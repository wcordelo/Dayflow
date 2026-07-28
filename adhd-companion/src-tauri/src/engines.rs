//! Pipe-shaped engines: checkin / analyze / monitor / brief.
//! Prompts live in ../prompts/*.md — runners load them for LLM calls when a key is present.

use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::day_boundary::{logical_day_key, now_unix};
use crate::db::Database;
use crate::monitor::{evaluate_alignment, CaptureContext, MonitorResult};
use crate::orchestrator::{OrchEvent, OrchestratorState};
#[cfg(test)]
use crate::orchestrator::Confidence;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnalyzeBatchResult {
    pub cards_created: usize,
    pub observations: usize,
    pub used_llm: bool,
    pub summary: String,
}

pub fn prompts_dir() -> PathBuf {
    // Dev checkout: adhd-companion/prompts next to src-tauri.
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../prompts")
}

/// Load an engine prompt. Prefer on-disk files in development; always fall back
/// to prompts embedded at compile time so packaged builds never fail when the
/// repo `prompts/` tree is absent beside the binary.
pub fn load_prompt(name: &str) -> Result<String, String> {
    let path = prompts_dir().join(format!("{name}.md"));
    if let Ok(s) = fs::read_to_string(&path) {
        return Ok(s);
    }
    let embedded = match name {
        "analyze" => Some(include_str!("../../prompts/analyze.md")),
        "monitor" => Some(include_str!("../../prompts/monitor.md")),
        "checkin" => Some(include_str!("../../prompts/checkin.md")),
        "brief" => Some(include_str!("../../prompts/brief.md")),
        _ => None,
    };
    embedded
        .map(|s| s.to_string())
        .ok_or_else(|| format!("unknown prompt {name}"))
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
        // Low-confidence drift (never fires). Orch preserves any stronger pending.
        crate::orchestrator::reduce(
            state,
            OrchEvent::DriftDetected {
                confidence: result.confidence,
            },
            now,
        );
    }
    // unknown leaves pending alone. If pending is still waiting and this capture
    // carries an event anchor, fire it (do not wait solely for the 10m cap).
    if state.pending_drift {
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
    }
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
        "Prompt excerpt:\n{}\n\nCards:\n{}\n\nReturn ONLY valid JSON with keys observations, timeline_cards, skipped_reason per the analyze schema.",
        prompt.chars().take(800).collect::<String>(),
        cards
            .iter()
            .map(|c| format!(
                "- id={} start={} end={} title={} summary={}",
                c.id,
                c.start_time,
                c.end_time,
                c.title,
                c.summary.clone().unwrap_or_default()
            ))
            .collect::<Vec<_>>()
            .join("\n")
    );
    Ok(PrepareAnalyzeOutcome::Pending(AnalyzeLlmPending {
        base,
        day_key,
        system: "You refine ADHD-companion timeline cards. Be concrete, shame-free, short. Output only JSON matching the analyze schema (timeline_cards with start/end as unix seconds or ISO-8601, title, summary)."
            .into(),
        user,
    }))
}

#[derive(Debug, Deserialize)]
struct AnalyzeLlmCard {
    title: Option<String>,
    summary: Option<String>,
    start: Option<serde_json::Value>,
    end: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct AnalyzeLlmPayload {
    #[serde(default)]
    timeline_cards: Vec<AnalyzeLlmCard>,
    #[serde(default)]
    observations: Vec<serde_json::Value>,
    #[serde(default)]
    skipped_reason: Option<String>,
}

fn extract_json_object(text: &str) -> Option<&str> {
    let t = text.trim();
    let start = t.find('{')?;
    let end = t.rfind('}')?;
    if end < start {
        return None;
    }
    Some(&t[start..=end])
}

fn parse_time_value(v: &Option<serde_json::Value>, fallback: i64) -> i64 {
    let Some(v) = v else {
        return fallback;
    };
    if let Some(n) = v.as_i64() {
        return n;
    }
    if let Some(n) = v.as_f64() {
        return n as i64;
    }
    if let Some(s) = v.as_str() {
        if let Ok(n) = s.parse::<i64>() {
            return n;
        }
        if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
            return dt.timestamp();
        }
        if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S") {
            return dt.and_utc().timestamp();
        }
    }
    fallback
}

