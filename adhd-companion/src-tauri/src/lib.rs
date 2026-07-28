mod bus;
mod capture;
mod day_boundary;
mod db;
mod engines;
mod gemini;
mod guards;
mod monitor;
mod nudge_windows;
mod orchestrator;
mod pipeline;
mod privacy;
mod runtime;
mod secrets;
mod state;

use std::sync::Arc;

use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager,
};
use tauri_plugin_autostart::MacosLauncher;

use bus::BusEvent;
use capture::CaptureEvent;
use day_boundary::{logical_day_key, next_day_boundary_unix, now_unix};
use engines::{run_checkin, run_soft_confirm};
use orchestrator::{OrchEvent, OrchestratorState};
use pipeline::Pipeline;
use state::{AppSettings, AppState};

fn data_dir() -> std::path::PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("ADHDCompanion")
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
    state::save_orchestrator(&db, &orch, *last);
    out
}

fn persist_orch(state: &AppState) {
    let db = state.db.lock();
    let orch = state.orch.lock();
    let last = state.last_nudge_present_unix.lock();
    state::save_orchestrator(&db, &orch, *last);
}

#[tauri::command]
fn get_status(state: tauri::State<'_, Arc<AppState>>) -> serde_json::Value {
    let orch = state.orch.lock();
    let settings = state.settings.lock();
    serde_json::json!({
        "platform": capture::native::platform_name(),
        "screen_recording_preflight": capture::native::screen_recording_preflight(),
        "capture_running": state.capture.running.load(std::sync::atomic::Ordering::SeqCst),
        "pause_capture": state.capture.pause_capture.load(std::sync::atomic::Ordering::SeqCst),
        "day": logical_day_key(now_unix()),
        "nudge_level": orch.level.as_str(),
        "gentle_mode": orch.gentle_mode,
        "onboarding_complete": settings.onboarding_complete,
        "companion_enabled": settings.companion_enabled,
        "has_gemini_key": secrets::load_gemini_key(&state.data_dir).is_some(),
        "contract": "v2.3",
        "runtime": "rust_resident",
    })
}

#[tauri::command]
fn get_orchestrator_state(state: tauri::State<'_, Arc<AppState>>) -> OrchestratorState {
    state.orch.lock().clone()
}

#[tauri::command]
fn orch_dispatch(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
    event: OrchEvent,
) -> Result<OrchestratorState, String> {
    let before = state.orch.lock().level.as_str().to_string();
    {
        let mut orch = state.orch.lock();
        orchestrator::reduce(&mut orch, event, now_unix());
        let day = logical_day_key(now_unix());
        if let Some(db) = state.db.try_lock() {
            let _ = db.log_nudge_event(
                &day,
                orch.level.as_str(),
                Some(&before),
                "dispatch",
                orch.last_transition.as_ref().map(|t| t.reason.as_str()),
                None,
                orch.escalate_after_unix,
            );
        }
    }
    let next = state.orch.lock().clone();
    let _ = nudge_windows::present_nudge_level(&app, next.level.as_str());
    if next.level.as_str() == "idle" {
        let _ = nudge_windows::hide_nudge_windows(&app);
    }
    persist_orch(&state);
    Ok(next)
}

