//! Full-day E2E pipeline without Tauri UI (runs on Linux CI).

use std::thread;
use std::time::Duration;

use adhd_companion_lib::testkit::*;
use tempfile::tempdir;

#[test]
fn e2e_capture_monitor_escalate_analyze_brief() {
    let dir = tempdir().unwrap();
    let db = Database::open(dir.path()).unwrap();
    let mut settings = AppSettings {
        onboarding_complete: true,
        gemini_analysis_opt_in: false,
        daily_nudge_budget: 20,
        nudges_fired_today: 0,
        quiet_hours_start: None,
        quiet_hours_end: None,
        ..AppSettings::default()
    };

    let capture = CaptureService::new();
    capture.set_rules(default_rules_from_settings(&settings));
    capture.start();

    db.replace_priorities(
        &logical_day_key(now_unix()),
        &["Write grant proposal".into(), "Email advisor".into()],
        "checkin",
    )
    .unwrap();

    let mut orch = OrchestratorState::default();
    orch.guards.minutes_since_last_nudge = Some(60);
    orch.guards.min_minutes_between_nudges = 0;

    let mut focus = FocusContext::default();
    let mut last_nudge = None;
    let mut pipe = Pipeline {
        db: &db,
        capture: &capture,
        orch: &mut orch,
        settings: &mut settings,
        focus: &mut focus,
        data_dir: dir.path(),
        last_nudge_present_unix: &mut last_nudge,
    };

    // Aligned work — stay idle
    let aligned = pipe
        .ingest_capture(CaptureEvent {
            trigger: "app_switch".into(),
            bundle_id: Some("com.google.Chrome".into()),
            window_title: Some("Grant proposal outline — Docs".into()),
            browser_url: Some("https://docs.google.com".into()),
            idle_seconds: Some(1.0),
            jpeg_base64: None,
            accessibility_text: Some("proposal".into()),
            frame_hash: Some("h1".into()),
        })
        .unwrap();
    assert_eq!(aligned.level_after, "idle");

    thread::sleep(Duration::from_millis(220));

    // Netflix triggers DRM pause (skip) — then leave DRM
    let _ = pipe.ingest_capture(CaptureEvent {
        trigger: "app_switch".into(),
        bundle_id: Some("com.netflix.Netflix".into()),
        window_title: Some("Netflix — Drama".into()),
        browser_url: None,
        idle_seconds: Some(1.0),
        jpeg_base64: None,
        accessibility_text: None,
        frame_hash: Some("h2".into()),
    });
    capture.on_focus_changed(Some("com.spotify.client"));
    thread::sleep(Duration::from_millis(220));

    let drift = pipe
        .ingest_capture(CaptureEvent {
            trigger: "app_switch".into(),
            bundle_id: Some("com.spotify.client".into()),
            window_title: Some("YouTube Music — hits".into()),
            browser_url: None,
            idle_seconds: Some(1.0),
            jpeg_base64: None,
            accessibility_text: None,
            frame_hash: Some("h3".into()),
        })
        .unwrap();
    assert!(
        matches!(drift.level_after.as_str(), "L1" | "L2"),
        "expected L1/L2 after drift, got {}",
        drift.level_after
    );

    if pipe.orch.level == NudgeLevel::L1 {
        pipe.orch.escalate_after_unix = Some(now_unix() - 1);
        assert_eq!(pipe.tick().level_after, "L2");
    }
    if pipe.orch.level == NudgeLevel::L2 {
        pipe.orch.escalate_after_unix = Some(now_unix() - 1);
        assert_eq!(pipe.tick().level_after, "L3");
    }

    reduce(
        pipe.orch,
        OrchEvent::Acknowledge {
            reason: "doing_it".into(),
        },
        now_unix(),
    );
    assert_eq!(pipe.orch.level, NudgeLevel::Idle);
    assert!(pipe.orch.cooldown_until_unix.is_some());

    pipe.sleep_lock();
    assert!(capture.pause_capture.load(std::sync::atomic::Ordering::SeqCst));
    let _ = pipe.wake();
    assert!(!capture.pause_capture.load(std::sync::atomic::Ordering::SeqCst));

    thread::sleep(Duration::from_millis(220));
    let incog = pipe
        .ingest_capture(CaptureEvent {
            trigger: "window_focus".into(),
            bundle_id: Some("com.google.Chrome".into()),
            window_title: Some("Secret - Incognito".into()),
            browser_url: None,
            idle_seconds: Some(0.0),
            jpeg_base64: None,
            accessibility_text: None,
            frame_hash: Some("h4".into()),
        })
        .unwrap();
    assert!(incog.capture.as_ref().unwrap().skipped);

    thread::sleep(Duration::from_millis(220));
    let _ = pipe
        .ingest_capture(CaptureEvent {
            trigger: "idle_fallback".into(),
            bundle_id: Some("com.apple.Safari".into()),
            window_title: Some("Docs".into()),
            browser_url: None,
            idle_seconds: Some(8.0),
            jpeg_base64: None,
            accessibility_text: None,
            frame_hash: Some("samehash".into()),
        })
        .unwrap();
    thread::sleep(Duration::from_millis(220));
    let deduped = pipe
        .ingest_capture(CaptureEvent {
            trigger: "idle_fallback".into(),
            bundle_id: Some("com.apple.Safari".into()),
            window_title: Some("Docs".into()),
            browser_url: None,
            idle_seconds: Some(8.0),
            jpeg_base64: None,
            accessibility_text: None,
            frame_hash: Some("samehash".into()),
        })
        .unwrap();
    assert!(deduped.capture.as_ref().unwrap().deduped);

    let analyze = pipe.run_analyze().unwrap();
    assert!(analyze.observations >= 1);
    let brief = pipe.run_brief().unwrap();
    assert!(!brief.accomplishments.is_empty());

    store_gemini_key(dir.path(), "fake-key-for-test").unwrap();
    assert!(load_gemini_key(dir.path()).is_some());
    clear_gemini_key(dir.path()).unwrap();
}

