//! Pipe-shaped engines: checkin / analyze / monitor / brief.
//! Prompts live in ../prompts/*.md — runners load them for LLM calls when a key is present.

use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::day_boundary::{logical_day_key, now_unix};
use crate::db::Database;
use crate::monitor::{evaluate_alignment, CaptureContext, MonitorResult};
use crate::orchestrator::{Confidence, OrchEvent, OrchestratorState};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnalyzeBatchResult {
    pub cards_created: usize,
    pub observations: usize,
    pub used_llm: bool,
    pub summary: String,
}

pub fn prompts_dir() -> PathBuf {
    // Dev: repo prompts/; bundled: resource dir — resolve relative to CARGO_MANIFEST_DIR
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../prompts")
}

pub fn load_prompt(name: &str) -> Result<String, String> {
    let path = prompts_dir().join(format!("{name}.md"));
    fs::read_to_string(&path).map_err(|e| format!("prompt {name}: {e}"))
}

/// Slow path — heuristic batch without Gemini when no key; still writes timeline cards.
pub fn run_analyze(db: &Database, day: Option<&str>) -> Result<AnalyzeBatchResult, String> {
    let _prompt = load_prompt("analyze")?;
    let day = day
        .map(|s| s.to_string())
        .unwrap_or_else(|| logical_day_key(now_unix()));
    let shots = db.list_screenshots(&day, 200).map_err(|e| e.to_string())?;
    if shots.is_empty() {
        db.log_llm_call(&day, "timeline", "analyze_batch", "skipped", None, "no screenshots")
            .ok();
        return Ok(AnalyzeBatchResult {
            cards_created: 0,
            observations: 0,
            used_llm: false,
            summary: "No screenshots yet for this day.".into(),
        });
    }

    db.replace_analyze_timeline_cards(&day)
        .map_err(|e| e.to_string())?;

    // Group by bundle for a simple local card (Gemini path plugs in later)
    use std::collections::BTreeMap;
    let mut by_bundle: BTreeMap<String, Vec<&crate::db::ScreenshotRow>> = BTreeMap::new();
    for s in &shots {
        if s.redacted != 0 {
            continue;
        }
        let key = s
            .frontmost_bundle_id
            .clone()
            .unwrap_or_else(|| "unknown".into());
        by_bundle.entry(key).or_default().push(s);
    }

    let mut cards = 0usize;
    for (bundle, group) in by_bundle {
        let start = group.iter().map(|g| g.captured_at).min().unwrap_or(0);
        let end = group.iter().map(|g| g.captured_at).max().unwrap_or(start);
        let title = group
            .iter()
            .find_map(|g| g.window_title.clone())
            .unwrap_or_else(|| bundle.clone());
        let summary = format!(
            "Local analyze: {} captures in {}",
            group.len(),
            bundle
        );
        db.insert_timeline_card(&day, start, end, &title, &summary, Some("local"))
            .map_err(|e| e.to_string())?;
        cards += 1;
    }

    db.log_llm_call(
        &day,
        "timeline",
        "analyze_batch",
        "ok",
        Some(0.0),
        &format!("local cards={cards}"),
    )
    .ok();

    Ok(AnalyzeBatchResult {
        cards_created: cards,
        observations: shots.len(),
        used_llm: false,
        summary: format!("Created {cards} timeline card(s) from local heuristics."),
    })
}

