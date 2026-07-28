//! Shared app state.

use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

use crate::bus::EventBus;
use crate::capture::CaptureService;
use crate::db::{Database, DbError};
use crate::orchestrator::{NudgeLevel, OrchestratorState};

const ORCH_STATE_KEY: &str = "orchestrator_state_json";
const LAST_NUDGE_KEY: &str = "last_nudge_present_unix";

/// Persist wall-clock nudge machine + spacing so quit/crash can resume.
pub fn save_orchestrator(
    db: &Database,
    orch: &OrchestratorState,
    last_nudge_present_unix: Option<i64>,
) {
    if let Ok(json) = serde_json::to_string(orch) {
        let _ = db.set_setting(ORCH_STATE_KEY, &json);
    }
    let _ = db.set_setting(
        LAST_NUDGE_KEY,
        &last_nudge_present_unix
            .map(|v| v.to_string())
            .unwrap_or_default(),
    );
}

pub fn load_orchestrator(db: &Database) -> (OrchestratorState, Option<i64>) {
    let mut orch = OrchestratorState::default();
    if let Ok(Some(json)) = db.get_setting(ORCH_STATE_KEY) {
        if let Ok(loaded) = serde_json::from_str::<OrchestratorState>(&json) {
            orch = loaded;
        }
    }
    let last = db
        .get_setting(LAST_NUDGE_KEY)
        .ok()
        .flatten()
        .filter(|s| !s.is_empty())
        .and_then(|s| s.parse().ok());
    (orch, last)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    pub companion_enabled: bool,
    pub checkin_hour: u32,
    pub daily_nudge_budget: i32,
    pub nudges_fired_today: i32,
    pub aggressiveness: u8,
    pub gemini_analysis_opt_in: bool,
    pub onboarding_complete: bool,
    pub pause_nudges_until: Option<i64>,
    pub pause_capture_until: Option<i64>,
    pub overwhelm_until: Option<i64>,
    pub quiet_hours_start: Option<u32>,
    pub quiet_hours_end: Option<u32>,
    pub app_blocklist: Vec<String>,
    pub title_blocklist: Vec<String>,
    pub ignore_incognito: bool,
    pub pause_on_drm: bool,
    pub autostart: bool,
    pub l2_l3_break_focus: bool,
    pub launch_at_login_requested: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            companion_enabled: true,
            checkin_hour: 9,
            daily_nudge_budget: 12,
            nudges_fired_today: 0,
            aggressiveness: 1,
            gemini_analysis_opt_in: false,
            onboarding_complete: false,
            pause_nudges_until: None,
            pause_capture_until: None,
            overwhelm_until: None,
            quiet_hours_start: Some(22),
            quiet_hours_end: Some(7),
            app_blocklist: vec!["com.1password.1password".into(), "com.apple.MobileSMS".into()],
            title_blocklist: vec!["password reset".into(), "bank statement".into()],
            ignore_incognito: true,
            pause_on_drm: true,
            autostart: true,
            l2_l3_break_focus: false,
            launch_at_login_requested: true,
        }
    }
}

fn setting_bool(v: &str) -> bool {
    v == "1" || v == "true"
}

fn load_opt_u32_from_db(db: &Database, key: &str) -> Option<Option<u32>> {
    match db.get_setting(key).ok().flatten() {
        None => None,
        Some(v) if v.is_empty() => Some(None),
        Some(v) => Some(v.parse().ok()),
    }
}

fn load_opt_i64_from_db(db: &Database, key: &str, now: i64) -> Option<Option<i64>> {
    match db.get_setting(key).ok().flatten() {
        None => None,
        Some(v) if v.is_empty() => Some(None),
        Some(v) => match v.parse::<i64>() {
            Ok(t) if t > now => Some(Some(t)),
            _ => Some(None),
        },
    }
}

