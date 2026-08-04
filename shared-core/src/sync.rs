use std::collections::BTreeMap;

use crate::{CoreError, EventEnvelope};

/// Idempotent local outbox. A native transport can persist the same shape in
/// SQLite; keeping the behavior here makes retry and duplicate-delivery tests
/// portable across all clients.
#[derive(Debug, Clone, Default)]
pub struct SyncQueue {
    pending: BTreeMap<String, EventEnvelope>,
}

impl SyncQueue {
    /// Add an envelope to the local retry queue.
    ///
    /// Re-delivering the exact immutable envelope is idempotent. Reusing an
    /// event ID for different envelope bytes is a protocol conflict and must
    /// not be silently treated as a duplicate.
    pub fn enqueue(&mut self, envelope: EventEnvelope) -> Result<bool, CoreError> {
        envelope.validate()?;
        let event_id = envelope.event_id.clone();
        if let Some(existing) = self.pending.get(&event_id) {
            if existing == &envelope {
                return Ok(false);
            }
            return Err(CoreError::ConflictingEvent);
        }
        self.pending.insert(event_id, envelope);
        Ok(true)
    }

    /// Merge a batch atomically. If any envelope conflicts, no envelope from
    /// the batch is added to the queue.
    pub fn merge_remote<I>(&mut self, envelopes: I) -> Result<usize, CoreError>
    where
        I: IntoIterator<Item = EventEnvelope>,
    {
        let mut candidate = self.clone();
        let mut inserted = 0;
        for envelope in envelopes {
            inserted += usize::from(candidate.enqueue(envelope)?);
        }
        *self = candidate;
        Ok(inserted)
    }

    pub fn pending(&self) -> Vec<EventEnvelope> {
        self.pending.values().cloned().collect()
    }

    pub fn acknowledge<I, S>(&mut self, event_ids: I) -> usize
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        event_ids
            .into_iter()
            .map(|event_id| usize::from(self.pending.remove(event_id.as_ref()).is_some()))
            .sum()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AccountRootKey, EventLog, EventPayload, TimelineCard};

    #[test]
    fn acknowledgement_only_removes_known_events() {
        let mut log = EventLog::new("mac", AccountRootKey::generate());
        let envelope = log
            .append(EventPayload::TimelineCardUpsert(TimelineCard {
                id: "card".into(),
                day: "2026-08-01".into(),
                start_timestamp: 1,
                end_timestamp: 2,
                title: "title".into(),
                summary: "summary".into(),
                category: "work".into(),
                subcategory: String::new(),
                detailed_summary: String::new(),
                source: String::new(),
                derivation_mode: String::new(),
            }))
            .unwrap();
        let mut queue = SyncQueue::default();
        assert!(queue.enqueue(envelope.clone()).unwrap());
        assert_eq!(
            queue.acknowledge(["missing", envelope.event_id.as_str()]),
            1
        );
        assert!(queue.is_empty());
    }

    #[test]
    fn retry_and_duplicate_delivery_keep_one_pending_envelope() {
        let mut log = EventLog::new("mac", AccountRootKey::generate());
        let envelope = log
            .append(EventPayload::TimelineCardUpsert(TimelineCard {
                id: "card".into(),
                day: "2026-08-01".into(),
                start_timestamp: 1,
                end_timestamp: 2,
                title: "title".into(),
                summary: "summary".into(),
                category: "work".into(),
                subcategory: String::new(),
                detailed_summary: String::new(),
                source: String::new(),
                derivation_mode: String::new(),
            }))
            .unwrap();
        let mut queue = SyncQueue::default();
        assert_eq!(
            queue
                .merge_remote([envelope.clone(), envelope.clone()])
                .unwrap(),
            1
        );
        assert_eq!(queue.pending(), vec![envelope.clone()]);
        assert_eq!(
            queue.acknowledge([envelope.event_id.as_str(), envelope.event_id.as_str()]),
            1
        );
        assert!(queue.is_empty());
    }

    #[test]
    fn conflicting_event_id_is_rejected_without_mutation() {
        let mut log = EventLog::new("mac", AccountRootKey::generate());
        let first = log
            .append(EventPayload::TimelineCardUpsert(TimelineCard {
                id: "first".into(),
                day: "2026-08-01".into(),
                start_timestamp: 1,
                end_timestamp: 2,
                title: "first".into(),
                summary: "first".into(),
                category: "work".into(),
                subcategory: String::new(),
                detailed_summary: String::new(),
                source: String::new(),
                derivation_mode: String::new(),
            }))
            .unwrap();
        let mut conflicting = first.clone();
        conflicting.ciphertext = "ZGlmZmVyZW50LWNpcGhlcnRleHQ=".into();

        let mut queue = SyncQueue::default();
        assert!(queue.enqueue(first.clone()).unwrap());
        assert!(matches!(
            queue.enqueue(conflicting),
            Err(CoreError::ConflictingEvent)
        ));
        assert_eq!(queue.pending(), vec![first]);
    }

    #[test]
    fn conflicting_batch_is_rejected_atomically() {
        let mut log = EventLog::new("mac", AccountRootKey::generate());
        let first = log
            .append(EventPayload::TimelineCardUpsert(TimelineCard {
                id: "first".into(),
                day: "2026-08-01".into(),
                start_timestamp: 1,
                end_timestamp: 2,
                title: "first".into(),
                summary: "first".into(),
                category: "work".into(),
                subcategory: String::new(),
                detailed_summary: String::new(),
                source: String::new(),
                derivation_mode: String::new(),
            }))
            .unwrap();
        let second = log
            .append(EventPayload::TimelineCardUpsert(TimelineCard {
                id: "second".into(),
                day: "2026-08-01".into(),
                start_timestamp: 3,
                end_timestamp: 4,
                title: "second".into(),
                summary: "second".into(),
                category: "work".into(),
                subcategory: String::new(),
                detailed_summary: String::new(),
                source: String::new(),
                derivation_mode: String::new(),
            }))
            .unwrap();
        let mut conflicting = first.clone();
        conflicting.ciphertext = "ZGlmZmVyZW50LWNpcGhlcnRleHQ=".into();

        let mut queue = SyncQueue::default();
        assert!(queue.enqueue(first.clone()).unwrap());
        assert!(matches!(
            queue.merge_remote([second, conflicting]),
            Err(CoreError::ConflictingEvent)
        ));
        assert_eq!(queue.pending(), vec![first]);
    }
}
