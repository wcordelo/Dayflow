//! Living guard computation from wall clock + settings + context.

use chrono::{Local, Timelike};

use crate::db::Database;
use crate::orchestrator::{Confidence, OrchestratorState};
use crate::privacy::PrivacyRules;
use crate::state::AppSettings;

const MEETING_BUNDLES: &[&str] = &[
    "us.zoom.xos",
    "com.microsoft.teams",
    "com.microsoft.teams2",
    "com.apple.FaceTime",
    "com.hnc.Discord", // often meetings; title refine below
];

const MEETING_TITLE: &[&str] = &[
    "zoom meeting",
    "microsoft teams",
    "meet.google.com",
    "in a call",
    "faceTime",
];

pub fn in_quiet_hours(settings: &AppSettings, hour: u32) -> bool {
    let Some(start) = settings.quiet_hours_start else {
        return false;
    };
    let Some(end) = settings.quiet_hours_end else {
        return false;
    };
    if start == end {
        return false;
    }
    if start < end {
        hour >= start && hour < end
    } else {
        // wraps midnight e.g. 22–7
        hour >= start || hour < end
    }
}

pub fn meeting_heuristic(bundle: Option<&str>, title: Option<&str>, url: Option<&str>) -> bool {
    if let Some(b) = bundle {
        if MEETING_BUNDLES.iter().any(|x| x.eq_ignore_ascii_case(b)) {
            // Discord alone is weak — require title cue unless Zoom/Teams/FaceTime
            if b.eq_ignore_ascii_case("com.hnc.Discord") {
                let blob = format!(
                    "{} {}",
                    title.unwrap_or_default(),
                    url.unwrap_or_default()
                )
                .to_lowercase();
                return MEETING_TITLE.iter().any(|t| blob.contains(t));
            }
            return true;
        }
    }
    let blob = format!(
        "{} {}",
        title.unwrap_or_default(),
        url.unwrap_or_default()
    )
    .to_lowercase();
    MEETING_TITLE.iter().any(|t| blob.contains(t))
}

pub fn confidence_threshold(aggressiveness: u8) -> Confidence {
    match aggressiveness {
        0 => Confidence::High,
        2 => Confidence::Low, // still never fires on low verdict path from monitor
        _ => Confidence::Medium,
    }
}

/// Reset daily nudge counter when the logical day (4 AM boundary) rolls over.
pub fn ensure_nudge_budget_day(
    settings: &mut AppSettings,
    db: &Database,
    logical_day: &str,
    orch: &mut OrchestratorState,
) {
    let stored = db
        .get_setting("nudges_fired_today_day")
        .ok()
        .flatten();
    if stored.as_deref() != Some(logical_day) {
        settings.nudges_fired_today = 0;
        orch.l3_presentations_today = 0;
        orch.gentle_mode = false;
        orch.consecutive_ignores = 0;
        let _ = db.set_setting("nudges_fired_today_day", logical_day);
        let _ = db.set_setting("nudges_fired_today", "0");
    }
}

pub fn sync_guards(
    state: &mut OrchestratorState,
    settings: &AppSettings,
    active_priorities: u32,
    bundle: Option<&str>,
    title: Option<&str>,
    url: Option<&str>,
    now_unix: i64,
) {
    let hour = Local::now().hour();
    state.guards.companion_enabled = settings.companion_enabled;
    state.guards.active_priority_count = active_priorities;
    state.guards.quiet_hours = in_quiet_hours(settings, hour);
    let nudges_paused = settings
        .pause_nudges_until
        .map(|t| now_unix < t)
        .unwrap_or(false);
    state.guards.paused = nudges_paused;
    state.guards.overwhelm = settings
        .overwhelm_until
        .map(|t| now_unix < t)
        .unwrap_or(false);
    state.guards.in_meeting = meeting_heuristic(bundle, title, url);
    state.guards.daily_budget_remaining = settings.daily_nudge_budget - settings.nudges_fired_today;
    state.guards.confidence_threshold = confidence_threshold(settings.aggressiveness);
    state.guards.cooldown_until_unix = state.cooldown_until_unix;
    if let Some(until) = settings.pause_nudges_until {
        if now_unix < until {
            state.guards.cooldown_until_unix = Some(until);
        }
    }
}

pub fn default_rules_from_settings(settings: &AppSettings) -> PrivacyRules {
    let mut rules = PrivacyRules::default();
    rules.app_blocklist = settings.app_blocklist.clone();
    rules.title_blocklist = settings.title_blocklist.clone();
    rules.incognito_mode = if settings.ignore_incognito {
        "skip".into()
    } else {
        "redact".into()
    };
    if !settings.pause_on_drm {
        rules.drm_bundle_ids.clear();
    }
    rules
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quiet_hours_wrap() {
        let s = AppSettings {
            quiet_hours_start: Some(22),
            quiet_hours_end: Some(7),
            ..AppSettings::default()
        };
        assert!(in_quiet_hours(&s, 23));
        assert!(in_quiet_hours(&s, 3));
        assert!(!in_quiet_hours(&s, 10));
    }

    #[test]
    fn zoom_is_meeting() {
        assert!(meeting_heuristic(Some("us.zoom.xos"), Some("Zoom"), None));
    }

    #[test]
    fn day_rollover_clears_ignore_streak() {
        let dir = tempfile::tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let mut settings = AppSettings {
            nudges_fired_today: 3,
            ..AppSettings::default()
        };
        let mut orch = OrchestratorState::default();
        orch.consecutive_ignores = 5;
        orch.l3_presentations_today = 2;
        orch.gentle_mode = true;
        let _ = db.set_setting("nudges_fired_today_day", "2024-01-01");
        ensure_nudge_budget_day(&mut settings, &db, "2024-01-02", &mut orch);
        assert_eq!(settings.nudges_fired_today, 0);
        assert_eq!(orch.consecutive_ignores, 0);
        assert_eq!(orch.l3_presentations_today, 0);
        assert!(!orch.gentle_mode);
    }
}