impl AppSettings {
    pub fn hydrate_from_db(&mut self, db: &Database) {
        if let Ok(Some(v)) = db.get_setting("onboarding_complete") {
            self.onboarding_complete = setting_bool(&v);
        }
        if let Ok(Some(v)) = db.get_setting("companion_enabled") {
            self.companion_enabled = v != "0" && v != "false";
        }
        if let Ok(Some(v)) = db.get_setting("gemini_analysis_opt_in") {
            self.gemini_analysis_opt_in = setting_bool(&v);
        }
        if let Ok(Some(v)) = db.get_setting("checkin_hour") {
            if let Ok(h) = v.parse() {
                self.checkin_hour = h;
            }
        }
        if let Ok(Some(v)) = db.get_setting("daily_nudge_budget") {
            if let Ok(b) = v.parse() {
                self.daily_nudge_budget = b;
            }
        }
        if let Ok(Some(v)) = db.get_setting("aggressiveness") {
            if let Ok(a) = v.parse() {
                self.aggressiveness = a;
            }
        }
        if let Some(v) = load_opt_u32_from_db(db, "quiet_hours_start") {
            self.quiet_hours_start = v;
        }
        if let Some(v) = load_opt_u32_from_db(db, "quiet_hours_end") {
            self.quiet_hours_end = v;
        }
        if let Ok(Some(v)) = db.get_setting("ignore_incognito") {
            self.ignore_incognito = setting_bool(&v);
        }
        if let Ok(Some(v)) = db.get_setting("pause_on_drm") {
            self.pause_on_drm = setting_bool(&v);
        }
        if let Ok(Some(v)) = db.get_setting("autostart") {
            self.autostart = setting_bool(&v);
        }
        if let Ok(Some(v)) = db.get_setting("l2_l3_break_focus") {
            self.l2_l3_break_focus = setting_bool(&v);
        }
        if let Ok(Some(v)) = db.get_setting("launch_at_login_requested") {
            self.launch_at_login_requested = setting_bool(&v);
        }
        if let Ok(Some(v)) = db.get_setting("app_blocklist_json") {
            if let Ok(list) = serde_json::from_str::<Vec<String>>(&v) {
                self.app_blocklist = list;
            }
        }
        if let Ok(Some(v)) = db.get_setting("title_blocklist_json") {
            if let Ok(list) = serde_json::from_str::<Vec<String>>(&v) {
                self.title_blocklist = list;
            }
        }
        if let Ok(Some(v)) = db.get_setting("nudges_fired_today") {
            self.nudges_fired_today = v.parse().unwrap_or(0);
        }
        let now = crate::day_boundary::now_unix();
        if let Some(v) = load_opt_i64_from_db(db, "pause_nudges_until", now) {
            self.pause_nudges_until = v;
        }
        if let Some(v) = load_opt_i64_from_db(db, "pause_capture_until", now) {
            self.pause_capture_until = v;
        }
        if let Some(v) = load_opt_i64_from_db(db, "overwhelm_until", now) {
            self.overwhelm_until = v;
        }
    }

    pub fn persist_to_db(&self, db: &Database) -> Result<(), DbError> {
        db.set_setting(
            "companion_enabled",
            if self.companion_enabled { "1" } else { "0" },
        )?;
        db.set_setting(
            "gemini_analysis_opt_in",
            if self.gemini_analysis_opt_in { "1" } else { "0" },
        )?;
        db.set_setting(
            "onboarding_complete",
            if self.onboarding_complete { "1" } else { "0" },
        )?;
        db.set_setting("checkin_hour", &self.checkin_hour.to_string())?;
        db.set_setting("daily_nudge_budget", &self.daily_nudge_budget.to_string())?;
        db.set_setting("nudges_fired_today", &self.nudges_fired_today.to_string())?;
        db.set_setting("aggressiveness", &self.aggressiveness.to_string())?;
        db.set_setting(
            "quiet_hours_start",
            &self
                .quiet_hours_start
                .map(|v| v.to_string())
                .unwrap_or_default(),
        )?;
        db.set_setting(
            "quiet_hours_end",
            &self
                .quiet_hours_end
                .map(|v| v.to_string())
                .unwrap_or_default(),
        )?;
        db.set_setting(
            "ignore_incognito",
            if self.ignore_incognito { "1" } else { "0" },
        )?;
        db.set_setting(
            "pause_on_drm",
            if self.pause_on_drm { "1" } else { "0" },
        )?;
        db.set_setting("autostart", if self.autostart { "1" } else { "0" })?;
        db.set_setting(
            "l2_l3_break_focus",
            if self.l2_l3_break_focus { "1" } else { "0" },
        )?;
        db.set_setting(
            "launch_at_login_requested",
            if self.launch_at_login_requested { "1" } else { "0" },
        )?;
        db.set_setting(
            "pause_nudges_until",
            &self
                .pause_nudges_until
                .map(|v| v.to_string())
                .unwrap_or_default(),
        )?;
        db.set_setting(
            "pause_capture_until",
            &self
                .pause_capture_until
                .map(|v| v.to_string())
                .unwrap_or_default(),
        )?;
        db.set_setting(
            "overwhelm_until",
            &self
                .overwhelm_until
                .map(|v| v.to_string())
                .unwrap_or_default(),
        )?;
        db.set_setting(
            "app_blocklist_json",
            &serde_json::to_string(&self.app_blocklist).unwrap_or_else(|_| "[]".into()),
        )?;
        db.set_setting(
            "title_blocklist_json",
            &serde_json::to_string(&self.title_blocklist).unwrap_or_else(|_| "[]".into()),
        )?;
        Ok(())
    }
}