/// L1 notification tap / action → escalate to L2 and show the nudge surface.
#[tauri::command]
fn l1_notification_clicked(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<OrchestratorState, String> {
    let before = state.orch.lock().level.as_str().to_string();
    {
        let mut orch = state.orch.lock();
        orchestrator::reduce(&mut orch, OrchEvent::L1Clicked, now_unix());
        let day = logical_day_key(now_unix());
        if let Some(db) = state.db.try_lock() {
            let _ = db.log_nudge_event(
                &day,
                orch.level.as_str(),
                Some(&before),
                "l1_clicked",
                orch.last_transition.as_ref().map(|t| t.reason.as_str()),
                None,
                orch.escalate_after_unix,
            );
        }
    }
    let next = state.orch.lock().clone();
    if next.level == orchestrator::NudgeLevel::L2 {
        let _ = nudge_windows::present_nudge_level(&app, "L2");
    }
    persist_orch(&state);
    Ok(next)
}

#[tauri::command]
fn start_capture(state: tauri::State<'_, Arc<AppState>>) -> Result<(), String> {
    state.capture.start();
    state
        .capture
        .pause_nudges_only
        .store(true, std::sync::atomic::Ordering::SeqCst);
    state
        .capture
        .pause_capture
        .store(false, std::sync::atomic::Ordering::SeqCst);
    Ok(())
}

#[tauri::command]
fn stop_capture(state: tauri::State<'_, Arc<AppState>>) -> Result<(), String> {
    state.capture.stop();
    Ok(())
}

#[tauri::command]
fn inject_capture_event(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
    event: CaptureEvent,
) -> Result<serde_json::Value, String> {
    let _ = state.bus.emit(BusEvent::Capture(event));
    runtime::process_bus(&app, &state)?;
    let orch = state.orch.lock().clone();
    Ok(serde_json::json!({
        "nudge_level": orch.level.as_str(),
        "pending_drift": orch.pending_drift,
        "gentle_mode": orch.gentle_mode,
    }))
}

#[tauri::command]
fn emit_os_event(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
    event: BusEvent,
) -> Result<(), String> {
    let _ = state.bus.emit(event);
    runtime::process_bus(&app, &state)
}

#[tauri::command]
fn list_screenshots(
    state: tauri::State<'_, Arc<AppState>>,
    day: Option<String>,
) -> Result<Vec<db::ScreenshotRow>, String> {
    let day = day.unwrap_or_else(|| logical_day_key(now_unix()));
    state
        .db
        .lock()
        .list_screenshots(&day, 100)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn list_timeline(
    state: tauri::State<'_, Arc<AppState>>,
    day: Option<String>,
) -> Result<Vec<db::TimelineCard>, String> {
    let day = day.unwrap_or_else(|| logical_day_key(now_unix()));
    state
        .db
        .lock()
        .list_timeline_cards(&day)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn list_priorities(
    state: tauri::State<'_, Arc<AppState>>,
    day: Option<String>,
) -> Result<Vec<monitor::Priority>, String> {
    let day = day.unwrap_or_else(|| logical_day_key(now_unix()));
    state
        .db
        .lock()
        .list_priorities(&day)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn save_checkin(
    state: tauri::State<'_, Arc<AppState>>,
    priorities: Vec<String>,
) -> Result<engines::CheckinResult, String> {
    let db = state.db.lock();
    let result = run_checkin(&db, priorities)?;
    drop(db);
    {
        let mut orch = state.orch.lock();
        orchestrator::reduce(
            &mut orch,
            OrchEvent::Acknowledge {
                reason: "priorities_changed".into(),
            },
            now_unix(),
        );
    }
    persist_orch(&state);
    Ok(result)
}

#[tauri::command]
fn soft_confirm_priorities(state: tauri::State<'_, Arc<AppState>>) -> Result<usize, String> {
    let db = state.db.lock();
    run_soft_confirm(&db)
}

#[tauri::command]
fn run_analyze_cmd(
    state: tauri::State<'_, Arc<AppState>>,
    day: Option<String>,
) -> Result<engines::AnalyzeBatchResult, String> {
    with_pipeline(&state, |p| {
        if let Some(d) = day.as_deref() {
            let client = p.llm();
            engines::run_analyze_with_llm(p.db, Some(d), client.as_ref())
        } else {
            p.run_analyze()
        }
    })
}

#[tauri::command]
fn run_brief_cmd(
    state: tauri::State<'_, Arc<AppState>>,
    day: Option<String>,
) -> Result<db::BriefPayload, String> {
    with_pipeline(&state, |p| {
        if let Some(d) = day.as_deref() {
            let client = p.llm();
            engines::run_brief_with_llm(p.db, Some(d), client.as_ref())
        } else {
            p.run_brief()
        }
    })
}

#[tauri::command]
fn acknowledge_nudge(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
    reason: String,
) -> Result<OrchestratorState, String> {
    if reason == "overwhelm" {
        let until = next_day_boundary_unix(now_unix());
        {
            let mut s = state.settings.lock();
            s.overwhelm_until = Some(until);
            s.pause_nudges_until = Some(until);
            let snapshot = s.clone();
            drop(s);
            {
                let db = state.db.lock();
                snapshot.persist_to_db(&db).map_err(|e| e.to_string())?;
            }
        }
        let mut orch = state.orch.lock();
        orch.guards.overwhelm = true;
        orch.guards.paused = true;
        // Pre-set deadline so enter_cooldown("overwhelm") keeps it (like pause).
        orch.guards.cooldown_until_unix = Some(until);
    }
    let next = {
        let mut orch = state.orch.lock();
        orchestrator::reduce(
            &mut orch,
            OrchEvent::Acknowledge { reason },
            now_unix(),
        );
        orch.clone()
    };
    nudge_windows::hide_nudge_windows(&app)?;
    persist_orch(&state);
    Ok(next)
}

#[tauri::command]
fn tick_orchestrator(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<OrchestratorState, String> {
    let step = with_pipeline(&state, |p| p.tick());
    runtime::present_from_step(&app, &step);
    Ok(state.orch.lock().clone())
}

#[tauri::command]
fn get_settings(state: tauri::State<'_, Arc<AppState>>) -> AppSettings {
    state.settings.lock().clone()
}

#[tauri::command]
fn update_settings(
    state: tauri::State<'_, Arc<AppState>>,
    patch: AppSettings,
) -> Result<AppSettings, String> {
    // Settings UI sends a full snapshot; preserve runtime-owned counters / clocks
    // so a stale refresh cannot rewind daily budget or wipe an active pause.
    let merged = {
        let current = state.settings.lock();
        let mut merged = patch;
        merged.nudges_fired_today = current.nudges_fired_today;
        merged.pause_nudges_until = current.pause_nudges_until;
        merged.pause_capture_until = current.pause_capture_until;
        merged.overwhelm_until = current.overwhelm_until;
        merged
    };
    {
        let db = state.db.lock();
        merged.persist_to_db(&db).map_err(|e| e.to_string())?;
        // Refresh orchestrator guards immediately so companion_enabled / quiet hours /
        // budget / aggressiveness apply before the next capture or 15s tick.
        let day = logical_day_key(now_unix());
        let active = db
            .list_priorities(&day)
            .unwrap_or_default()
            .iter()
            .filter(|p| p.status == "active")
            .count() as u32;
        let mut orch = state.orch.lock();
        let focus = state.focus.lock();
        let last = state.last_nudge_present_unix.lock();
        guards::sync_guards(
            &mut orch,
            &merged,
            active,
            focus.bundle_id.as_deref(),
            focus.title.as_deref(),
            focus.url.as_deref(),
            now_unix(),
        );
        if let Some(t) = *last {
            orch.guards.minutes_since_last_nudge = Some(((now_unix() - t) / 60).max(0));
        }
        state::save_orchestrator(&db, &orch, *last);
    }
    state
        .capture
        .set_rules(guards::default_rules_from_settings(&merged));
    *state.settings.lock() = merged.clone();
    Ok(merged)
}

#[tauri::command]
fn pause_nudges(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
    minutes: i64,
) -> Result<AppSettings, String> {
    apply_pause_nudges(&app, &state, minutes)
}

fn apply_pause_nudges(
    app: &tauri::AppHandle,
    state: &AppState,
    minutes: i64,
) -> Result<AppSettings, String> {
    let until = now_unix() + minutes * 60;
    let mut settings = state.settings.lock();
    settings.pause_nudges_until = Some(until);
    let snapshot = settings.clone();
    drop(settings);
    {
        let db = state.db.lock();
        snapshot.persist_to_db(&db).map_err(|e| e.to_string())?;
    }
    state
        .capture
        .pause_nudges_only
        .store(true, std::sync::atomic::Ordering::SeqCst);
    {
        let mut orch = state.orch.lock();
        orch.guards.paused = true;
        orch.guards.cooldown_until_unix = Some(until);
        orchestrator::reduce(
            &mut orch,
            OrchEvent::Acknowledge {
                reason: "pause".into(),
            },
            now_unix(),
        );
    }
    nudge_windows::hide_nudge_windows(app)?;
    persist_orch(state);
    Ok(snapshot)
}

#[tauri::command]
fn pause_watching(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<AppSettings, String> {
    // UI contract: pause watching stops capture *and* nudges (24h).
    let until = now_unix() + 24 * 3600;
    let mut settings = state.settings.lock();
    settings.pause_capture_until = Some(until);
    settings.pause_nudges_until = Some(until);
    let snapshot = settings.clone();
    drop(settings);
    {
        let db = state.db.lock();
        snapshot.persist_to_db(&db).map_err(|e| e.to_string())?;
    }
    state
        .capture
        .pause_nudges_only
        .store(false, std::sync::atomic::Ordering::SeqCst);
    state
        .capture
        .pause_capture
        .store(true, std::sync::atomic::Ordering::SeqCst);
    {
        let mut orch = state.orch.lock();
        orch.guards.paused = true;
        orch.guards.cooldown_until_unix = Some(until);
        orchestrator::reduce(
            &mut orch,
            OrchEvent::Acknowledge {
                reason: "pause".into(),
            },
            now_unix(),
        );
    }
    nudge_windows::hide_nudge_windows(&app)?;
    persist_orch(&state);
    Ok(snapshot)
}

#[tauri::command]
fn overwhelm_until_boundary(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<AppState>>,
) -> Result<AppSettings, String> {
    let until = next_day_boundary_unix(now_unix());
    let mut s = state.settings.lock().clone();
    s.overwhelm_until = Some(until);
    s.pause_nudges_until = Some(until);
    *state.settings.lock() = s.clone();
    {
        let db = state.db.lock();
        s.persist_to_db(&db).map_err(|e| e.to_string())?;
    }
    {
        let mut orch = state.orch.lock();
        orch.guards.overwhelm = true;
        orch.guards.paused = true;
        // Pre-set deadline so enter_cooldown("overwhelm") keeps it (like pause).
        orch.guards.cooldown_until_unix = Some(until);
        orchestrator::reduce(
            &mut orch,
            OrchEvent::Acknowledge {
                reason: "overwhelm".into(),
            },
            now_unix(),
        );
    }
    nudge_windows::hide_nudge_windows(&app)?;
    persist_orch(&state);
    Ok(s)
}

#[tauri::command]
fn complete_onboarding(state: tauri::State<'_, Arc<AppState>>) -> Result<(), String> {
    let mut s = state.settings.lock().clone();
    s.onboarding_complete = true;
    *state.settings.lock() = s;
    state
        .db
        .lock()
        .set_setting("onboarding_complete", "1")
        .map_err(|e| e.to_string())?;
    state.capture.start();
    Ok(())
}

#[tauri::command]
fn store_gemini_key(state: tauri::State<'_, Arc<AppState>>, key: String) -> Result<String, String> {
    secrets::store_gemini_key(&state.data_dir, &key)?;
    Ok(format!("stored fingerprint={}", secrets::key_fingerprint(&key)))
}

#[tauri::command]
fn clear_gemini_key(state: tauri::State<'_, Arc<AppState>>) -> Result<(), String> {
    secrets::clear_gemini_key(&state.data_dir)
}

#[tauri::command]
fn get_nudge_view_model(state: tauri::State<'_, Arc<AppState>>) -> serde_json::Value {
    let orch = state.orch.lock();
    let day = logical_day_key(now_unix());
    let priorities = state.db.lock().list_priorities(&day).unwrap_or_default();
    serde_json::json!({
        "level": orch.level.as_str(),
        "priorities": priorities,
        "message": "Still with your list? No shame — pick what fits.",
    })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let dir = data_dir();
    let db = db::Database::open(&dir).expect("open db");
    let app_state = Arc::new(AppState::new(db, dir));

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            Some(vec!["--autostart"]),
        ))
        .manage(app_state.clone())
        .setup(move |app| {
            let show_i = MenuItem::with_id(app, "show", "Open ADHD Companion", true, None::<&str>)?;
            let pause_i = MenuItem::with_id(app, "pause", "Pause nudges 30m", true, None::<&str>)?;
            let quit_i = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show_i, &pause_i, &quit_i])?;

            let _tray = TrayIconBuilder::new()
                .menu(&menu)
                .tooltip("ADHD Companion")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "quit" => {
                        if let Some(st) = app.try_state::<Arc<AppState>>() {
                            runtime::stop_runtime(&st);
                        }
                        app.exit(0);
                    }
                    "show" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                    "pause" => {
                        if let Some(st) = app.try_state::<Arc<AppState>>() {
                            let _ = apply_pause_nudges(app, &st, 30);
                        }
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                })
                .build(app)?;

            if app_state.settings.lock().onboarding_complete {
                app_state.capture.start();
            }
            runtime::start_runtime(app.handle().clone(), app_state.clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_status,
            get_orchestrator_state,
            orch_dispatch,
            l1_notification_clicked,
            start_capture,
            stop_capture,
            inject_capture_event,
            emit_os_event,
            list_screenshots,
            list_timeline,
            list_priorities,
            save_checkin,
            soft_confirm_priorities,
            run_analyze_cmd,
            run_brief_cmd,
            acknowledge_nudge,
            tick_orchestrator,
            get_settings,
            update_settings,
            pause_nudges,
            pause_watching,
            overwhelm_until_boundary,
            complete_onboarding,
            store_gemini_key,
            clear_gemini_key,
            get_nudge_view_model,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// Exposed for integration tests / e2e harness (no Tauri UI).
pub mod testkit {
    pub use crate::bus::*;
    pub use crate::capture::*;
    pub use crate::day_boundary::*;
    pub use crate::db::*;
    pub use crate::engines::*;
    pub use crate::gemini::*;
    pub use crate::guards::*;
    pub use crate::monitor::*;
    pub use crate::orchestrator::*;
    pub use crate::pipeline::*;
    pub use crate::privacy::*;
    pub use crate::secrets::*;
    pub use crate::state::*;
}