/// Apply Gemini/network analyze JSON onto SQLite timeline_cards (sliding-window replace).
fn apply_analyze_llm_cards(
    db: &Database,
    day_key: &str,
    text: &str,
    fallback_start: i64,
    fallback_end: i64,
) -> Result<Option<(usize, usize)>, String> {
    let Some(json) = extract_json_object(text) else {
        return Ok(None);
    };
    let parsed: AnalyzeLlmPayload = match serde_json::from_str(json) {
        Ok(p) => p,
        Err(_) => return Ok(None),
    };
    if parsed
        .skipped_reason
        .as_deref()
        .filter(|s| !s.is_empty() && *s != "null")
        .is_some()
        && parsed.timeline_cards.is_empty()
    {
        return Ok(None);
    }
    if parsed.timeline_cards.is_empty() {
        return Ok(None);
    }

    db.replace_analyze_timeline_cards(day_key)
        .map_err(|e| e.to_string())?;
    let mut cards = 0usize;
    for c in parsed.timeline_cards {
        let title = c
            .title
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("Activity");
        let summary = c.summary.clone().unwrap_or_default();
        let start = parse_time_value(&c.start, fallback_start);
        let end = parse_time_value(&c.end, fallback_end).max(start);
        db.insert_timeline_card(day_key, start, end, title, &summary, Some("gemini"))
            .map_err(|e| e.to_string())?;
        cards += 1;
    }
    Ok(Some((cards, parsed.observations.len())))
}

pub fn finish_analyze_for_llm(
    db: &Database,
    pending: AnalyzeLlmPending,
    llm_out: Result<crate::gemini::LlmResponse, String>,
) -> Result<AnalyzeBatchResult, String> {
    let mut base = pending.base;
    match llm_out {
        Ok(resp) => {
            crate::gemini::log_llm(db, "timeline", "analyze_batch", &resp, "ok");
            if resp.used_network {
                base.used_llm = true;
                let now = now_unix();
                match apply_analyze_llm_cards(
                    db,
                    &pending.day_key,
                    &resp.text,
                    now - 15 * 60,
                    now,
                )? {
                    Some((cards, obs)) => {
                        base.cards_created = cards;
                        if obs > 0 {
                            base.observations = obs;
                        }
                        base.summary = format!(
                            "Created {cards} timeline card(s) from Gemini analyze."
                        );
                    }
                    None => {
                        // Keep heuristic cards in SQLite; surface a truncated note only.
                        base.summary = format!(
                            "{} | llm(unparsed): {}",
                            base.summary,
                            resp.text.chars().take(120).collect::<String>()
                        );
                    }
                }
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
    fn pending_unknown_with_anchor_fires_l1() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let day = logical_day_key(now_unix());
        db.replace_priorities(&day, &["Write grant proposal".into()], "checkin")
            .unwrap();

        let mut orch = OrchestratorState::default();
        orch.guards.minutes_since_last_nudge = Some(60);
        orch.guards.min_minutes_between_nudges = 0;
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
                capture_trigger: Some("app_switch".into()),
                idle_seconds: Some(1.0),
            },
        )
        .unwrap();
        assert_eq!(result.verdict, "unknown");
        assert_eq!(orch.level, crate::orchestrator::NudgeLevel::L1);
        assert!(!orch.pending_drift);
    }

    #[test]
    fn low_confidence_drift_preserves_stronger_pending() {
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
        assert!(orch.pending_drift);
        assert_eq!(orch.pending_confidence, Some(Confidence::High));
    }

    #[test]
    fn finish_analyze_writes_gemini_cards_to_db() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let day = logical_day_key(now_unix());
        let now = now_unix();
        db.insert_screenshot(
            now - 60,
            "app_switch",
            Some("com.apple.Safari"),
            Some("Docs"),
            None,
            false,
            None,
            None,
            Some("h1"),
            Some(1.0),
            None,
        )
        .unwrap();
        let base = run_analyze(&db, Some(&day)).unwrap();
        assert!(base.cards_created >= 1);
        let local = db.list_timeline_cards(&day).unwrap();
        assert!(!local.is_empty());
        assert_eq!(local[0].category.as_deref(), Some("local"));

        let pending = AnalyzeLlmPending {
            base,
            day_key: day.clone(),
            system: "sys".into(),
            user: "user".into(),
        };
        let llm = crate::gemini::LlmResponse {
            text: format!(
                "```json\n{{\n  \"observations\": [{{\"note\":\"reading\"}}],\n  \"timeline_cards\": [{{\n    \"start\": {},\n    \"end\": {},\n    \"title\": \"Refined docs\",\n    \"summary\": \"Worked on proposal docs\"\n  }}],\n  \"skipped_reason\": null\n}}\n```",
                now - 120,
                now
            ),
            model: "test".into(),
            prompt_tokens: Some(1),
            completion_tokens: Some(1),
            cost_usd: Some(0.0),
            used_network: true,
        };
        let out = finish_analyze_for_llm(&db, pending, Ok(llm)).unwrap();
        assert!(out.used_llm);
        assert_eq!(out.cards_created, 1);
        let cards = db.list_timeline_cards(&day).unwrap();
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].title, "Refined docs");
        assert_eq!(cards[0].category.as_deref(), Some("gemini"));
        assert!(cards[0]
            .summary
            .as_deref()
            .unwrap_or("")
            .contains("proposal"));
    }

    #[test]
    fn load_prompt_embeds_core_engines() {
        for name in ["analyze", "monitor", "checkin", "brief"] {
            let body = load_prompt(name).expect(name);
            assert!(body.len() > 80, "{name} too short");
        }
        assert!(load_prompt("does-not-exist").is_err());
    }
}
