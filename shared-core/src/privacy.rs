use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum SkipReason {
    PermissionMissing,
    UserPaused,
    DeviceLocked,
    Sleep,
    PrivateContext,
    DrmContent,
    BlockedApplication,
    BlockedWindowTitle,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct CaptureContext {
    pub permission_granted: bool,
    pub user_paused: bool,
    pub device_locked: bool,
    pub sleeping: bool,
    pub private_context: bool,
    pub drm_content: bool,
    pub application_id: Option<String>,
    pub window_title: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PrivacyPolicy {
    pub ignore_private_context: bool,
    pub pause_on_drm: bool,
    pub blocked_application_ids: BTreeSet<String>,
    pub blocked_window_title_fragments: Vec<String>,
}

impl Default for PrivacyPolicy {
    fn default() -> Self {
        Self {
            ignore_private_context: true,
            pause_on_drm: true,
            blocked_application_ids: BTreeSet::new(),
            blocked_window_title_fragments: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureDecision {
    Capture,
    Skip(SkipReason),
}

impl CaptureDecision {
    pub fn reason(self) -> &'static str {
        match self {
            Self::Capture => "capture",
            Self::Skip(SkipReason::PermissionMissing) => "permission_missing",
            Self::Skip(SkipReason::UserPaused) => "user_paused",
            Self::Skip(SkipReason::DeviceLocked) => "device_locked",
            Self::Skip(SkipReason::Sleep) => "sleep",
            Self::Skip(SkipReason::PrivateContext) => "private_context",
            Self::Skip(SkipReason::DrmContent) => "drm_content",
            Self::Skip(SkipReason::BlockedApplication) => "blocked_application",
            Self::Skip(SkipReason::BlockedWindowTitle) => "blocked_window_title",
        }
    }
}

impl PrivacyPolicy {
    pub fn decide(&self, context: &CaptureContext) -> CaptureDecision {
        if !context.permission_granted {
            return CaptureDecision::Skip(SkipReason::PermissionMissing);
        }
        if context.user_paused {
            return CaptureDecision::Skip(SkipReason::UserPaused);
        }
        if context.device_locked {
            return CaptureDecision::Skip(SkipReason::DeviceLocked);
        }
        if context.sleeping {
            return CaptureDecision::Skip(SkipReason::Sleep);
        }
        if self.ignore_private_context && context.private_context {
            return CaptureDecision::Skip(SkipReason::PrivateContext);
        }
        if self.pause_on_drm && context.drm_content {
            return CaptureDecision::Skip(SkipReason::DrmContent);
        }
        if context
            .application_id
            .as_ref()
            .is_some_and(|application| self.blocked_application_ids.contains(application))
        {
            return CaptureDecision::Skip(SkipReason::BlockedApplication);
        }
        if context.window_title.as_ref().is_some_and(|title| {
            let normalized = title.to_lowercase();
            self.blocked_window_title_fragments
                .iter()
                .any(|fragment| normalized.contains(&fragment.to_lowercase()))
        }) {
            return CaptureDecision::Skip(SkipReason::BlockedWindowTitle);
        }
        CaptureDecision::Capture
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn privacy_gates_are_ordered_before_capture() {
        let policy = PrivacyPolicy {
            blocked_application_ids: ["com.example.bank".to_owned()].into_iter().collect(),
            blocked_window_title_fragments: vec!["password".to_owned()],
            ..Default::default()
        };
        let context = CaptureContext {
            permission_granted: true,
            application_id: Some("com.example.bank".to_owned()),
            window_title: Some("Password reset".to_owned()),
            ..Default::default()
        };

        assert_eq!(
            policy.decide(&context),
            CaptureDecision::Skip(SkipReason::BlockedApplication)
        );
    }

    #[test]
    fn missing_permission_never_falls_through_to_capture() {
        assert_eq!(
            PrivacyPolicy::default().decide(&CaptureContext::default()),
            CaptureDecision::Skip(SkipReason::PermissionMissing)
        );
    }

    #[test]
    fn every_platform_pause_gate_returns_an_explicit_skip_reason() {
        let cases = [
            (
                CaptureContext {
                    permission_granted: false,
                    ..Default::default()
                },
                SkipReason::PermissionMissing,
            ),
            (
                CaptureContext {
                    permission_granted: true,
                    user_paused: true,
                    ..Default::default()
                },
                SkipReason::UserPaused,
            ),
            (
                CaptureContext {
                    permission_granted: true,
                    device_locked: true,
                    ..Default::default()
                },
                SkipReason::DeviceLocked,
            ),
            (
                CaptureContext {
                    permission_granted: true,
                    sleeping: true,
                    ..Default::default()
                },
                SkipReason::Sleep,
            ),
            (
                CaptureContext {
                    permission_granted: true,
                    private_context: true,
                    ..Default::default()
                },
                SkipReason::PrivateContext,
            ),
            (
                CaptureContext {
                    permission_granted: true,
                    drm_content: true,
                    ..Default::default()
                },
                SkipReason::DrmContent,
            ),
        ];

        for (context, reason) in cases {
            assert_eq!(
                PrivacyPolicy::default().decide(&context),
                CaptureDecision::Skip(reason)
            );
        }
    }
}
