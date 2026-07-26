//! Phase-1 local alignment monitor (no Gemini).

use serde::{Deserialize, Serialize};

use crate::orchestrator::Confidence;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Priority {
    pub id: i64,
    pub text: String,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaptureContext {
    pub frontmost_bundle_id: Option<String>,
    pub window_title: Option<String>,
    pub browser_url: Option<String>,
    pub capture_trigger: Option<String>,
    pub idle_seconds: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MonitorResult {
    pub verdict: String, // aligned | drift | unknown
    pub confidence: Confidence,
    pub recommend_nudge: bool,
    pub evidence: Vec<String>,
}

const STRONG_DRIFT_BUNDLES: &[&str] = &[
    "com.hnc.Discord",
    "com.tinyspeck.slackmacgap",
    "com.spotify.client",
    "com.netflix.Netflix",
    "com.apple.TV",
    "com.reddit.Reddit",
    "com.twitter.twitter-mac",
    "ru.keepcoder.Telegram",
];

const STRONG_DRIFT_TITLE: &[&str] = &[
    "youtube", "twitter", "x.com", "instagram", "tiktok", "reddit", "facebook", "netflix", "twitch",
];

const ANCHORS: &[&str] = &["app_switch", "window_focus", "idle_return"];

pub fn evaluate_alignment(ctx: &CaptureContext, priorities: &[Priority]) -> MonitorResult {
    let mut evidence = Vec::new();
    let active: Vec<_> = priorities
        .iter()
        .filter(|p| p.status == "active")
        .collect();
    if active.is_empty() {
        evidence.push("no_active_priorities".into());
        return MonitorResult {
            verdict: "unknown".into(),
            confidence: Confidence::Low,
            recommend_nudge: false,
            evidence,
        };
    }

    let bundle = ctx.frontmost_bundle_id.clone().unwrap_or_default();
    let title = ctx.window_title.clone().unwrap_or_default();
    let url = ctx.browser_url.clone().unwrap_or_default();
    let blob = format!("{title} {url}").to_lowercase();

    if let Some(idle) = ctx.idle_seconds {
        if idle >= 300.0 {
            evidence.push("long_idle".into());
            return MonitorResult {
                verdict: "unknown".into(),
                confidence: Confidence::Low,
                recommend_nudge: false,
                evidence,
            };
        }
    }

    for p in &active {
        let hit = p
            .text
            .to_lowercase()
            .split_whitespace()
            .filter(|t| t.len() >= 4)
            .any(|t| blob.contains(t));
        if hit {
            evidence.push("priority_token_in_title".into());
            return MonitorResult {
                verdict: "aligned".into(),
                confidence: Confidence::Medium,
                recommend_nudge: false,
                evidence,
            };
        }
    }

    let on_drift_bundle = STRONG_DRIFT_BUNDLES
        .iter()
        .any(|b| b.eq_ignore_ascii_case(&bundle));
    let on_drift_title = STRONG_DRIFT_TITLE.iter().any(|t| blob.contains(t));

    if on_drift_bundle && on_drift_title {
        evidence.push("drift_bundle_and_title".into());
        return MonitorResult {
            verdict: "drift".into(),
            confidence: Confidence::High,
            recommend_nudge: true,
            evidence,
        };
    }
    if on_drift_bundle || on_drift_title {
        evidence.push(if on_drift_bundle {
            "drift_bundle".into()
        } else {
            "drift_title".into()
        });
        let anchored = ctx
            .capture_trigger
            .as_deref()
            .map(|t| ANCHORS.contains(&t))
            .unwrap_or(false);
        if anchored {
            evidence.push(format!(
                "anchor:{}",
                ctx.capture_trigger.as_deref().unwrap_or("")
            ));
            return MonitorResult {
                verdict: "drift".into(),
                confidence: Confidence::Medium,
                recommend_nudge: true,
                evidence,
            };
        }
        evidence.push("no_event_anchor".into());
        return MonitorResult {
            verdict: "drift".into(),
            confidence: Confidence::Low,
            recommend_nudge: false,
            evidence,
        };
    }

    evidence.push("no_strong_signal".into());
    MonitorResult {
        verdict: "unknown".into(),
        confidence: Confidence::Low,
        recommend_nudge: false,
        evidence,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn low_confidence_no_nudge() {
        let r = evaluate_alignment(
            &CaptureContext {
                frontmost_bundle_id: Some("com.spotify.client".into()),
                window_title: Some("Discover".into()),
                browser_url: None,
                capture_trigger: None,
                idle_seconds: Some(1.0),
            },
            &[Priority {
                id: 1,
                text: "Write proposal".into(),
                status: "active".into(),
            }],
        );
        assert_eq!(r.confidence, Confidence::Low);
        assert!(!r.recommend_nudge);
    }
}