#[derive(Debug, Clone, Default)]
pub struct FocusContext {
    pub bundle_id: Option<String>,
    pub title: Option<String>,
    pub url: Option<String>,
}

pub struct AppState {
    pub db: Mutex<Database>,
    pub orch: Mutex<OrchestratorState>,
    pub capture: CaptureService,
    pub settings: Mutex<AppSettings>,
    pub bus: Arc<EventBus>,
    pub focus: Mutex<FocusContext>,
    pub runtime_stop: Arc<AtomicBool>,
    pub last_nudge_present_unix: Mutex<Option<i64>>,
    pub last_analyze_unix: Mutex<Option<i64>>,
    pub data_dir: std::path::PathBuf,
}

impl AppState {
    pub fn new(db: Database, data_dir: std::path::PathBuf) -> Self {
        let mut s = AppSettings::default();
        s.hydrate_from_db(&db);
        let today = crate::day_boundary::logical_day_key(crate::day_boundary::now_unix());
        let stored_day = db.get_setting("nudges_fired_today_day").ok().flatten();
        let (mut orch, last_nudge) = load_orchestrator(&db);
        if stored_day.as_deref() != Some(today.as_str()) {
            s.nudges_fired_today = 0;
            orch.l3_presentations_today = 0;
            orch.gentle_mode = false;
            orch.consecutive_ignores = 0;
            let _ = db.set_setting("nudges_fired_today_day", &today);
            let _ = db.set_setting("nudges_fired_today", "0");
        }
        let now = crate::day_boundary::now_unix();
        if let Some(cd) = orch.cooldown_until_unix {
            if now >= cd {
                orch.cooldown_until_unix = None;
                orch.guards.cooldown_until_unix = None;
            }
        }
        // Stale L1/L2 sessions without a deadline fall back to idle on boot.
        if matches!(orch.level, NudgeLevel::L1 | NudgeLevel::L2)
            && orch.escalate_after_unix.is_none()
        {
            orch.level = NudgeLevel::Idle;
            orch.level_entered_at_unix = None;
        }
        // Resync guards from hydrated settings so overwhelm / pause / quiet /
        // budget / companion_enabled apply before the first tick or capture.
        let active = db
            .list_priorities(&today)
            .unwrap_or_default()
            .iter()
            .filter(|p| p.status == "active")
            .count() as u32;
        crate::guards::sync_guards(&mut orch, &s, active, None, None, None, now);
        if let Some(t) = last_nudge {
            orch.guards.minutes_since_last_nudge = Some(((now - t) / 60).max(0));
        }
        // Catch up L1→L2→L3 escalations that elapsed while the app was quit.
        // UI re-presentation happens in setup once the AppHandle exists.
        if orch.level != NudgeLevel::Idle {
            crate::orchestrator::reduce(
                &mut orch,
                crate::orchestrator::OrchEvent::Tick,
                now,
            );
        }
        save_orchestrator(&db, &orch, last_nudge);

        let capture = CaptureService::new();
        capture.set_rules(crate::guards::default_rules_from_settings(&s));
        if s.pause_capture_until.map(|t| now < t).unwrap_or(false) {
            capture
                .pause_capture
                .store(true, std::sync::atomic::Ordering::SeqCst);
        }
        Self {
            db: Mutex::new(db),
            orch: Mutex::new(orch),
            capture,
            settings: Mutex::new(s),
            bus: EventBus::new(200),
            focus: Mutex::new(FocusContext::default()),
            runtime_stop: Arc::new(AtomicBool::new(false)),
            last_nudge_present_unix: Mutex::new(last_nudge),
            last_analyze_unix: Mutex::new(None),
            data_dir,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::day_boundary::now_unix;
    use crate::orchestrator::{Confidence, NudgeLevel};
    use tempfile::tempdir;

    #[test]
    fn orchestrator_survives_appstate_restart() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let today = crate::day_boundary::logical_day_key(now_unix());
        let _ = db.set_setting("nudges_fired_today_day", &today);
        let mut orch = OrchestratorState::default();
        orch.level = NudgeLevel::L1;
        orch.escalate_after_unix = Some(now_unix() + 500);
        orch.pending_drift = false;
        orch.consecutive_ignores = 2;
        orch.pending_confidence = Some(Confidence::High);
        let last = Some(now_unix() - 120);
        save_orchestrator(&db, &orch, last);

        let state = AppState::new(db, dir.path().to_path_buf());
        let loaded = state.orch.lock().clone();
        assert_eq!(loaded.level, NudgeLevel::L1);
        assert_eq!(loaded.escalate_after_unix, orch.escalate_after_unix);
        assert_eq!(loaded.consecutive_ignores, 2);
        assert_eq!(*state.last_nudge_present_unix.lock(), last);
    }

    #[test]
    fn boot_keeps_l2_and_escalates_past_deadline() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let today = crate::day_boundary::logical_day_key(now_unix());
        let _ = db.set_setting("nudges_fired_today_day", &today);
        // Disable default quiet hours so boot Tick catch-up is not cancelled.
        let _ = db.set_setting("quiet_hours_start", "");
        let _ = db.set_setting("quiet_hours_end", "");
        db.replace_priorities(&today, &["Write grant proposal".into()], "checkin")
            .unwrap();
        let now = now_unix();

        let mut live = OrchestratorState::default();
        live.level = NudgeLevel::L2;
        live.escalate_after_unix = Some(now + 600);
        live.level_entered_at_unix = Some(now - 60);
        save_orchestrator(&db, &live, Some(now - 120));
        let state = AppState::new(
            Database::open(dir.path()).unwrap(),
            dir.path().to_path_buf(),
        );
        assert_eq!(state.orch.lock().level, NudgeLevel::L2);

        let mut overdue = OrchestratorState::default();
        overdue.level = NudgeLevel::L1;
        overdue.escalate_after_unix = Some(now - 1);
        overdue.level_entered_at_unix = Some(now - 900);
        overdue.guards.min_minutes_between_nudges = 0;
        overdue.guards.minutes_since_last_nudge = Some(60);
        save_orchestrator(&db, &overdue, Some(now - 3600));
        let state2 = AppState::new(db, dir.path().to_path_buf());
        assert_eq!(
            state2.orch.lock().level,
            NudgeLevel::L2,
            "past L1 escalate_after must catch up on boot"
        );
    }