#[test]
fn e2e_bus_debounce_and_quiet_hours() {
    let bus = EventBus::new(200);
    let e = BusEvent::AppSwitch {
        bundle_id: "com.a".into(),
        title: None,
    };
    assert!(bus.emit(e.clone()));
    assert!(!bus.emit(e));

    let s = AppSettings {
        quiet_hours_start: Some(22),
        quiet_hours_end: Some(7),
        ..AppSettings::default()
    };
    assert!(in_quiet_hours(&s, 23));
    assert!(!in_quiet_hours(&s, 12));
    assert!(meeting_heuristic(Some("us.zoom.xos"), Some("Zoom"), None));
}

#[test]
fn e2e_tick_budgets_and_drm_holds_progression() {
    let dir = tempdir().unwrap();
    let db = Database::open(dir.path()).unwrap();
    let mut settings = AppSettings {
        onboarding_complete: true,
        gemini_analysis_opt_in: false,
        daily_nudge_budget: 20,
        nudges_fired_today: 0,
        quiet_hours_start: None,
        quiet_hours_end: None,
        ..AppSettings::default()
    };
    let capture = CaptureService::new();
    capture.set_rules(default_rules_from_settings(&settings));
    capture.start();
    db.replace_priorities(
        &logical_day_key(now_unix()),
        &["Write grant proposal".into()],
        "checkin",
    )
    .unwrap();

    let mut orch = OrchestratorState::default();
    orch.guards.minutes_since_last_nudge = Some(60);
    orch.guards.min_minutes_between_nudges = 0;
    // Pending drift past anchor cap → tick should fire L1 and count budget.
    orch.pending_drift = true;
    orch.pending_drift_since_unix = Some(now_unix() - PENDING_ANCHOR_CAP_SECS - 1);
    orch.pending_confidence = Some(Confidence::High);

    let mut focus = FocusContext {
        bundle_id: Some("com.apple.Safari".into()),
        title: Some("Docs".into()),
        url: None,
    };
    let mut last_nudge = None;
    let mut pipe = Pipeline {
        db: &db,
        capture: &capture,
        orch: &mut orch,
        settings: &mut settings,
        focus: &mut focus,
        data_dir: dir.path(),
        last_nudge_present_unix: &mut last_nudge,
    };

    let step = pipe.tick();
    assert_eq!(step.level_after, "L1");
    assert!(step.presented_l1);
    assert_eq!(pipe.settings.nudges_fired_today, 1);
    assert!(pipe.last_nudge_present_unix.is_some());

    // Switch focus to DRM — tick must not escalate or present.
    pipe.focus.bundle_id = Some("com.netflix.Netflix".into());
    pipe.orch.escalate_after_unix = Some(now_unix() - 1);
    let held = pipe.tick();
    assert_eq!(held.level_after, "L1");
    assert!(!held.presented_l1);
    assert!(!held.should_show_l2);
    assert!(!held.should_show_l3);
    assert_eq!(pipe.settings.nudges_fired_today, 1);
}
