use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::crypto::{
    decode_base64, open_event_with_keyring, seal_event_with_keyring, seal_event_with_nonce,
    AccountKeyRing, AccountRootKey, EVENT_AUTH_TAG_BYTES, EVENT_NONCE_BYTES,
};
use crate::{CoreError, EVENT_SCHEMA_VERSION, MAX_LOGICAL_CLOCK};

/// The only record sent to the sync relay. `ciphertext` contains a serialized
/// `EventPayload`; the relay must treat every field after the routing metadata as
/// opaque.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EventEnvelope {
    pub event_id: String,
    pub device_id: String,
    pub logical_clock: u64,
    pub schema_version: u16,
    pub key_version: u32,
    pub nonce: String,
    pub ciphertext: String,
}

impl EventEnvelope {
    pub fn validate(&self) -> Result<(), CoreError> {
        if self.event_id.trim().is_empty()
            || self.device_id.trim().is_empty()
            || self.logical_clock == 0
            || self.logical_clock > MAX_LOGICAL_CLOCK
            || self.schema_version != EVENT_SCHEMA_VERSION
            || self.key_version == 0
            || self.nonce.is_empty()
            || self.ciphertext.is_empty()
        {
            return Err(CoreError::InvalidEnvelope);
        }

        let nonce = decode_base64(&self.nonce).ok_or(CoreError::InvalidEnvelope)?;
        let ciphertext = decode_base64(&self.ciphertext).ok_or(CoreError::InvalidEnvelope)?;
        if nonce.len() != EVENT_NONCE_BYTES || ciphertext.len() < EVENT_AUTH_TAG_BYTES {
            return Err(CoreError::InvalidEnvelope);
        }
        Ok(())
    }
}

