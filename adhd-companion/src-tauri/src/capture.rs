//! Capture worker — Candidate C event-driven stills + privacy + hash dedupe.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::db::Database;
use crate::privacy::{evaluate_privacy, PrivacyDecision, PrivacyRules};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaptureEvent {
    pub trigger: String,
    pub bundle_id: Option<String>,
    pub window_title: Option<String>,
    pub browser_url: Option<String>,
    pub idle_seconds: Option<f64>,
    pub jpeg_base64: Option<String>,
    pub accessibility_text: Option<String>,
    pub frame_hash: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaptureResult {
    pub screenshot_id: Option<i64>,
    pub decision: PrivacyDecision,
    pub skipped: bool,
    pub deduped: bool,
}

pub struct CaptureService {
    pub running: Arc<AtomicBool>,
    pub pause_capture: Arc<AtomicBool>,
    pub pause_nudges_only: Arc<AtomicBool>,
    pub rules: parking_lot::RwLock<PrivacyRules>,
    last_hash: Mutex<Option<String>>,
    last_drm_bundle: Mutex<Option<String>>,
    last_capture_at: Mutex<Option<Instant>>,
    min_interval: Duration,
}

impl CaptureService {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            pause_capture: Arc::new(AtomicBool::new(false)),
            pause_nudges_only: Arc::new(AtomicBool::new(true)),
            rules: parking_lot::RwLock::new(PrivacyRules::default()),
            last_hash: Mutex::new(None),
            last_drm_bundle: Mutex::new(None),
            last_capture_at: Mutex::new(None),
            min_interval: Duration::from_millis(200),
        }
    }

    pub fn start(&self) {
        self.running.store(true, Ordering::SeqCst);
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
    }

    pub fn set_rules(&self, rules: PrivacyRules) {
        *self.rules.write() = rules;
    }

    pub fn on_focus_changed(&self, bundle_id: Option<&str>) {
        let rules = self.rules.read().clone();
        let is_drm = crate::privacy::is_drm_focus(bundle_id, &rules);
        if is_drm {
            *self.last_drm_bundle.lock() = bundle_id.map(|s| s.to_string());
            self.pause_capture.store(true, Ordering::SeqCst);
            return;
        }
        let left_drm = self.last_drm_bundle.lock().take().is_some();
        if left_drm && self.pause_nudges_only.load(Ordering::SeqCst) {
            self.pause_capture.store(false, Ordering::SeqCst);
        }
    }

    pub fn handle_event(
        &self,
        db: &Database,
        mut event: CaptureEvent,
        pause_capture_until: Option<i64>,
        now_unix: i64,
    ) -> Result<CaptureResult, String> {
        if !self.running.load(Ordering::SeqCst) {
            return Ok(CaptureResult {
                screenshot_id: None,
                decision: PrivacyDecision::Skip {
                    reason: "capture_stopped".into(),
                },
                skipped: true,
                deduped: false,
            });
        }
        let settings_pause = pause_capture_until
            .map(|t| now_unix < t)
            .unwrap_or(false);
        if settings_pause || self.pause_capture.load(Ordering::SeqCst) {
            return Ok(CaptureResult {
                screenshot_id: None,
                decision: PrivacyDecision::Skip {
                    reason: "pause_watching_or_drm".into(),
                },
                skipped: true,
                deduped: false,
            });
        }

        // Rate limit
        {
            let mut last = self.last_capture_at.lock();
            if let Some(t) = *last {
                if t.elapsed() < self.min_interval {
                    return Ok(CaptureResult {
                        screenshot_id: None,
                        decision: PrivacyDecision::Skip {
                            reason: "debounce".into(),
                        },
                        skipped: true,
                        deduped: false,
                    });
                }
            }
            *last = Some(Instant::now());
        }

        let rules = self.rules.read().clone();
        let decision = evaluate_privacy(
            event.bundle_id.as_deref(),
            event.window_title.as_deref(),
            &rules,
        );

        match &decision {
            PrivacyDecision::Skip { .. } => {
                return Ok(CaptureResult {
                    screenshot_id: None,
                    decision,
                    skipped: true,
                    deduped: false,
                });
            }
            PrivacyDecision::PauseCapture { .. } => {
                self.pause_capture.store(true, Ordering::SeqCst);
                *self.last_drm_bundle.lock() = event.bundle_id.clone();
                return Ok(CaptureResult {
                    screenshot_id: None,
                    decision,
                    skipped: true,
                    deduped: false,
                });
            }
            PrivacyDecision::Allow | PrivacyDecision::Redact { .. } => {}
        }

        // Compute / accept frame hash for idle_fallback / visual_change dedupe.
        // When there is no real JPEG, do not hash the shared placeholder bytes —
        // that would make every subsequent idle tick permanently hash_dedupe.
        // Fingerprint by focus so same-focus idles still dedupe, but focus
        // changes still capture.
        let has_jpeg = event
            .jpeg_base64
            .as_ref()
            .map(|s| !s.is_empty())
            .unwrap_or(false);
        let bytes = decode_jpeg(event.jpeg_base64.as_deref());
        let hash = event.frame_hash.clone().unwrap_or_else(|| {
            if has_jpeg {
                hash_bytes(&bytes)
            } else {
                let fingerprint = format!(
                    "noface|{}|{}|{}|{}",
                    event.trigger,
                    event.bundle_id.as_deref().unwrap_or(""),
                    event.window_title.as_deref().unwrap_or(""),
                    event.browser_url.as_deref().unwrap_or("")
                );
                hash_bytes(fingerprint.as_bytes())
            }
        });
        event.frame_hash = Some(hash.clone());

        if event.trigger == "idle_fallback" || event.trigger == "visual_change" {
            let mut last = self.last_hash.lock();
            if last.as_ref() == Some(&hash) {
                return Ok(CaptureResult {
                    screenshot_id: None,
                    decision: PrivacyDecision::Skip {
                        reason: "hash_dedupe".into(),
                    },
                    skipped: true,
                    deduped: true,
                });
            }
            *last = Some(hash.clone());
        } else {
            *self.last_hash.lock() = Some(hash);
        }

        let redacted = matches!(decision, PrivacyDecision::Redact { .. });
        let reason = match &decision {
            PrivacyDecision::Redact { reason } => Some(reason.as_str()),
            _ => None,
        };

        let file_path = if redacted {
            None
        } else {
            Some(self.write_frame(db, &event, &bytes, now_unix)?)
        };

        let id = db
            .insert_screenshot(
                now_unix,
                &event.trigger,
                event.bundle_id.as_deref(),
                event.window_title.as_deref(),
                file_path.as_deref(),
                redacted,
                reason,
                event.accessibility_text.as_deref(),
                event.frame_hash.as_deref(),
                event.idle_seconds,
                event.browser_url.as_deref(),
            )
            .map_err(|e| e.to_string())?;

        Ok(CaptureResult {
            screenshot_id: Some(id),
            decision,
            skipped: false,
            deduped: false,
        })
    }

    fn write_frame(
        &self,
        db: &Database,
        event: &CaptureEvent,
        bytes: &[u8],
        captured_at: i64,
    ) -> Result<String, String> {
        let day = crate::day_boundary::logical_day_key(captured_at);
        let dir = db.root.join("screenshots").join(&day);
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let name = format!(
            "{}_{}.jpg",
            captured_at,
            &uuid::Uuid::new_v4().to_string()[..8]
        );
        let path = dir.join(&name);
        fs::write(&path, bytes).map_err(|e| e.to_string())?;
        let _ = event;
        Ok(PathBuf::from("screenshots")
            .join(day)
            .join(name)
            .to_string_lossy()
            .into_owned())
    }
}

