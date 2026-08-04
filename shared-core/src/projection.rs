use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::events::{EventPayload, EventRecord, JournalEntry, Priority, Reflection, TimelineCard};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatContextItem {
    pub id: String,
    pub kind: String,
    pub day: String,
    pub content: String,
}

/// Deterministic, materialized state derived exclusively from the append-only
/// event log. Every client rebuilds this shape locally; the relay never owns it.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectionState {
    pub timeline_cards: BTreeMap<String, TimelineCard>,
    pub journal_entries: BTreeMap<String, JournalEntry>,
    pub priorities: BTreeMap<String, Priority>,
    pub reflections: BTreeMap<String, Reflection>,
    pub settings: BTreeMap<String, String>,
    pub tombstones: BTreeSet<String>,
    /// Content-addressed, deterministic context for on-device chat. It is
    /// derived from the same local projection and never sent to the relay.
    pub chat_context: Vec<ChatContextItem>,
}

impl ProjectionState {
    pub fn from_records(records: &[EventRecord]) -> Self {
        let mut ordered = records.to_vec();
        ordered.sort_by(|a, b| {
            a.logical_clock
                .cmp(&b.logical_clock)
                .then_with(|| a.device_id.cmp(&b.device_id))
                .then_with(|| a.event_id.cmp(&b.event_id))
        });

        let mut projection = Self::default();
        for record in ordered {
            projection.apply(&record.payload);
        }
        projection.rebuild_chat_context();
        projection
    }

    pub fn rebuild_chat_context(&mut self) {
        let mut items = Vec::new();
        items.extend(self.timeline_cards.values().map(|card| ChatContextItem {
            id: card.id.clone(),
            kind: "timeline_card".to_owned(),
            day: card.day.clone(),
            content: if card.source.is_empty() && card.derivation_mode.is_empty() {
                format!("{}: {}", card.title, card.summary)
            } else {
                format!(
                    "{}: {} [source={}, derivation={}]",
                    card.title, card.summary, card.source, card.derivation_mode
                )
            },
        }));
        items.extend(self.journal_entries.values().map(|entry| ChatContextItem {
            id: entry.id.clone(),
            kind: "journal".to_owned(),
            day: entry.day.clone(),
            content: entry.body.clone(),
        }));
        items.extend(self.priorities.values().map(|priority| ChatContextItem {
            id: priority.id.clone(),
            kind: "priority".to_owned(),
            day: priority.day.clone(),
            content: format!("{} ({})", priority.text, priority.status),
        }));
        items.extend(self.reflections.values().map(|reflection| ChatContextItem {
            id: reflection.id.clone(),
            kind: "reflection".to_owned(),
            day: reflection.day.clone(),
            content: reflection.body.clone(),
        }));
        items.sort_by(|left, right| {
            right
                .day
                .cmp(&left.day)
                .then_with(|| left.kind.cmp(&right.kind))
                .then_with(|| left.id.cmp(&right.id))
        });
        self.chat_context = items;
    }

    pub fn apply(&mut self, payload: &EventPayload) {
        match payload {
            EventPayload::CaptureDerived(capture) => {
                let card = TimelineCard {
                    id: capture.id.clone(),
                    day: capture.day.clone(),
                    start_timestamp: capture.start_timestamp,
                    end_timestamp: capture.end_timestamp,
                    title: capture.title.clone(),
                    summary: capture.summary.clone(),
                    category: capture.category.clone(),
                    subcategory: String::new(),
                    detailed_summary: String::new(),
                    source: capture.source.clone(),
                    derivation_mode: capture.derivation_mode.clone(),
                };
                self.upsert_card(card);
            }
            EventPayload::TimelineCardUpsert(card) => self.upsert_card(card.clone()),
            EventPayload::JournalUpsert(entry) => {
                self.tombstones.remove(&entry.id);
                self.journal_entries.insert(entry.id.clone(), entry.clone());
            }
            EventPayload::PriorityUpsert(priority) => {
                self.tombstones.remove(&priority.id);
                self.priorities
                    .insert(priority.id.clone(), priority.clone());
            }
            EventPayload::ReflectionUpsert(reflection) => {
                self.tombstones.remove(&reflection.id);
                self.reflections
                    .insert(reflection.id.clone(), reflection.clone());
            }
            EventPayload::SettingUpsert { key, value } => {
                self.tombstones.remove(key);
                self.settings.insert(key.clone(), value.clone());
            }
            EventPayload::Tombstone { target_id } => {
                self.tombstones.insert(target_id.clone());
                self.timeline_cards.remove(target_id);
                self.journal_entries.remove(target_id);
                self.priorities.remove(target_id);
                self.reflections.remove(target_id);
                self.settings.remove(target_id);
            }
        }
    }

    fn upsert_card(&mut self, card: TimelineCard) {
        self.tombstones.remove(&card.id);
        self.timeline_cards.insert(card.id.clone(), card);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AccountRootKey, EventLog};