/// Re-encrypt an envelope for a new local/account key-ring while preserving
/// its immutable event identity and logical clock. The migration nonce is
/// deterministic for the destination key and source envelope, so a retry
/// after an interrupted local-workspace link produces the same envelope and
/// remains idempotent in every native SQLite outbox.
pub fn rekey_envelope(
    envelope: &EventEnvelope,
    source_key_ring: &AccountKeyRing,
    destination_key_ring: &AccountKeyRing,
) -> Result<EventEnvelope, CoreError> {
    envelope.validate()?;
    let plaintext = open_event_with_keyring(
        source_key_ring,
        &envelope.event_id,
        &envelope.device_id,
        envelope.logical_clock,
        envelope.schema_version,
        envelope.key_version,
        &envelope.nonce,
        &envelope.ciphertext,
    )?;
    let payload: EventPayload =
        serde_json::from_slice(&plaintext).map_err(|e| CoreError::Serialization(e.to_string()))?;
    payload.validate()?;
    let key_version = destination_key_ring.active_version();
    let root_key = destination_key_ring.key(key_version)?;
    let mut hasher = Sha256::new();
    hasher.update(b"dayflow:local-workspace-rekey:v1");
    hasher.update(root_key.as_bytes());
    hasher.update(envelope.event_id.as_bytes());
    hasher.update([0]);
    hasher.update(envelope.device_id.as_bytes());
    hasher.update(envelope.logical_clock.to_be_bytes());
    hasher.update(envelope.schema_version.to_be_bytes());
    hasher.update(envelope.key_version.to_be_bytes());
    hasher.update(envelope.nonce.as_bytes());
    let digest = hasher.finalize();
    let mut nonce = [0u8; 24];
    nonce.copy_from_slice(&digest[..24]);
    let (nonce, ciphertext) = seal_event_with_nonce(
        root_key,
        &envelope.event_id,
        &envelope.device_id,
        envelope.logical_clock,
        envelope.schema_version,
        key_version,
        nonce,
        &plaintext,
    )?;
    Ok(EventEnvelope {
        event_id: envelope.event_id.clone(),
        device_id: envelope.device_id.clone(),
        logical_clock: envelope.logical_clock,
        schema_version: envelope.schema_version,
        key_version,
        nonce,
        ciphertext,
    })
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum EventKind {
    CaptureDerived,
    TimelineCardUpsert,
    JournalUpsert,
    PriorityUpsert,
    ReflectionUpsert,
    SettingUpsert,
    Tombstone,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CaptureDerived {
    pub id: String,
    pub day: String,
    pub start_timestamp: i64,
    pub end_timestamp: i64,
    pub title: String,
    pub summary: String,
    pub category: String,
    /// Platform adapter that produced this locally derived record. Optional
    /// so older encrypted events remain replayable after the contract grows.
    #[serde(default)]
    pub source: String,
    /// Honest description of the local derivation stage. This must not imply
    /// AI inference when a platform client only emitted privacy-gated metadata.
    #[serde(default)]
    pub derivation_mode: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TimelineCard {
    pub id: String,
    pub day: String,
    pub start_timestamp: i64,
    pub end_timestamp: i64,
    pub title: String,
    pub summary: String,
    pub category: String,
    #[serde(default)]
    pub subcategory: String,
    #[serde(default)]
    pub detailed_summary: String,
    /// Capture provenance carried into the deterministic cross-device
    /// projection. Empty means the event predates the provenance contract.
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub derivation_mode: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JournalEntry {
    pub id: String,
    pub day: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Priority {
    pub id: String,
    pub day: String,
    pub rank: i32,
    pub text: String,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Reflection {
    pub id: String,
    pub day: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", content = "value")]
pub enum EventPayload {
    CaptureDerived(CaptureDerived),
    TimelineCardUpsert(TimelineCard),
    JournalUpsert(JournalEntry),
    PriorityUpsert(Priority),
    ReflectionUpsert(Reflection),
    SettingUpsert { key: String, value: String },
    Tombstone { target_id: String },
}

impl EventPayload {
    pub fn kind(&self) -> EventKind {
        match self {
            Self::CaptureDerived(_) => EventKind::CaptureDerived,
            Self::TimelineCardUpsert(_) => EventKind::TimelineCardUpsert,
            Self::JournalUpsert(_) => EventKind::JournalUpsert,
            Self::PriorityUpsert(_) => EventKind::PriorityUpsert,
            Self::ReflectionUpsert(_) => EventKind::ReflectionUpsert,
            Self::SettingUpsert { .. } => EventKind::SettingUpsert,
            Self::Tombstone { .. } => EventKind::Tombstone,
        }
    }

    /// Validate payload invariants that must hold before an event crosses the
    /// encryption boundary. Native shells repeat the allowlist so malformed
    /// input is rejected close to the UI, while this shared check protects all
    /// FFI, replay, migration, and future-client paths consistently.
    pub fn validate(&self) -> Result<(), CoreError> {
        let Self::SettingUpsert { key, value } = self else {
            return Ok(());
        };

        let allowed = match key.as_str() {
            "dayflow.theme" | "dayflow.capture.paused" | "dayflow.logical_day_boundary_hour" => {
                true
            }
            _ => {
                valid_dated_setting_key(key, "day_goal:")
                    || valid_dated_setting_key(key, "daily_standup:")
            }
        };
        if !allowed {
            return Err(CoreError::InvalidSettingKey);
        }
        if key == "dayflow.capture.paused" && value != "true" && value != "false" {
            return Err(CoreError::InvalidSettingValue);
        }
        Ok(())
    }
}

fn valid_dated_setting_key(key: &str, prefix: &str) -> bool {
    let Some(day) = key.strip_prefix(prefix) else {
        return false;
    };
    day.len() == 10 && chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d").is_ok()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EventRecord {
    pub event_id: String,
    pub device_id: String,
    pub logical_clock: u64,
    pub schema_version: u16,
    pub key_version: u32,
    pub payload: EventPayload,
}

impl EventRecord {
    pub fn ordering_key(&self) -> (u64, &str, &str) {
        (self.logical_clock, &self.device_id, &self.event_id)
    }
}

/// Local event log plus an idempotent encrypted ingest path. A native client can
/// replace this in-memory container with its local SQLite implementation while
/// preserving the same envelope and projection behavior.
pub struct EventLog {
    device_id: String,
    next_clock: u64,
    key_ring: AccountKeyRing,
    events: BTreeMap<String, EventEnvelope>,
}

impl EventLog {
    pub fn new(device_id: impl Into<String>, root_key: AccountRootKey) -> Self {
        Self::with_key_ring(device_id, AccountKeyRing::new(root_key))
    }

    pub fn with_key_ring(device_id: impl Into<String>, key_ring: AccountKeyRing) -> Self {
        Self {
            device_id: device_id.into(),
            next_clock: 0,
            key_ring,
            events: BTreeMap::new(),
        }
    }

    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    pub fn key_ring(&self) -> &AccountKeyRing {
        &self.key_ring
    }

    pub fn add_key_version(
        &mut self,
        version: u32,
        root_key: AccountRootKey,
    ) -> Result<(), CoreError> {
        self.key_ring.insert(version, root_key)
    }

    pub fn set_active_key_version(&mut self, version: u32) -> Result<(), CoreError> {
        self.key_ring.set_active_version(version)
    }

    pub fn append(&mut self, payload: EventPayload) -> Result<EventEnvelope, CoreError> {
        payload.validate()?;
        self.next_clock = self
            .next_clock
            .checked_add(1)
            .ok_or(CoreError::LogicalClockExhausted)?;
        if self.next_clock > MAX_LOGICAL_CLOCK {
            return Err(CoreError::LogicalClockExhausted);
        }
        let event_id = Uuid::new_v4().to_string();
        let bytes =
            serde_json::to_vec(&payload).map_err(|e| CoreError::Serialization(e.to_string()))?;
        let key_version = self.key_ring.active_version();
        let (nonce, ciphertext) = seal_event_with_keyring(
            &self.key_ring,
            &event_id,
            &self.device_id,
            self.next_clock,
            EVENT_SCHEMA_VERSION,
            key_version,
            &bytes,
        )?;
        let envelope = EventEnvelope {
            event_id: event_id.clone(),
            device_id: self.device_id.clone(),
            logical_clock: self.next_clock,
            schema_version: EVENT_SCHEMA_VERSION,
            key_version,
            nonce,
            ciphertext,
        };
        self.events.insert(event_id, envelope.clone());
        Ok(envelope)
    }

    /// Insert a remote event exactly once. Replaying the same envelope is a
    /// successful no-op, which lets clients retry after uncertain acknowledgements.
    pub fn ingest(&mut self, envelope: EventEnvelope) -> Result<bool, CoreError> {
        envelope.validate()?;
        if let Some(existing) = self.events.get(&envelope.event_id) {
            if existing == &envelope {
                return Ok(false);
            }
            return Err(CoreError::ConflictingEvent);
        }
        // Authenticate before persisting a remote envelope. A relay cannot inject
        // arbitrary ciphertext into the local log even if it knows an event ID.
        let _ = self.decrypt_envelope(&envelope)?;
        self.next_clock = self.next_clock.max(envelope.logical_clock);
        self.events.insert(envelope.event_id.clone(), envelope);
        Ok(true)
    }

    pub fn envelopes(&self) -> impl Iterator<Item = &EventEnvelope> {
        self.events.values()
    }

    pub fn decrypt_envelope(&self, envelope: &EventEnvelope) -> Result<EventRecord, CoreError> {
        let bytes = open_event_with_keyring(
            &self.key_ring,
            &envelope.event_id,
            &envelope.device_id,
            envelope.logical_clock,
            envelope.schema_version,
            envelope.key_version,
            &envelope.nonce,
            &envelope.ciphertext,
        )?;
        let payload: EventPayload =
            serde_json::from_slice(&bytes).map_err(|e| CoreError::Serialization(e.to_string()))?;
        payload.validate()?;
        Ok(EventRecord {
            event_id: envelope.event_id.clone(),
            device_id: envelope.device_id.clone(),
            logical_clock: envelope.logical_clock,
            schema_version: envelope.schema_version,
            key_version: envelope.key_version,
            payload,
        })
    }

    pub fn records(&self) -> Result<Vec<EventRecord>, CoreError> {
        let mut records = self
            .events
            .values()
            .map(|envelope| self.decrypt_envelope(envelope))
            .collect::<Result<Vec<_>, _>>()?;
        records.sort_by(|a, b| {
            a.logical_clock
                .cmp(&b.logical_clock)
                .then_with(|| a.device_id.cmp(&b.device_id))
                .then_with(|| a.event_id.cmp(&b.event_id))
        });
        Ok(records)
    }

    pub fn project(&self) -> Result<crate::ProjectionState, CoreError> {
        Ok(crate::ProjectionState::from_records(&self.records()?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AccountRootKey, SyncQueue};
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

    fn card(id: &str) -> EventPayload {
        EventPayload::TimelineCardUpsert(TimelineCard {
            id: id.to_owned(),
            day: "2026-08-01".to_owned(),
            start_timestamp: 1,
            end_timestamp: 2,
            title: "Build".to_owned(),
            summary: "Shared core".to_owned(),
            category: "work".to_owned(),
            subcategory: String::new(),
            detailed_summary: String::new(),
            source: String::new(),
            derivation_mode: String::new(),
        })
    }

    #[test]
    fn checked_in_envelope_fixture_matches_the_portable_wire_contract() {
        let fixture: EventEnvelope = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../docs/multi-device/fixtures/event-envelope-v1.json"
        )))
        .unwrap();

        assert_eq!(fixture.event_id, "fixture-event-1");
        assert_eq!(fixture.device_id, "fixture-mac");
        assert_eq!(fixture.logical_clock, 42);
        assert_eq!(fixture.schema_version, EVENT_SCHEMA_VERSION);
        assert_eq!(fixture.key_version, 2);
        assert_eq!(fixture.nonce, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        assert_eq!(fixture.ciphertext, "Y2lwaGVydGV4dC1wYXlsb2Fk");
        fixture.validate().unwrap();

        let encoded = serde_json::to_string(&fixture).unwrap();
        let decoded: EventEnvelope = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded, fixture);
    }

    #[test]
    fn duplicate_remote_delivery_is_idempotent() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("mac", root.clone());
        let envelope = source.append(card("card-1")).unwrap();
        let mut target = EventLog::new("phone", root);

        assert!(target.ingest(envelope.clone()).unwrap());
        assert!(!target.ingest(envelope).unwrap());
        assert_eq!(target.records().unwrap().len(), 1);
    }

    #[test]
    fn local_workspace_rekey_preserves_identity_and_is_retryable() {
        let source_key = AccountRootKey::generate();
        let destination_key = AccountRootKey::generate();
        let mut source = EventLog::new("device", source_key.clone());
        let envelope = source.append(card("card-1")).unwrap();
        let source_ring = AccountKeyRing::new(source_key);
        let destination_ring = AccountKeyRing::new(destination_key);

        let first = rekey_envelope(&envelope, &source_ring, &destination_ring).unwrap();
        let retry = rekey_envelope(&envelope, &source_ring, &destination_ring).unwrap();
        assert_eq!(first, retry);
        assert_eq!(first.event_id, envelope.event_id);
        assert_eq!(first.device_id, envelope.device_id);
        assert_eq!(first.logical_clock, envelope.logical_clock);
        assert_ne!(first.ciphertext, envelope.ciphertext);

        let mut target = EventLog::with_key_ring("target", destination_ring);
        assert!(target.ingest(first).unwrap());
        assert_eq!(target.project().unwrap().timeline_cards.len(), 1);
    }

    #[test]
    fn conflicting_remote_event_id_is_rejected_before_mutation() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("mac", root.clone());
        let first = source.append(card("card-1")).unwrap();
        let mut conflicting = source.append(card("card-2")).unwrap();
        conflicting.event_id = first.event_id.clone();

        let mut target = EventLog::new("phone", root);
        assert!(target.ingest(first.clone()).unwrap());
        assert!(matches!(
            target.ingest(conflicting),
            Err(CoreError::ConflictingEvent)
        ));
        assert_eq!(
            target.records().unwrap(),
            vec![target.decrypt_envelope(&first).unwrap()]
        );
    }

    #[test]
    fn tampered_remote_envelope_is_rejected_before_ingest() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("mac", root.clone());
        let mut envelope = source.append(card("card-1")).unwrap();
        envelope.ciphertext.push('x');
        let mut target = EventLog::new("phone", root);

        assert!(target.ingest(envelope).is_err());
        assert_eq!(target.records().unwrap().len(), 0);
    }

    #[test]
    fn malformed_encrypted_fields_are_rejected_before_ingest() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("mac", root.clone());
        let valid = source.append(card("card-1")).unwrap();

        let mut short_nonce = valid.clone();
        short_nonce.nonce = "bm9uY2U".to_owned();
        let mut target = EventLog::new("phone", root.clone());
        assert!(matches!(
            target.ingest(short_nonce),
            Err(CoreError::InvalidEnvelope)
        ));

        let mut short_ciphertext = valid;
        short_ciphertext.ciphertext = "c2hvcnQ".to_owned();
        assert!(matches!(
            target.ingest(short_ciphertext),
            Err(CoreError::InvalidEnvelope)
        ));
        assert_eq!(target.records().unwrap().len(), 0);
    }

    #[test]
    fn base64url_envelope_replays_through_the_shared_core() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("mac", root.clone());
        let mut envelope = source.append(card("card-1")).unwrap();
        envelope.nonce = URL_SAFE_NO_PAD.encode(decode_base64(&envelope.nonce).unwrap());
        envelope.ciphertext = URL_SAFE_NO_PAD.encode(decode_base64(&envelope.ciphertext).unwrap());

        let mut target = EventLog::new("phone", root);
        assert!(target.ingest(envelope).unwrap());
        assert_eq!(target.records().unwrap().len(), 1);
    }

    #[test]
    fn zero_logical_clock_is_rejected_before_ingest() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("mac", root.clone());
        let mut envelope = source.append(card("card-1")).unwrap();
        envelope.logical_clock = 0;

        let mut target = EventLog::new("phone", root);
        assert!(matches!(
            target.ingest(envelope),
            Err(CoreError::InvalidEnvelope)
        ));
        assert_eq!(target.records().unwrap().len(), 0);
    }

    #[test]
    fn unsupported_schema_version_is_rejected_before_ingest() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("mac", root.clone());
        let mut envelope = source.append(card("card-1")).unwrap();
        envelope.schema_version = EVENT_SCHEMA_VERSION + 1;

        let mut target = EventLog::new("phone", root);
        assert!(matches!(
            target.ingest(envelope),
            Err(CoreError::InvalidEnvelope)
        ));
        assert_eq!(target.records().unwrap().len(), 0);
    }

    #[test]
    fn shared_setting_contract_rejects_unknown_and_malformed_values() {
        assert!(EventPayload::SettingUpsert {
            key: "dayflow.theme".to_owned(),
            value: "dark".to_owned(),
        }
        .validate()
        .is_ok());
        assert!(EventPayload::SettingUpsert {
            key: "day_goal:2026-08-01".to_owned(),
            value: "{}".to_owned(),
        }
        .validate()
        .is_ok());
        assert!(EventPayload::SettingUpsert {
            key: "daily_standup:2026-02-29".to_owned(),
            value: "{}".to_owned(),
        }
        .validate()
        .is_err());
        assert!(matches!(
            EventPayload::SettingUpsert {
                key: "dayflow.provider.api_key".to_owned(),
                value: "secret".to_owned(),
            }
            .validate(),
            Err(CoreError::InvalidSettingKey)
        ));
        assert!(matches!(
            EventPayload::SettingUpsert {
                key: "dayflow.capture.paused".to_owned(),
                value: "maybe".to_owned(),
            }
            .validate(),
            Err(CoreError::InvalidSettingValue)
        ));
    }

    #[test]
    fn invalid_shared_setting_does_not_advance_the_local_clock() {
        let root = AccountRootKey::generate();
        let mut log = EventLog::new("mac", root);
        assert!(log
            .append(EventPayload::SettingUpsert {
                key: "dayflow.provider.api_key".to_owned(),
                value: "secret".to_owned(),
            })
            .is_err());
        let envelope = log.append(card("card-1")).unwrap();
        assert_eq!(envelope.logical_clock, 1);
    }

    #[test]
    fn logical_clock_exhaustion_fails_before_sealing_an_event() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("mac", root);
        source.next_clock = MAX_LOGICAL_CLOCK;

        assert!(matches!(
            source.append(card("card-1")),
            Err(CoreError::LogicalClockExhausted)
        ));
        assert_eq!(source.envelopes().count(), 0);
    }

    #[test]
    fn logical_clock_above_json_safe_range_is_rejected_before_ingest() {
        let root = AccountRootKey::generate();
        let mut source = EventLog::new("mac", root.clone());
        let mut envelope = source.append(card("card-1")).unwrap();
        envelope.logical_clock = MAX_LOGICAL_CLOCK + 1;

        let mut target = EventLog::new("phone", root);
        assert!(matches!(
            target.ingest(envelope),
            Err(CoreError::InvalidEnvelope)
        ));
        assert_eq!(target.records().unwrap().len(), 0);
    }

    #[test]
    fn two_device_concurrent_edits_replay_identically_in_any_arrival_order() {
        let root = AccountRootKey::generate();
        let mut mac = EventLog::new("mac", root.clone());
        let mut phone = EventLog::new("phone", root.clone());

        // Both devices edit the same stable aggregate while offline. The
        // projection ordering, rather than network arrival order, chooses the
        // deterministic winner for this v1 last-writer-wins operation.
        let mac_edit = mac
            .append(EventPayload::JournalUpsert(JournalEntry {
                id: "mac:v1:journal:2026-08-01".to_owned(),
                day: "2026-08-01".to_owned(),
                body: "Mac edit".to_owned(),
            }))
            .unwrap();
        let phone_edit = phone
            .append(EventPayload::JournalUpsert(JournalEntry {
                id: "mac:v1:journal:2026-08-01".to_owned(),
                day: "2026-08-01".to_owned(),
                body: "Phone edit".to_owned(),
            }))
            .unwrap();
        let tombstone = phone
            .append(EventPayload::Tombstone {
                target_id: "mac:v1:journal:2026-08-01".to_owned(),
            })
            .unwrap();

        let mut arrival_a = EventLog::new("replay-a", root.clone());
        for envelope in [tombstone.clone(), phone_edit.clone(), mac_edit.clone()] {
            arrival_a.ingest(envelope).unwrap();
        }
        // Duplicate delivery must be a no-op even when it is interleaved with
        // a different device's event.
        assert!(!arrival_a.ingest(phone_edit.clone()).unwrap());

        let mut arrival_b = EventLog::new("replay-b", root);
        for envelope in [mac_edit, phone_edit, tombstone] {
            arrival_b.ingest(envelope).unwrap();
        }

        assert_eq!(arrival_a.project().unwrap(), arrival_b.project().unwrap());
        let projection = arrival_a.project().unwrap();
        assert!(projection.journal_entries.is_empty());
        assert!(projection.tombstones.contains("mac:v1:journal:2026-08-01"));
    }

    #[test]
    fn capture_derived_payload_is_metadata_only() {
        let payload = EventPayload::CaptureDerived(CaptureDerived {
            id: "capture-1".to_owned(),
            day: "2026-08-01".to_owned(),
            start_timestamp: 1,
            end_timestamp: 2,
            title: "Activity observed locally".to_owned(),
            summary: "A metadata summary".to_owned(),
            category: "activity_capture".to_owned(),
            source: "android_media_projection".to_owned(),
            derivation_mode: "privacy_gated_local_metadata".to_owned(),
        });
        let encoded = serde_json::to_string(&payload).unwrap();
        let document: serde_json::Value = serde_json::from_str(&encoded).unwrap();
        let value = document
            .get("value")
            .and_then(serde_json::Value::as_object)
            .unwrap();
        let keys = value.keys().map(String::as_str).collect::<Vec<_>>();
        assert_eq!(
            keys,
            vec![
                "category",
                "day",
                "derivation_mode",
                "end_timestamp",
                "id",
                "source",
                "start_timestamp",
                "summary",
                "title",
            ]
        );
        assert_eq!(
            value.get("title").and_then(serde_json::Value::as_str),
            Some("Activity observed locally")
        );
        assert!(!encoded.contains("video_summary_url"));
        assert!(!encoded.contains("file_path"));
        assert!(!encoded.contains("screenshot"));
        assert!(!encoded.contains("recording"));
        assert!(!encoded.contains("pixels"));
    }

    #[test]
    fn capture_payload_rejects_unknown_media_fields_before_sealing() {
        let payload = serde_json::json!({
            "kind": "CaptureDerived",
            "value": {
                "id": "capture-1",
                "day": "2026-08-01",
                "start_timestamp": 1,
                "end_timestamp": 2,
                "title": "Activity observed locally",
                "summary": "A metadata summary",
                "category": "activity_capture",
                "source": "windows_graphics_capture",
                "derivation_mode": "privacy_gated_foreground_metadata",
                "screenshot": "data:image/png;base64,not-an-event-field"
            }
        });

        assert!(serde_json::from_value::<EventPayload>(payload).is_err());
    }

    #[test]
    fn legacy_capture_payload_defaults_provenance_without_breaking_replay() {
        let legacy = serde_json::json!({
            "kind": "CaptureDerived",
            "value": {
                "id": "legacy-capture",
                "day": "2026-08-01",
                "start_timestamp": 1,
                "end_timestamp": 2,
                "title": "Legacy activity",
                "summary": "Created before provenance was added",
                "category": "activity_capture"
            }
        });

        let decoded: EventPayload = serde_json::from_value(legacy).unwrap();
        let EventPayload::CaptureDerived(capture) = decoded else {
            panic!("expected capture-derived payload");
        };
        assert!(capture.source.is_empty());
        assert!(capture.derivation_mode.is_empty());
    }

    #[test]
    fn offline_queue_is_replayable() {
        let root = AccountRootKey::generate();
        let mut log = EventLog::new("mac", root);
        let first = log.append(card("one")).unwrap();
        let second = log.append(card("two")).unwrap();
        let mut queue = SyncQueue::default();
        queue.enqueue(first.clone()).unwrap();
        queue.enqueue(first).unwrap();
        queue.enqueue(second).unwrap();
        assert_eq!(queue.pending().len(), 2);
    }

    #[test]
    fn out_of_order_delivery_produces_the_same_projection() {
        let root = AccountRootKey::generate();
        let mut mac = EventLog::new("mac", root.clone());
        let mut phone = EventLog::new("phone", root.clone());
        let mac_event = mac.append(card("mac-card")).unwrap();
        let phone_event = phone.append(card("phone-card")).unwrap();

        let mut first_arrival_order = EventLog::new("laptop", root.clone());
        first_arrival_order.ingest(phone_event.clone()).unwrap();
        first_arrival_order.ingest(mac_event.clone()).unwrap();

        let mut second_arrival_order = EventLog::new("laptop", root);
        second_arrival_order.ingest(mac_event).unwrap();
        second_arrival_order.ingest(phone_event).unwrap();

        assert_eq!(
            first_arrival_order.project().unwrap(),
            second_arrival_order.project().unwrap()
        );
    }

    #[test]
    fn historical_key_versions_replay_after_rotation() {
        let first = AccountRootKey::generate();
        let second = AccountRootKey::generate();
        let mut log = EventLog::new("mac", first.clone());
        log.append(card("before-rotation")).unwrap();
        log.add_key_version(2, second.clone()).unwrap();
        log.set_active_key_version(2).unwrap();
        log.append(card("after-rotation")).unwrap();

        let mut envelopes = log.envelopes().cloned().collect::<Vec<_>>();
        envelopes.sort_by_key(|envelope| envelope.logical_clock);
        assert_eq!(envelopes[0].key_version, 1);
        assert_eq!(envelopes[1].key_version, 2);

        let mut replay = EventLog::new("phone", first);
        replay.add_key_version(2, second).unwrap();
        for envelope in envelopes.into_iter().rev() {
            replay.ingest(envelope).unwrap();
        }
        assert_eq!(replay.project().unwrap(), log.project().unwrap());
    }
}