    #[test]
    fn boot_preserves_l3_session() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let today = crate::day_boundary::logical_day_key(now_unix());
        let _ = db.set_setting("nudges_fired_today_day", &today);
        let _ = db.set_setting("quiet_hours_start", "");
        let _ = db.set_setting("quiet_hours_end", "");
        let mut orch = OrchestratorState::default();
        orch.level = NudgeLevel::L3;
        orch.escalate_after_unix = None;
        orch.l3_presentations_today = 1;
        save_orchestrator(&db, &orch, Some(now_unix() - 30));
        let state = AppState::new(db, dir.path().to_path_buf());
        assert_eq!(state.orch.lock().level, NudgeLevel::L3);
        assert_eq!(state.orch.lock().l3_presentations_today, 1);
    }

    #[test]
    fn boot_syncs_guards_from_settings_deadlines() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let today = crate::day_boundary::logical_day_key(now_unix());
        let _ = db.set_setting("nudges_fired_today_day", &today);
        let until = now_unix() + 3600;
        let _ = db.set_setting("overwhelm_until", &until.to_string());
        let _ = db.set_setting("pause_nudges_until", &until.to_string());
        let _ = db.set_setting("companion_enabled", "0");
        let _ = db.set_setting("nudges_fired_today", "3");
        let _ = db.set_setting("daily_nudge_budget", "10");
        // Orch snapshot has stale cleared guards — boot must resync.
        let mut orch = OrchestratorState::default();
        orch.guards.overwhelm = false;
        orch.guards.paused = false;
        orch.guards.companion_enabled = true;
        orch.guards.daily_budget_remaining = 10;
        save_orchestrator(&db, &orch, Some(now_unix() - 600));

        let state = AppState::new(db, dir.path().to_path_buf());
        let g = state.orch.lock().guards.clone();
        assert!(g.overwhelm, "boot must sync overwhelm from settings");
        assert!(g.paused, "boot must sync pause from settings");
        assert!(!g.companion_enabled);
        assert_eq!(g.daily_budget_remaining, 7);
        assert_eq!(g.cooldown_until_unix, Some(until));
        assert_eq!(g.minutes_since_last_nudge, Some(10));
    }
}
