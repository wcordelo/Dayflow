//! Shared OS / capture / orchestrator event bus (Screenpipe-inspired).

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

use crate::capture::CaptureEvent;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum BusEvent {
    Capture(CaptureEvent),
    AppSwitch {
        bundle_id: String,
        title: Option<String>,
    },
    WindowFocus {
        bundle_id: String,
        title: Option<String>,
    },
    IdleReturn {
        idle_seconds: f64,
    },
    IdleFallback,
    Sleep,
    Wake,
    Lock,
    Unlock,
    FocusChanged {
        bundle_id: Option<String>,
        title: Option<String>,
    },
}

pub struct EventBus {
    inner: Mutex<VecDeque<BusEvent>>,
    last_emit: Mutex<Option<(String, Instant)>>,
    debounce: Duration,
}

impl EventBus {
    pub fn new(debounce_ms: u64) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(VecDeque::new()),
            last_emit: Mutex::new(None),
            debounce: Duration::from_millis(debounce_ms),
        })
    }

    /// Debounce identical trigger+bundle storms (≥200ms contract).
    pub fn emit(&self, event: BusEvent) -> bool {
        let key = match &event {
            BusEvent::Capture(c) => format!(
                "cap:{}:{}",
                c.trigger,
                c.bundle_id.clone().unwrap_or_default()
            ),
            BusEvent::AppSwitch { bundle_id, .. } => format!("app:{bundle_id}"),
            BusEvent::WindowFocus { bundle_id, title } => {
                format!("focus:{bundle_id}:{}", title.clone().unwrap_or_default())
            }
            BusEvent::IdleReturn { .. } => "idle_return".into(),
            BusEvent::IdleFallback => "idle_fallback".into(),
            BusEvent::Sleep => "sleep".into(),
            BusEvent::Wake => "wake".into(),
            BusEvent::Lock => "lock".into(),
            BusEvent::Unlock => "unlock".into(),
            BusEvent::FocusChanged { bundle_id, .. } => {
                format!("fc:{}", bundle_id.clone().unwrap_or_default())
            }
        };
        {
            let mut last = self.last_emit.lock();
            if let Some((prev, at)) = last.as_ref() {
                if *prev == key && at.elapsed() < self.debounce {
                    return false;
                }
            }
            *last = Some((key, Instant::now()));
        }
        self.inner.lock().push_back(event);
        true
    }

    pub fn drain(&self) -> Vec<BusEvent> {
        let mut q = self.inner.lock();
        q.drain(..).collect()
    }

    pub fn len(&self) -> usize {
        self.inner.lock().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debounce_drops_storm() {
        let bus = EventBus::new(200);
        let e = BusEvent::AppSwitch {
            bundle_id: "com.a".into(),
            title: None,
        };
        assert!(bus.emit(e.clone()));
        assert!(!bus.emit(e));
        assert_eq!(bus.len(), 1);
    }
}