fn decode_jpeg(b64: Option<&str>) -> Vec<u8> {
    if let Some(b64) = b64 {
        use base64::Engine;
        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(b64) {
            return bytes;
        }
    }
    placeholder_jpeg()
}

fn hash_bytes(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex::encode(h.finalize())
}

fn placeholder_jpeg() -> Vec<u8> {
    vec![
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06,
        0x05, 0x08, 0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B,
        0x0C, 0x19, 0x12, 0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
        0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31,
        0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF,
        0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00,
        0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x08, 0xFF, 0xC4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xDA, 0x00, 0x08,
        0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x7F, 0xFF, 0xD9,
    ]
}

#[cfg(target_os = "macos")]
pub mod native {
    //! ScreenCaptureKit + NSWorkspace observers — wired on Mac builds.
    //! Linux/CI uses EventBus injectors + idle simulator.
    pub fn platform_name() -> &'static str {
        "macos"
    }

    pub fn screen_recording_preflight() -> bool {
        // CGPreflightScreenCaptureAccess via objc2 in a follow-up; default true for compile.
        true
    }
}

#[cfg(not(target_os = "macos"))]
pub mod native {
    pub fn platform_name() -> &'static str {
        "stub"
    }

    pub fn screen_recording_preflight() -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn hash_dedupe_idle_fallback() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let cap = CaptureService::new();
        cap.start();
        let ev = CaptureEvent {
            trigger: "idle_fallback".into(),
            bundle_id: Some("com.apple.Safari".into()),
            window_title: Some("Docs".into()),
            browser_url: None,
            idle_seconds: Some(8.0),
            jpeg_base64: None,
            accessibility_text: None,
            frame_hash: Some("abc".into()),
        };
        let r1 = cap.handle_event(&db, ev.clone(), None, 0).unwrap();
        assert!(!r1.skipped);
        std::thread::sleep(Duration::from_millis(220));
        let r2 = cap.handle_event(&db, ev, None, 0).unwrap();
        assert!(r2.deduped);
    }

    #[test]
    fn idle_without_jpeg_dedupes_same_focus_not_across_focus() {
        let dir = tempdir().unwrap();
        let db = Database::open(dir.path()).unwrap();
        let cap = CaptureService::new();
        cap.start();
        let mut a = CaptureEvent {
            trigger: "idle_fallback".into(),
            bundle_id: Some("com.apple.Safari".into()),
            window_title: Some("Docs".into()),
            browser_url: None,
            idle_seconds: Some(8.0),
            jpeg_base64: None,
            accessibility_text: None,
            frame_hash: None,
        };
        let r1 = cap.handle_event(&db, a.clone(), None, 0).unwrap();
        assert!(!r1.skipped && !r1.deduped);
        std::thread::sleep(Duration::from_millis(220));
        let r2 = cap.handle_event(&db, a.clone(), None, 1).unwrap();
        assert!(r2.deduped, "same focus without JPEG must still hash_dedupe");
        std::thread::sleep(Duration::from_millis(220));
        a.window_title = Some("Mail".into());
        let r3 = cap.handle_event(&db, a, None, 2).unwrap();
        assert!(!r3.deduped && !r3.skipped, "focus change must escape placeholder dedupe");
    }
}