pub fn run_monitor(
    db: &Database,
    state: &mut OrchestratorState,
    ctx: CaptureContext,
) -> Result<MonitorResult, String> {
    let _prompt = load_prompt("monitor")?;
    let day = logical_day_key(now_unix());
    let priorities = db.list_priorities(&day).map_err(|e| e.to_string())?;
    let result = evaluate_alignment(&ctx, &priorities);

    let now = now_unix();
    if result.verdict == "aligned" {
        crate::orchestrator::reduce(state, OrchEvent::Aligned, now);
    } else if result.recommend_nudge {
        let conf = result.confidence;
        crate::orchestrator::reduce(
            state,
            OrchEvent::DriftDetected {
                confidence: conf,
            },
            now,
        );
        if let Some(trigger) = &ctx.capture_trigger {
            if matches!(
                trigger.as_str(),
                "app_switch" | "window_focus" | "idle_return"
            ) {
                crate::orchestrator::reduce(
                    state,
                    OrchEvent::EventAnchor {
                        anchor: trigger.clone(),
                    },
                    now,
                );
            }
        }
    } else if result.verdict == "drift" {
        // Explicit low-confidence drift observation — clear pending (orch rule).
        crate::orchestrator::reduce(
            state,
            OrchEvent::DriftDetected {
                confidence: result.confidence,
            },
            now,
        );
    }
    // verdict == "unknown": leave pending alone so anchor-cap / later anchors
    // can still fire from an earlier actionable drift.
    Ok(result)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckinResult {
    pub day: String,
    pub priorities_saved: usize,
    pub soft_confirm_offered: bool,
    pub prompt_excerpt: String,
}

pub fn run_checkin(db: &Database, texts: Vec<String>) -> Result<CheckinResult, String> {
    let prompt = load_prompt("checkin")?;
    let day = logical_day_key(now_unix());
    db.replace_priorities(&day, &texts, "checkin")
        .map_err(|e| e.to_string())?;
    Ok(CheckinResult {
        day,
        priorities_saved: texts.iter().filter(|t| !t.trim().is_empty()).count(),
        soft_confirm_offered: false,
        prompt_excerpt: prompt.chars().take(120).collect(),
    })
}

pub fn run_soft_confirm(db: &Database) -> Result<usize, String> {
    let now = now_unix();
    let today = logical_day_key(now);
    let yesterday = crate::day_boundary::previous_logical_day_key(now);
    db.soft_confirm_carryover(&yesterday, &today)
        .map_err(|e| e.to_string())
}

pub fn run_brief(db: &Database, day: Option<&str>) -> Result<crate::db::BriefPayload, String> {
    let _prompt = load_prompt("brief")?;
    let day = day
        .map(|s| s.to_string())
        .unwrap_or_else(|| logical_day_key(now_unix()));
    let brief = db.build_evening_brief(&day).map_err(|e| e.to_string())?;
    db.log_llm_call(
        &day,
        "brief",
        "brief",
        "ok",
        Some(0.0),
        "accomplishments_first",
    )
    .ok();
    Ok(brief)
}

pub struct AnalyzeLlmPending {
    pub base: AnalyzeBatchResult,
    pub day_key: String,
    pub system: String,
    pub user: String,
}

pub enum PrepareAnalyzeOutcome {
    Complete(AnalyzeBatchResult),
    Pending(AnalyzeLlmPending),
}

pub fn prepare_analyze_for_llm(
    db: &Database,
    day: Option<&str>,
) -> Result<PrepareAnalyzeOutcome, String> {
    let prompt = load_prompt("analyze")?;
    let base = run_analyze(db, day)?;
    if base.observations == 0 {
        return Ok(PrepareAnalyzeOutcome::Complete(base));
    }
    let day_key = day
        .map(|s| s.to_string())
        .unwrap_or_else(|| logical_day_key(now_unix()));
    let cards = db.list_timeline_cards(&day_key).map_err(|e| e.to_string())?;
    let user = format!(
        "Prompt excerpt:\n{}\n\nCards:\n{}",
        prompt.chars().take(800).collect::<String>(),
        cards
            .iter()
            .map(|c| format!("- {} ({})", c.title, c.summary.clone().unwrap_or_default()))
            .collect::<Vec<_>>()
            .join("\n")
    );
    Ok(PrepareAnalyzeOutcome::Pending(AnalyzeLlmPending {
        base,
        day_key,
        system: "You refine ADHD-companion timeline cards. Be concrete, shame-free, short."
            .into(),
        user,
    }))
}

pub fn finish_analyze_for_llm(
    db: &Database,
    mut pending: AnalyzeLlmPending,
    llm_out: Result<crate::gemini::LlmResponse, String>,
) -> Result<AnalyzeBatchResult, String> {
    let mut base = pending.base;
    match llm_out {
        Ok(resp) => {
            crate::gemini::log_llm(db, "timeline", "analyze_batch", &resp, "ok");
            if resp.used_network {
                base.used_llm = true;
                base.summary = format!(
                    "{} | llm: {}",
                    base.summary,
                    resp.text.chars().take(180).collect::<String>()
                );
            }
            Ok(base)
        }
        Err(e) => {
            db.log_llm_call(
                &pending.day_key,
                "timeline",
                "analyze_batch",
                "error",
                None,
                &e,
            )
            .ok();
            Ok(base)
        }
    }
}

pub fn run_analyze_with_llm(
    db: &Database,
    day: Option<&str>,
    llm: &dyn crate::gemini::LlmClient,
) -> Result<AnalyzeBatchResult, String> {
    match prepare_analyze_for_llm(db, day)? {
        PrepareAnalyzeOutcome::Complete(r) => Ok(r),
        PrepareAnalyzeOutcome::Pending(p) => {
            let llm_out = llm.complete(&p.system, &p.user);
            finish_analyze_for_llm(db, p, llm_out)
        }
    }
}

pub fn run_brief_with_llm(
    db: &Database,
    day: Option<&str>,
    llm: &dyn crate::gemini::LlmClient,
) -> Result<crate::db::BriefPayload, String> {
    let prompt = load_prompt("brief")?;
    let mut brief = run_brief(db, day)?;
    let user = format!(
        "{}\n\nAccomplishments: {:?}\nStill open: {:?}",
        prompt.chars().take(600).collect::<String>(),
        brief.accomplishments,
        brief.still_open
    );
    if let Ok(resp) = llm.complete(
        "Evening brief. Accomplishments first. Never use failure language.",
        &user,
    ) {
        crate::gemini::log_llm(db, "brief", "brief", &resp, "ok");
        if resp.used_network && !resp.text.is_empty() {
            brief.narrative = resp.text;
        }
    }
    Ok(brief)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn unknown_monitor_preserves_pending_drift() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let day = logical_day_key(now_unix());
        db.replace_priorities(&day, &["Write grant proposal".into()], "checkin")
            .unwrap();

        let mut orch = OrchestratorState::default();
        orch.pending_drift = true;
        orch.pending_drift_since_unix = Some(now_unix() - 30);
        orch.pending_confidence = Some(Confidence::High);

        let result = run_monitor(
            &db,
            &mut orch,
            CaptureContext {
                frontmost_bundle_id: Some("com.apple.Safari".into()),
                window_title: Some("Random tab".into()),
                browser_url: None,
                capture_trigger: Some("idle_fallback".into()),
                idle_seconds: Some(1.0),
            },
        )
        .unwrap();
        assert_eq!(result.verdict, "unknown");
        assert!(orch.pending_drift);
        assert_eq!(orch.pending_confidence, Some(Confidence::High));
    }

    #[test]
    fn low_confidence_drift_clears_pending() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let day = logical_day_key(now_unix());
        db.replace_priorities(&day, &["Write grant proposal".into()], "checkin")
            .unwrap();

        let mut orch = OrchestratorState::default();
        orch.pending_drift = true;
        orch.pending_drift_since_unix = Some(now_unix() - 30);
        orch.pending_confidence = Some(Confidence::High);

        let result = run_monitor(
            &db,
            &mut orch,
            CaptureContext {
                frontmost_bundle_id: Some("com.spotify.client".into()),
                window_title: Some("Discover".into()),
                browser_url: None,
                capture_trigger: None,
                idle_seconds: Some(1.0),
            },
        )
        .unwrap();
        assert_eq!(result.verdict, "drift");
        assert!(!result.recommend_nudge);
        assert!(!orch.pending_drift);
    }
}