    #[test]
    fn delete_is_an_operation_and_replay_is_deterministic() {
        let root = AccountRootKey::generate();
        let mut log = EventLog::new("mac", root);
        log.append(EventPayload::JournalUpsert(JournalEntry {
            id: "journal-1".to_owned(),
            day: "2026-08-01".to_owned(),
            body: "first".to_owned(),
        }))
        .unwrap();
        log.append(EventPayload::Tombstone {
            target_id: "journal-1".to_owned(),
        })
        .unwrap();

        let projection = log.project().unwrap();
        assert!(projection.journal_entries.is_empty());
        assert!(projection.tombstones.contains("journal-1"));
        assert_eq!(projection, log.project().unwrap());
    }

    #[test]
    fn later_edit_can_resurrect_an_explicitly_deleted_record() {
        let root = AccountRootKey::generate();
        let mut log = EventLog::new("mac", root);
        log.append(EventPayload::Tombstone {
            target_id: "priority-1".to_owned(),
        })
        .unwrap();
        log.append(EventPayload::PriorityUpsert(Priority {
            id: "priority-1".to_owned(),
            day: "2026-08-01".to_owned(),
            rank: 0,
            text: "Re-opened intentionally".to_owned(),
            status: "active".to_owned(),
        }))
        .unwrap();

        let projection = log.project().unwrap();
        assert!(projection.priorities.contains_key("priority-1"));
        assert!(!projection.tombstones.contains("priority-1"));
    }

    #[test]
    fn chat_context_is_deterministic_and_contains_local_projection_content() {
        let root = AccountRootKey::generate();
        let mut log = EventLog::new("mac", root);
        log.append(EventPayload::JournalUpsert(JournalEntry {
            id: "journal-1".to_owned(),
            day: "2026-08-01".to_owned(),
            body: "Ship the native sync path".to_owned(),
        }))
        .unwrap();
        let projection = log.project().unwrap();
        assert_eq!(projection.chat_context.len(), 1);
        assert_eq!(projection.chat_context[0].kind, "journal");
        assert!(projection.chat_context[0].content.contains("native sync"));
        assert_eq!(projection, log.project().unwrap());
    }

    #[test]
    fn capture_provenance_survives_projection_and_replay() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("android", root.clone());
        source
            .append(EventPayload::CaptureDerived(crate::CaptureDerived {
                id: "capture-1".to_owned(),
                day: "2026-08-01".to_owned(),
                start_timestamp: 1,
                end_timestamp: 2,
                title: "Android activity".to_owned(),
                summary: "Derived locally after a privacy decision.".to_owned(),
                category: "activity_capture".to_owned(),
                source: "android_media_projection".to_owned(),
                derivation_mode: "privacy_gated_local_metadata".to_owned(),
            }))
            .unwrap();

        let envelopes = source.envelopes().cloned().collect::<Vec<_>>();
        let mut replay = EventLog::new("mac", root);
        for envelope in envelopes.into_iter().rev() {
            replay.ingest(envelope).unwrap();
        }

        let projection = replay.project().unwrap();
        let card = &projection.timeline_cards["capture-1"];
        assert_eq!(card.source, "android_media_projection");
        assert_eq!(card.derivation_mode, "privacy_gated_local_metadata");
        let chat_item = projection
            .chat_context
            .iter()
            .find(|item| item.id == "capture-1")
            .expect("replayed capture should be available to local chat");
        assert_eq!(chat_item.kind, "timeline_card");
        assert!(chat_item.content.contains("Android activity"));
        assert!(chat_item.content.contains("privacy_gated_local_metadata"));
    }

    #[test]
    fn priorities_reflections_and_settings_replay_in_any_arrival_order() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("mac", root.clone());
        source
            .append(EventPayload::PriorityUpsert(Priority {
                id: "priority-1".to_owned(),
                day: "2026-08-01".to_owned(),
                rank: 1,
                text: "Finish the native sync slice".to_owned(),
                status: "active".to_owned(),
            }))
            .unwrap();
        source
            .append(EventPayload::ReflectionUpsert(Reflection {
                id: "reflection-1".to_owned(),
                day: "2026-08-01".to_owned(),
                body: "The local projection is understandable.".to_owned(),
            }))
            .unwrap();
        source
            .append(EventPayload::SettingUpsert {
                key: "day_goal:2026-08-01".to_owned(),
                value: "{\"focus_target_minutes\":120}".to_owned(),
            })
            .unwrap();

        let envelopes = source.envelopes().cloned().collect::<Vec<_>>();
        let mut forward = EventLog::new("phone", root.clone());
        for envelope in envelopes.iter().cloned() {
            forward.ingest(envelope).unwrap();
        }

        let mut reverse = EventLog::new("phone", root);
        for envelope in envelopes.into_iter().rev() {
            reverse.ingest(envelope).unwrap();
        }

        assert_eq!(forward.project().unwrap(), reverse.project().unwrap());
        let projection = forward.project().unwrap();
        assert_eq!(
            projection.priorities["priority-1"].text,
            "Finish the native sync slice"
        );
        assert_eq!(
            projection.reflections["reflection-1"].body,
            "The local projection is understandable."
        );
        assert_eq!(
            projection.settings["day_goal:2026-08-01"],
            "{\"focus_target_minutes\":120}"
        );
        assert!(projection
            .chat_context
            .iter()
            .any(|item| { item.kind == "priority" && item.content.contains("native sync") }));
        assert!(projection
            .chat_context
            .iter()
            .any(|item| { item.kind == "reflection" && item.content.contains("understandable") }));
    }
}
