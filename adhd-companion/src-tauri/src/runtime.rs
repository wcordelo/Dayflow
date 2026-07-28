//! Rust-resident loops — orchestrator tick, idle capture, analyze schedule.

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use tauri::AppHandle;

use crate::bus::BusEvent;
use crate::capture::CaptureEvent;
use crate::day_boundary::now_unix;
use crate::nudge_windows::{hide_nudge_windows, present_nudge_level};
use crate::pipeline::{Pipeline, PipelineStepResult};
use crate::state::AppState;

const ORCH_TICK_SECS: u64 = 15;
const IDLE_FALLBACK_SECS: u64 = 8;
const ANALYZE_EVERY_SECS: i64 = 15 * 60;

pub fn start_runtime(app: AppHandle, state: Arc<AppState>) {
    let stop = state.runtime_stop.clone();
    let state_tick = state.clone();
    let app_tick = app.clone();
    thread::spawn(move || {
        while !stop.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_secs(ORCH_TICK_SECS));
            if stop.load(Ordering::SeqCst) {
                break;
            }
            let _ = process_bus(&app_tick, &state_tick);
            let step = with_pipeline(&state_tick, |p| p.tick());
            present_from_step(&app_tick, &step);
        }
    });

    let stop2 = state.runtime_stop.clone();
    let state_idle = state.clone();
    let app_idle = app.clone();
    thread::spawn(move || {
        while !stop2.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_secs(IDLE_FALLBACK_SECS));
            if !state_idle.capture.running.load(Ordering::SeqCst) {
                continue;
            }
            let focus = state_idle.focus.lock().clone();
            let ev = CaptureEvent {
                trigger: "idle_fallback".into(),
                bundle_id: focus.bundle_id,
                window_title: focus.title,
                browser_url: focus.url,
                idle_seconds: Some(IDLE_FALLBACK_SECS as f64),
                jpeg_base64: None,
                accessibility_text: None,
                frame_hash: None,
            };
            let _ = state_idle.bus.emit(BusEvent::Capture(ev));
            let _ = process_bus(&app_idle, &state_idle);
        }
    });

    let stop3 = state.runtime_stop.clone();
    let state_an = state.clone();
    thread::spawn(move || {
        while !stop3.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_secs(30));
            let now = now_unix();
            let due = {
                let last = state_an.last_analyze_unix.lock();
                match *last {
                    None => true,
                    Some(t) => now - t >= ANALYZE_EVERY_SECS,
                }
            };
            if due && state_an.settings.lock().onboarding_complete {
                let client = {
                    let settings = state_an.settings.lock();
                    crate::gemini::select_client(
                        &state_an.data_dir,
                        settings.gemini_analysis_opt_in,
                    )
                };
                let result = {
                    let db = state_an.db.lock();
                    crate::engines::run_analyze_with_llm(&db, None, client.as_ref())
                };
                // Only advance the schedule on success so transient failures retry soon.
                if result.is_ok() {
                    *state_an.last_analyze_unix.lock() = Some(now);
                }
            }
        }
    });
}

fn with_pipeline<R>(state: &AppState, f: impl FnOnce(&mut Pipeline<'_>) -> R) -> R {
    let db = state.db.lock();
    let mut orch = state.orch.lock();
    let mut settings = state.settings.lock();
    let mut focus = state.focus.lock();
    let mut last = state.last_nudge_present_unix.lock();
    let mut pipe = Pipeline {
        db: &db,
        capture: &state.capture,
        orch: &mut orch,
        settings: &mut settings,
        focus: &mut focus,
        data_dir: &state.data_dir,
        last_nudge_present_unix: &mut last,
    };
    let out = f(&mut pipe);
    crate::state::save_orchestrator(&db, &orch, *last);
    out
}

pub fn process_bus(app: &AppHandle, state: &Arc<AppState>) -> Result<(), String> {
    for ev in state.bus.drain() {
        match ev {
            BusEvent::Sleep | BusEvent::Lock => {
                with_pipeline(state, |p| p.sleep_lock());
            }
            BusEvent::Wake | BusEvent::Unlock => {
                let step = with_pipeline(state, |p| p.wake());
                present_from_step(app, &step);
            }
            BusEvent::Capture(cap) => {
                let step = with_pipeline(state, |p| p.ingest_capture(cap))?;
                present_from_step(app, &step);
            }
            BusEvent::AppSwitch { bundle_id, title } => {
                emit_and_process(app, state, "app_switch", bundle_id, title)?;
            }
            BusEvent::WindowFocus { bundle_id, title } => {
                emit_and_process(app, state, "window_focus", bundle_id, title)?;
            }
            BusEvent::IdleReturn { idle_seconds } => {
                let focus = state.focus.lock().clone();
                let cap = CaptureEvent {
                    trigger: "idle_return".into(),
                    bundle_id: focus.bundle_id,
                    window_title: focus.title,
                    browser_url: focus.url,
                    idle_seconds: Some(idle_seconds),
                    jpeg_base64: None,
                    accessibility_text: None,
                    frame_hash: None,
                };
                let step = with_pipeline(state, |p| p.ingest_capture(cap))?;
                present_from_step(app, &step);
            }
            BusEvent::IdleFallback => {}
            BusEvent::FocusChanged { bundle_id, title } => {
                {
                    let mut focus = state.focus.lock();
                    focus.bundle_id = bundle_id.clone();
                    focus.title = title;
                }
                state.capture.on_focus_changed(bundle_id.as_deref());
            }
        }
    }
    Ok(())
}

fn emit_and_process(
    app: &AppHandle,
    state: &Arc<AppState>,
    trigger: &str,
    bundle_id: String,
    title: Option<String>,
) -> Result<(), String> {
    {
        let mut focus = state.focus.lock();
        focus.bundle_id = Some(bundle_id.clone());
        focus.title = title.clone();
    }
    let cap = CaptureEvent {
        trigger: trigger.into(),
        bundle_id: Some(bundle_id),
        window_title: title,
        browser_url: None,
        idle_seconds: Some(0.0),
        jpeg_base64: None,
        accessibility_text: Some("thin_ax".into()),
        frame_hash: None,
    };
    let step = with_pipeline(state, |p| p.ingest_capture(cap))?;
    present_from_step(app, &step);
    Ok(())
}

pub(crate) fn present_from_step(app: &AppHandle, step: &PipelineStepResult) {
    if step.presented_l1 || (step.level_before != step.level_after && step.level_after == "L1") {
        let _ = present_nudge_level(app, "L1");
    }
    if step.should_show_l2 {
        let _ = present_nudge_level(app, "L2");
    }
    if step.should_show_l3 {
        let _ = present_nudge_level(app, "L3");
    }
    if step.level_after == "idle" {
        let _ = hide_nudge_windows(app);
    }
}

/// After quit/crash restore, re-show the matching L1/L2/L3 surface so the
/// orchestrator is never elevated without a user-visible nudge.
pub fn restore_nudge_ui_after_boot(app: &AppHandle, state: &AppState) {
    let level = state.orch.lock().level.as_str().to_string();
    match level.as_str() {
        "L1" | "L2" | "L3" => {
            let _ = present_nudge_level(app, &level);
        }
        _ => {
            let _ = hide_nudge_windows(app);
        }
    }
}

pub fn stop_runtime(state: &AppState) {
    state.runtime_stop.store(true, Ordering::SeqCst);
}
