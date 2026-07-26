//! Rust-resident nudge orchestrator (SPEC_STATE_MACHINE.md / contract v2.3).

use serde::{Deserialize, Serialize};

pub const L1_IGNORE_SECS: i64 = 8 * 60;
pub const L2_IGNORE_SECS: i64 = 10 * 60;
pub const PENDING_ANCHOR_CAP_SECS: i64 = 10 * 60;
pub const COOLDOWN_DOING_IT_SECS: i64 = 45 * 60;
pub const COOLDOWN_SNOOZE_SECS: i64 = 20 * 60;
pub const L3_CIRCUIT_MAX: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum NudgeLevel {
    Idle,
    L1,
    L2,
    L3,
}

impl NudgeLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::L1 => "L1",
            Self::L2 => "L2",
            Self::L3 => "L3",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    Low,
    Medium,
    High,
}

impl Confidence {
    fn rank(self) -> u8 {
        match self {
            Self::Low => 0,
            Self::Medium => 1,
            Self::High => 2,
        }
    }

    pub fn at_least(self, need: Confidence) -> bool {
        self.rank() >= need.rank()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Guards {
    pub companion_enabled: bool,
    pub active_priority_count: u32,
    pub quiet_hours: bool,
    pub paused: bool,
    pub overwhelm: bool,
    pub in_meeting: bool,
    pub daily_budget_remaining: i32,
    pub confidence: Confidence,
    pub confidence_threshold: Confidence,
    pub cooldown_until_unix: Option<i64>,
    pub minutes_since_last_nudge: Option<i64>,
    pub min_minutes_between_nudges: i64,
}

impl Default for Guards {
    fn default() -> Self {
        Self {
            companion_enabled: true,
            active_priority_count: 1,
            quiet_hours: false,
            paused: false,
            overwhelm: false,
            in_meeting: false,
            daily_budget_remaining: 10,
            confidence: Confidence::Medium,
            confidence_threshold: Confidence::Medium,
            cooldown_until_unix: None,
            minutes_since_last_nudge: Some(60),
            min_minutes_between_nudges: 15,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transition {
    pub from: String,
    pub to: String,
    pub at_unix: i64,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrchestratorState {
    pub level: NudgeLevel,
    pub level_entered_at_unix: Option<i64>,
    pub escalate_after_unix: Option<i64>,
    pub pending_drift: bool,
    pub pending_drift_since_unix: Option<i64>,
    pub pending_confidence: Option<Confidence>,
    pub cooldown_until_unix: Option<i64>,
    pub consecutive_ignores: u32,
    pub l3_presentations_today: u32,
    pub gentle_mode: bool,
    pub last_transition: Option<Transition>,
    pub guards: Guards,
}

impl Default for OrchestratorState {
    fn default() -> Self {
        Self {
            level: NudgeLevel::Idle,
            level_entered_at_unix: None,
            escalate_after_unix: None,
            pending_drift: false,
            pending_drift_since_unix: None,
            pending_confidence: None,
            cooldown_until_unix: None,
            consecutive_ignores: 0,
            l3_presentations_today: 0,
            gentle_mode: false,
            last_transition: None,
            guards: Guards::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum OrchEvent {
    DriftDetected { confidence: Confidence },
    EventAnchor { anchor: String },
    Tick,
    Wake,
    L1Clicked,
    Acknowledge { reason: String },
    SetGuards { guards: Guards },
}

pub fn guards_block(state: &OrchestratorState, now: i64) -> Option<&'static str> {
    let g = &state.guards;
    if !g.companion_enabled {
        return Some("companion_disabled");
    }
    if g.overwhelm {
        return Some("overwhelm");
    }
    if g.paused {
        return Some("paused");
    }
    if g.in_meeting {
        return Some("meeting");
    }
    if g.quiet_hours {
        return Some("quiet_hours");
    }
    if g.daily_budget_remaining <= 0 {
        return Some("budget_exhausted");
    }
    if g.active_priority_count < 1 {
        return Some("no_priorities");
    }
    let cd = g.cooldown_until_unix.or(state.cooldown_until_unix);
    if let Some(until) = cd {
        if now < until {
            return Some("cooldown");
        }
    }
    if let Some(mins) = g.minutes_since_last_nudge {
        if mins < g.min_minutes_between_nudges {
            return Some("spacing");
        }
    }
    if !g.confidence.at_least(g.confidence_threshold) {
        return Some("low_confidence");
    }
    None
}

fn transition(state: &mut OrchestratorState, to: NudgeLevel, now: i64, reason: &str) {
    let from = state.level;
    state.last_transition = Some(Transition {
        from: from.as_str().into(),
        to: to.as_str().into(),
        at_unix: now,
        reason: reason.into(),
    });
    state.level = to;
    state.level_entered_at_unix = if to == NudgeLevel::Idle {
        None
    } else {
        Some(now)
    };
    state.escalate_after_unix = match to {
        NudgeLevel::L1 => Some(now + L1_IGNORE_SECS),
        NudgeLevel::L2 => Some(now + L2_IGNORE_SECS),
        _ => None,
    };
    state.pending_drift = false;
    state.pending_drift_since_unix = None;
    state.pending_confidence = None;

    if to == NudgeLevel::L3 && from != NudgeLevel::L3 {
        state.l3_presentations_today += 1;
        if state.l3_presentations_today >= L3_CIRCUIT_MAX {
            state.gentle_mode = true;
        }
    }
}

fn enter_cooldown(state: &mut OrchestratorState, now: i64, reason: &str) {
    let cooldown = match reason {
        "doing_it" => Some(now + COOLDOWN_DOING_IT_SECS),
        "snooze" => Some(now + COOLDOWN_SNOOZE_SECS),
        _ => None,
    };
    transition(state, NudgeLevel::Idle, now, reason);
    state.cooldown_until_unix = cooldown;
    state.guards.cooldown_until_unix = cooldown;
    if matches!(reason, "resolve" | "doing_it" | "snooze") {
        state.consecutive_ignores = 0;
    }
}

fn try_fire_l1(state: &mut OrchestratorState, now: i64, reason: &str) {
    if let Some(block) = guards_block(state, now) {
        state.pending_drift = false;
        state.pending_drift_since_unix = None;
        state.pending_confidence = None;
        state.last_transition = Some(Transition {
            from: state.level.as_str().into(),
            to: state.level.as_str().into(),
            at_unix: now,
            reason: format!("blocked:{block}"),
        });
        return;
    }
    let start = if state.consecutive_ignores >= 3 && !state.gentle_mode {
        NudgeLevel::L2
    } else {
        NudgeLevel::L1
    };
    let start = if state.gentle_mode {
        NudgeLevel::L1
    } else {
        start
    };
    transition(state, start, now, reason);
}

fn maybe_escalate(state: &mut OrchestratorState, now: i64) {
    if !matches!(state.level, NudgeLevel::L1 | NudgeLevel::L2) {
        return;
    }
    let Some(deadline) = state.escalate_after_unix else {
        return;
    };
    if now < deadline {
        return;
    }
    if let Some(block) = guards_block(state, now) {
        enter_cooldown(state, now, "guards_failed");
        if let Some(t) = state.last_transition.as_mut() {
            t.reason = format!("escalate_cancelled:{block}");
        }
        return;
    }
    match state.level {
        NudgeLevel::L1 => {
            state.consecutive_ignores += 1;
            transition(state, NudgeLevel::L2, now, "ignore>=8m");
        }
        NudgeLevel::L2 => {
            if state.gentle_mode {
                enter_cooldown(state, now, "circuit_breaker");
            } else {
                state.consecutive_ignores += 1;
                transition(state, NudgeLevel::L3, now, "ignore>=10m");
            }
        }
        _ => {}
    }
}

pub fn reduce(state: &mut OrchestratorState, event: OrchEvent, now: i64) {
    match event {
        OrchEvent::SetGuards { guards } => {
            state.guards = guards;
        }
        OrchEvent::DriftDetected { confidence } => {
            if state.level != NudgeLevel::Idle {
                return;
            }
            state.guards.confidence = confidence;
            if confidence == Confidence::Low {
                state.last_transition = Some(Transition {
                    from: "idle".into(),
                    to: "idle".into(),
                    at_unix: now,
                    reason: "drift_low_confidence_ignored".into(),
                });
                return;
            }
            state.pending_drift = true;
            state.pending_drift_since_unix = Some(now);
            state.pending_confidence = Some(confidence);
        }
        OrchEvent::EventAnchor { anchor } => {
            if state.level != NudgeLevel::Idle || !state.pending_drift {
                return;
            }
            if let Some(c) = state.pending_confidence {
                state.guards.confidence = c;
            }
            try_fire_l1(state, now, &format!("anchor:{anchor}"));
        }
        OrchEvent::Tick | OrchEvent::Wake => {
            if let Some(cd) = state.cooldown_until_unix {
                if now >= cd {
                    state.cooldown_until_unix = None;
                    state.guards.cooldown_until_unix = None;
                }
            }
            if state.pending_drift && state.level == NudgeLevel::Idle {
                if let Some(since) = state.pending_drift_since_unix {
                    if now - since >= PENDING_ANCHOR_CAP_SECS {
                        if let Some(c) = state.pending_confidence {
                            state.guards.confidence = c;
                        }
                        try_fire_l1(state, now, "pending_anchor_cap");
                    }
                }
            }
            let before = state.level;
            maybe_escalate(state, now);
            if matches!(event, OrchEvent::Wake) && state.level != NudgeLevel::Idle {
                if let Some(block) = guards_block(state, now) {
                    let from = before;
                    enter_cooldown(state, now, "guards_failed");
                    state.last_transition = Some(Transition {
                        from: from.as_str().into(),
                        to: "idle".into(),
                        at_unix: now,
                        reason: format!("wake_cancel:{block}"),
                    });
                }
            }
        }
        OrchEvent::L1Clicked => {
            if state.level == NudgeLevel::L1 {
                transition(state, NudgeLevel::L2, now, "l1_clicked");
            }
        }
        OrchEvent::Acknowledge { reason } => {
            if reason == "priorities_changed" {
                transition(state, NudgeLevel::Idle, now, "priorities_changed");
                state.cooldown_until_unix = None;
                state.consecutive_ignores = 0;
            } else {
                enter_cooldown(state, now, &reason);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_to_l1_on_anchor() {
        let mut s = OrchestratorState::default();
        reduce(
            &mut s,
            OrchEvent::DriftDetected {
                confidence: Confidence::High,
            },
            1000,
        );
        reduce(
            &mut s,
            OrchEvent::EventAnchor {
                anchor: "app_switch".into(),
            },
            1000,
        );
        assert_eq!(s.level, NudgeLevel::L1);
        assert_eq!(s.escalate_after_unix, Some(1000 + L1_IGNORE_SECS));
    }

    #[test]
    fn low_confidence_never_fires() {
        let mut s = OrchestratorState::default();
        reduce(
            &mut s,
            OrchEvent::DriftDetected {
                confidence: Confidence::Low,
            },
            1000,
        );
        reduce(
            &mut s,
            OrchEvent::EventAnchor {
                anchor: "app_switch".into(),
            },
            1000,
        );
        assert_eq!(s.level, NudgeLevel::Idle);
    }

    #[test]
    fn escalate_l1_l2_l3() {
        let mut s = OrchestratorState::default();
        reduce(
            &mut s,
            OrchEvent::DriftDetected {
                confidence: Confidence::Medium,
            },
            0,
        );
        reduce(
            &mut s,
            OrchEvent::EventAnchor {
                anchor: "idle_return".into(),
            },
            0,
        );
        reduce(&mut s, OrchEvent::Tick, L1_IGNORE_SECS);
        assert_eq!(s.level, NudgeLevel::L2);
        reduce(&mut s, OrchEvent::Tick, L1_IGNORE_SECS + L2_IGNORE_SECS);
        assert_eq!(s.level, NudgeLevel::L3);
    }

    #[test]
    fn doing_it_cooldown_45m() {
        let mut s = OrchestratorState::default();
        reduce(
            &mut s,
            OrchEvent::DriftDetected {
                confidence: Confidence::High,
            },
            0,
        );
        reduce(
            &mut s,
            OrchEvent::EventAnchor {
                anchor: "app_switch".into(),
            },
            0,
        );
        reduce(
            &mut s,
            OrchEvent::Acknowledge {
                reason: "doing_it".into(),
            },
            10,
        );
        assert_eq!(s.level, NudgeLevel::Idle);
        assert_eq!(s.cooldown_until_unix, Some(10 + COOLDOWN_DOING_IT_SECS));
    }
}
