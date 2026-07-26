//! Shared app state.

use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

use crate::bus::EventBus;
use crate::capture::CaptureService;
use crate::db::{Database, DbError};
use crate::orchestrator::OrchestratorState;

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
        if stored_day.as_deref() != Some(today.as_str()) {
            s.nudges_fired_today = 0;
            let _ = db.set_setting("nudges_fired_today_day", &today);
            let _ = db.set_setting("nudges_fired_today", "0");
        }
        let capture = CaptureService::new();
        capture.set_rules(crate::guards::default_rules_from_settings(&s));
        let now = crate::day_boundary::now_unix();
        if s.pause_capture_until.map(|t| now < t).unwrap_or(false) {
            capture
                .pause_capture
                .store(true, std::sync::atomic::Ordering::SeqCst);
        }
        Self {
            db: Mutex::new(db),
            orch: Mutex::new(OrchestratorState::default()),
            capture,
            settings: Mutex::new(s),
            bus: EventBus::new(200),
            focus: Mutex::new(FocusContext::default()),
            runtime_stop: Arc::new(AtomicBool::new(false)),
            last_nudge_present_unix: Mutex::new(None),
            last_analyze_unix: Mutex::new(None),
            data_dir,
        }
    }
}
