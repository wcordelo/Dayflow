//! End-to-end pipeline (capture → monitor → orch) — unit/E2E testable without Tauri UI.

use serde::{Deserialize, Serialize};

use crate::capture::{CaptureEvent, CaptureResult, CaptureService};
use crate::day_boundary::{logical_day_key, now_unix};
use crate::db::Database;
use crate::engines::{run_analyze_with_llm, run_brief_with_llm, run_monitor};
use crate::gemini::{select_client, LlmClient};
use crate::guards::{ensure_nudge_budget_day, sync_guards};
use crate::monitor::{CaptureContext, MonitorResult};
use crate::orchestrator::{NudgeLevel, OrchEvent, OrchestratorState};
use crate::privacy::should_suppress_l3_for_focus;
use crate::state::{AppSettings, FocusContext};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PipelineStepResult {
    pub capture: Option<CaptureResult>,
    pub monitor: Option<MonitorResult>,
    pub level_before: String,
    pub level_after: String,
    pub presented_l1: bool,
    pub should_show_l2: bool,
    pub should_show_l3: bool,
    pub suppressed_l3_drm: bool,
}

pub struct Pipeline<'a> {
    pub db: &'a Database,
    pub capture: &'a CaptureService,
    pub orch: &'a mut OrchestratorState,
    pub settings: &'a mut AppSettings,
    pub focus: &'a mut FocusContext,
    pub data_dir: &'a std::path::Path,
    pub last_nudge_present_unix: &'a mut Option<i64>,
}

impl<'a> Pipeline<'a> {
    pub fn ingest_capture(&mut self, event: CaptureEvent) -> Result<PipelineStepResult, String> {
        let level_before = self.orch.level.as_str().to_string();
        self.focus.bundle_id = event.bundle_id.clone();
        self.focus.title = event.window_title.clone();
        self.focus.url = event.browser_url.clone();
        self.capture
            .on_focus_changed(event.bundle_id.as_deref());

        let day = logical_day_key(now_unix());
        ensure_nudge_budget_day(self.settings, self.db, &day, self.orch);
        let priorities = self.db.list_priorities(&day).map_err(|e| e.to_string())?;
        sync_guards(
            self.orch,
            self.settings,
            priorities.iter().filter(|p| p.status == "active").count() as u32,
            event.bundle_id.as_deref(),
            event.window_title.as_deref(),
            event.browser_url.as_deref(),
            now_unix(),
        );
        if let Some(last) = *self.last_nudge_present_unix {
            self.orch.guards.minutes_since_last_nudge =
                Some(((now_unix() - last) / 60).max(0));
        }

        let now = now_unix();
        let capture = self.capture.handle_event(
            self.db,
            event.clone(),
            self.settings.pause_capture_until,
            now,
        )?;
        let mut presented_l1 = false;

        let ctx = CaptureContext {
            frontmost_bundle_id: event.bundle_id.clone(),
            window_title: event.window_title.clone(),
            browser_url: event.browser_url.clone(),
            capture_trigger: Some(event.trigger.clone()),
            idle_seconds: event.idle_seconds,
        };
        let m = run_monitor(self.db, self.orch, ctx)?;
        if m.recommend_nudge
            && self.orch.level != NudgeLevel::Idle
            && level_before == "idle"
        {
            presented_l1 = self.orch.level == NudgeLevel::L1
                || self.orch.level == NudgeLevel::L2;
            if presented_l1 {
                self.settings.nudges_fired_today += 1;
                *self.last_nudge_present_unix = Some(now_unix());
                let _ = self.db.set_setting(
                    "nudges_fired_today",
                    &self.settings.nudges_fired_today.to_string(),
                );
                let _ = self.db.log_nudge_event(
                    &day,
                    self.orch.level.as_str(),
                    Some("idle"),
                    "present",
                    Some("monitor_drift"),
                    Some(match m.confidence {
                        crate::orchestrator::Confidence::Low => "low",
                        crate::orchestrator::Confidence::Medium => "medium",
                        crate::orchestrator::Confidence::High => "high",
                    }),
                    self.orch.escalate_after_unix,
                );
            }
        }
        let monitor = Some(m);

        let rules = self.capture.rules.read().clone();
        let suppressed_l3_drm =
            should_suppress_l3_for_focus(self.focus.bundle_id.as_deref(), &rules);
        let level_after = self.orch.level.as_str().to_string();

        Ok(PipelineStepResult {
            capture: Some(capture),
            monitor,
            level_before,
            level_after: level_after.clone(),
            presented_l1,
            should_show_l2: level_after == "L2",
            should_show_l3: level_after == "L3" && !suppressed_l3_drm,
            suppressed_l3_drm,
        })
    }

    pub fn tick(&mut self) -> PipelineStepResult {
        let level_before = self.orch.level.as_str().to_string();
        let day = logical_day_key(now_unix());
        ensure_nudge_budget_day(self.settings, self.db, &day, self.orch);
        let priorities = self.db.list_priorities(&day).unwrap_or_default();
        sync_guards(
            self.orch,
            self.settings,
            priorities.iter().filter(|p| p.status == "active").count() as u32,
            self.focus.bundle_id.as_deref(),
            self.focus.title.as_deref(),
            self.focus.url.as_deref(),
            now_unix(),
        );
        crate::orchestrator::reduce(self.orch, OrchEvent::Tick, now_unix());
        let rules = self.capture.rules.read().clone();
        let suppressed_l3_drm =
            should_suppress_l3_for_focus(self.focus.bundle_id.as_deref(), &rules);
        let level_after = self.orch.level.as_str().to_string();
        PipelineStepResult {
            capture: None,
            monitor: None,
            level_before,
            level_after: level_after.clone(),
            presented_l1: false,
            should_show_l2: level_after == "L2",
            should_show_l3: level_after == "L3" && !suppressed_l3_drm,
            suppressed_l3_drm,
        }
    }

    pub fn wake(&mut self) -> PipelineStepResult {
        let level_before = self.orch.level.as_str().to_string();
        // Resume capture after unlock unless pause-watching
        if self.capture.pause_nudges_only.load(std::sync::atomic::Ordering::SeqCst) {
            self.capture
                .pause_capture
                .store(false, std::sync::atomic::Ordering::SeqCst);
        }
        crate::orchestrator::reduce(self.orch, OrchEvent::Wake, now_unix());
        let level_after = self.orch.level.as_str().to_string();
        PipelineStepResult {
            capture: None,
            monitor: None,
            level_before,
            level_after,
            presented_l1: false,
            should_show_l2: false,
            should_show_l3: false,
            suppressed_l3_drm: false,
        }
    }

    pub fn sleep_lock(&mut self) {
        self.capture
            .pause_capture
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    pub fn run_analyze(&self) -> Result<crate::engines::AnalyzeBatchResult, String> {
        let client = select_client(self.data_dir, self.settings.gemini_analysis_opt_in);
        run_analyze_with_llm(self.db, None, client.as_ref())
    }

    pub fn run_brief(&self) -> Result<crate::db::BriefPayload, String> {
        let client = select_client(self.data_dir, self.settings.gemini_analysis_opt_in);
        run_brief_with_llm(self.db, None, client.as_ref())
    }

    pub fn llm(&self) -> Box<dyn LlmClient> {
        select_client(self.data_dir, self.settings.gemini_analysis_opt_in)
    }
}
