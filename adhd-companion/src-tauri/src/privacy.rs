//! Privacy suite — app/title blocklist, incognito, DRM pause.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivacyRules {
    pub app_blocklist: Vec<String>,
    pub title_blocklist: Vec<String>,
    pub browser_bundle_ids: Vec<String>,
    pub drm_bundle_ids: Vec<String>,
    pub incognito_title_markers: Vec<String>,
    pub incognito_mode: String, // skip | redact
}

impl Default for PrivacyRules {
    fn default() -> Self {
        Self {
            app_blocklist: vec![],
            title_blocklist: vec![],
            browser_bundle_ids: vec![
                "com.apple.Safari".into(),
                "com.google.Chrome".into(),
                "com.brave.Browser".into(),
                "company.thebrowser.Browser".into(),
                "org.mozilla.firefox".into(),
                "com.microsoft.edgemac".into(),
            ],
            drm_bundle_ids: vec![
                "com.netflix.Netflix".into(),
                "com.apple.TV".into(),
                "com.disney.disneyplus".into(),
                "com.hulu.plus".into(),
                "com.amazon.aiv.AIVApp".into(),
                "tv.twitch.desktop".into(),
            ],
            incognito_title_markers: vec![
                "Incognito".into(),
                "InPrivate".into(),
                "Private Browsing".into(),
                "Private Window".into(),
            ],
            incognito_mode: "skip".into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum PrivacyDecision {
    Allow,
    Redact { reason: String },
    Skip { reason: String },
    PauseCapture { reason: String },
}

fn norm(s: &str) -> String {
    s.trim().to_lowercase()
}

pub fn is_app_blocked(bundle_id: Option<&str>, rules: &PrivacyRules) -> bool {
    let Some(bundle_id) = bundle_id else {
        return false;
    };
    let b = norm(bundle_id);
    rules.app_blocklist.iter().any(|x| norm(x) == b)
}

pub fn is_title_blocked(title: Option<&str>, rules: &PrivacyRules) -> bool {
    let Some(title) = title else {
        return false;
    };
    let t = norm(title);
    if t.is_empty() {
        return false;
    }
    rules.title_blocklist.iter().any(|rule| {
        let r = norm(rule);
        !r.is_empty() && t.contains(&r)
    })
}

pub fn is_incognito_window(
    bundle_id: Option<&str>,
    title: Option<&str>,
    rules: &PrivacyRules,
) -> bool {
    let Some(bundle_id) = bundle_id else {
        return false;
    };
    let b = norm(bundle_id);
    if !rules.browser_bundle_ids.iter().any(|x| norm(x) == b) {
        return false;
    }
    let t = title.unwrap_or("");
    rules
        .incognito_title_markers
        .iter()
        .any(|marker| t.to_lowercase().contains(&marker.to_lowercase()))
}

pub fn is_drm_focus(bundle_id: Option<&str>, rules: &PrivacyRules) -> bool {
    let Some(bundle_id) = bundle_id else {
        return false;
    };
    let b = norm(bundle_id);
    rules.drm_bundle_ids.iter().any(|x| norm(x) == b)
}

/// Precedence: DRM pause → app blocklist → incognito → title blocklist → allow.
pub fn evaluate_privacy(
    bundle_id: Option<&str>,
    window_title: Option<&str>,
    rules: &PrivacyRules,
) -> PrivacyDecision {
    if is_drm_focus(bundle_id, rules) {
        return PrivacyDecision::PauseCapture {
            reason: "drm".into(),
        };
    }
    if is_app_blocked(bundle_id, rules) {
        return PrivacyDecision::Redact {
            reason: "app_blocklist".into(),
        };
    }
    if is_incognito_window(bundle_id, window_title, rules) {
        return if rules.incognito_mode == "redact" {
            PrivacyDecision::Redact {
                reason: "incognito".into(),
            }
        } else {
            PrivacyDecision::Skip {
                reason: "incognito".into(),
            }
        };
    }
    if is_title_blocked(window_title, rules) {
        return PrivacyDecision::Redact {
            reason: "title_blocklist".into(),
        };
    }
    PrivacyDecision::Allow
}

pub fn should_suppress_l3_for_focus(bundle_id: Option<&str>, rules: &PrivacyRules) -> bool {
    is_drm_focus(bundle_id, rules)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drm_pauses() {
        let rules = PrivacyRules::default();
        let d = evaluate_privacy(Some("com.netflix.Netflix"), Some("Netflix"), &rules);
        assert!(matches!(d, PrivacyDecision::PauseCapture { .. }));
    }

    #[test]
    fn incognito_skips() {
        let rules = PrivacyRules::default();
        let d = evaluate_privacy(
            Some("com.google.Chrome"),
            Some("Docs - Incognito"),
            &rules,
        );
        assert!(matches!(d, PrivacyDecision::Skip { .. }));
    }
}
