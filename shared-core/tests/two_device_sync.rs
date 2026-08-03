use std::collections::BTreeMap;

use dayflow_core::{
    export_recovery_kit_for_keyring, restore_recovery_key_set, unwrap_account_key_versioned,
    wrap_account_key_versioned, AccountKeyRing, AccountRootKey, CaptureContext, CaptureDecision,
    CaptureDerived, CoreError, DeviceKeyPair, EventEnvelope, EventLog, EventPayload, JournalEntry,
    Priority, PrivacyPolicy, SyncQueue,
};

/// A deliberately small relay double for the cross-device acceptance test.
/// It stores routing metadata and ciphertext only; it has no account key and
/// cannot construct an EventRecord or ProjectionState.
#[derive(Clone, Default)]
struct OpaqueRelay {
    next_sequence: u64,
    events: BTreeMap<String, (u64, EventEnvelope)>,
}

impl OpaqueRelay {
    fn push(
        &mut self,
        envelopes: &[EventEnvelope],
    ) -> Result<(Vec<String>, Vec<String>), CoreError> {
        let mut candidate = self.clone();
        let mut accepted = Vec::new();
        let mut duplicates = Vec::new();

        for envelope in envelopes {
            if let Some((_, existing)) = candidate.events.get(&envelope.event_id) {
                if existing == envelope {
                    duplicates.push(envelope.event_id.clone());
                    continue;
                }
                return Err(CoreError::ConflictingEvent);
            }

            candidate.next_sequence = candidate.next_sequence.saturating_add(1);
            candidate.events.insert(
                envelope.event_id.clone(),
                (candidate.next_sequence, envelope.clone()),
            );
            accepted.push(envelope.event_id.clone());
        }

        *self = candidate;
        Ok((accepted, duplicates))
    }

    fn pull_after(&self, cursor: u64) -> (u64, Vec<EventEnvelope>) {
        let mut events = self
            .events
            .values()
            .filter(|(sequence, _)| *sequence > cursor)
            .map(|(_, envelope)| envelope.clone())
            .collect::<Vec<_>>();
        let next_cursor = self
            .events
            .values()
            .filter_map(|(sequence, _)| (*sequence > cursor).then_some(*sequence))
            .max()
            .unwrap_or(cursor);

        // A client must not depend on relay sequence order for projection
        // semantics. Reverse the batch to model an out-of-order transport.
        events.reverse();
        (next_cursor, events)
    }

    fn all_events_in_wire_form(&self) -> String {
        serde_json::to_string(
            &self
                .events
                .values()
                .map(|(_, envelope)| envelope)
                .collect::<Vec<_>>(),
        )
        .expect("event envelopes are serializable")
    }
}

fn journal(body: &str) -> EventPayload {
    EventPayload::JournalUpsert(JournalEntry {
        id: "mac:v1:journal:2026-08-01".to_owned(),
        day: "2026-08-01".to_owned(),
        body: body.to_owned(),
    })
}

fn queue_all(queue: &mut SyncQueue, envelopes: impl IntoIterator<Item = EventEnvelope>) {
    for envelope in envelopes {
        queue
            .enqueue(envelope)
            .expect("local event IDs are immutable");
    }
}

#[test]
fn two_devices_replay_offline_edits_through_an_opaque_relay() {
    let first_key = AccountRootKey::generate();
    let mut mac = EventLog::new("mac", first_key.clone());

    // Device approval delivers the existing account key over a device-bound
    // wrapper. The relay double never receives either private key or plaintext.
    let phone_device_key = DeviceKeyPair::generate();
    let wrapped_first =
        wrap_account_key_versioned(&first_key, 1, "phone", &phone_device_key.public_key()).unwrap();
    let (first_version, phone_first_key) =
        unwrap_account_key_versioned(&wrapped_first, &phone_device_key).unwrap();
    assert_eq!(first_version, 1);
    let mut phone_key_ring = AccountKeyRing::new(phone_first_key);

    // Both devices make local edits while offline. A second key version is
    // active on the Mac before the phone receives the rotation wrapper.
    mac.append(journal("Mac offline journal")).unwrap();
    let second_key = AccountRootKey::generate();
    mac.add_key_version(2, second_key.clone()).unwrap();
    mac.set_active_key_version(2).unwrap();
    let wrapped_second =
        wrap_account_key_versioned(&second_key, 2, "phone", &phone_device_key.public_key())
            .unwrap();
    let (second_version, phone_second_key) =
        unwrap_account_key_versioned(&wrapped_second, &phone_device_key).unwrap();
    phone_key_ring
        .insert(second_version, phone_second_key)
        .unwrap();
    phone_key_ring.set_active_version(2).unwrap();
    let mut phone = EventLog::with_key_ring("phone", phone_key_ring);

    let mac_priority = mac
        .append(EventPayload::PriorityUpsert(Priority {
            id: "dayflow:v1:priority:one".to_owned(),
            day: "2026-08-01".to_owned(),
            rank: 0,
            text: "Finish the unified sync slice".to_owned(),
            status: "active".to_owned(),
        }))
        .unwrap();
    let phone_journal = phone.append(journal("Phone offline journal")).unwrap();
    let phone_tombstone = phone
        .append(EventPayload::Tombstone {
            target_id: "dayflow:v1:priority:one".to_owned(),
        })
        .unwrap();

    let mac_events = mac.envelopes().cloned().collect::<Vec<_>>();
    let phone_events = phone.envelopes().cloned().collect::<Vec<_>>();
    assert_eq!(mac_events.len(), 2);
    assert_eq!(phone_events.len(), 2);
    assert!(mac_events.iter().any(|envelope| envelope.key_version == 2));

    let mut relay = OpaqueRelay::default();
    let mut mac_queue = SyncQueue::default();
    queue_all(&mut mac_queue, mac_events.clone());

    // The first response is lost after the relay commits. The exact retry is
    // a duplicate, then the client acknowledges its durable outbox.
    let (accepted, duplicates) = relay.push(&mac_queue.pending()).unwrap();
    assert_eq!(accepted.len(), 2);
    assert!(duplicates.is_empty());
    let (accepted_retry, duplicates_retry) = relay.push(&mac_queue.pending()).unwrap();
    assert!(accepted_retry.is_empty());
    assert_eq!(duplicates_retry.len(), 2);
    assert_eq!(mac_queue.acknowledge(accepted.into_iter()), 2);
    assert!(mac_queue.is_empty());

    let mut phone_queue = SyncQueue::default();
    queue_all(&mut phone_queue, phone_events.clone());
    relay.push(&phone_queue.pending()).unwrap();
    let phone_ids = phone_queue
        .pending()
        .into_iter()
        .map(|envelope| envelope.event_id)
        .collect::<Vec<_>>();
    assert_eq!(phone_queue.acknowledge(phone_ids), 2);
    assert!(phone_queue.is_empty());

    // The serialized relay state contains only the envelope shape. None of the
    // local journal text or projection payload is present server-side.
    let wire = relay.all_events_in_wire_form();
    assert!(!wire.contains("Mac offline journal"));
    assert!(!wire.contains("Phone offline journal"));
    assert!(!wire.contains("Finish the unified sync slice"));
    assert!(!wire.contains("payload"));

    let (cursor, out_of_order_events) = relay.pull_after(0);
    assert_eq!(out_of_order_events.len(), 4);
    let mut mac_after_sync = mac;
    let mut phone_after_sync = phone;
    for envelope in out_of_order_events {
        mac_after_sync.ingest(envelope.clone()).unwrap();
        phone_after_sync.ingest(envelope).unwrap();
    }
    assert_eq!(
        mac_after_sync.project().unwrap(),
        phone_after_sync.project().unwrap()
    );
    assert_eq!(
        mac_after_sync
            .project()
            .unwrap()
            .tombstones
            .iter()
            .collect::<Vec<_>>(),
        vec![&"dayflow:v1:priority:one".to_owned()]
    );

    // A duplicate batch after the cursor is harmless, and a replay from a
    // fresh cursor reconstructs the same projection for a new device.
    let (_, duplicate_batch) = relay.pull_after(0);
    for envelope in duplicate_batch {
        assert!(!mac_after_sync.ingest(envelope).unwrap());
    }
    let mut recovery_device =
        EventLog::with_key_ring("recovery", mac_after_sync.key_ring().clone());
    let (_, recovery_batch) = relay.pull_after(0);
    for envelope in recovery_batch {
        recovery_device.ingest(envelope).unwrap();
    }
    assert_eq!(
        recovery_device.project().unwrap(),
        mac_after_sync.project().unwrap()
    );
    assert_eq!(cursor, 4);

    // Recovery material retains both event-key versions, so a device restored
    // after rotation can decrypt the full history without server plaintext.
    let kit =
        export_recovery_kit_for_keyring(mac_after_sync.key_ring(), "test passphrase").unwrap();
    let restored_ring = restore_recovery_key_set(&kit, "test passphrase").unwrap();
    assert_eq!(restored_ring.versions().collect::<Vec<_>>(), vec![1, 2]);
    assert_eq!(restored_ring.active_version(), 2);

    // Keep an explicit use of the second-version event in the test so a future
    // change cannot accidentally remove rotation coverage from the scenario.
    assert_eq!(mac_priority.key_version, 2);
    assert_eq!(phone_journal.key_version, 2);
    assert_eq!(phone_tombstone.key_version, 2);
}

#[test]
fn relay_rejects_a_conflicting_immutable_event_without_partial_push() {
    let root = AccountRootKey::generate();
    let mut source = EventLog::new("mac", root);
    let original = source.append(journal("original")).unwrap();
    let mut conflicting = original.clone();
    conflicting.ciphertext.push('x');
    let second = source.append(journal("second")).unwrap();

    let mut relay = OpaqueRelay::default();
    relay.push(std::slice::from_ref(&original)).unwrap();
    assert!(matches!(
        relay.push(&[second, conflicting]),
        Err(CoreError::ConflictingEvent)
    ));
    assert_eq!(relay.events.len(), 1);
    assert_eq!(relay.events[&original.event_id].1, original);
}

#[test]
fn capture_derived_event_replays_from_privacy_gate_through_opaque_relay_into_local_chat() {
    let root = AccountRootKey::generate();
    let mut source = EventLog::new("android", root.clone());
    let policy = PrivacyPolicy::default();
    let capture_context = CaptureContext {
        permission_granted: true,
        application_id: Some("com.example.editor".to_owned()),
        window_title: Some("Dayflow planning".to_owned()),
        ..Default::default()
    };
    assert_eq!(policy.decide(&capture_context), CaptureDecision::Capture);

    source
        .append(EventPayload::CaptureDerived(CaptureDerived {
            id: "capture:v1:android:2026-08-02T10:00:00Z".to_owned(),
            day: "2026-08-02".to_owned(),
            start_timestamp: 1_754_132_400,
            end_timestamp: 1_754_132_460,
            title: "Drafted the launch checklist".to_owned(),
            summary: "Local metadata was accepted after the privacy gate.".to_owned(),
            category: "work".to_owned(),
            source: "android_media_projection".to_owned(),
            derivation_mode: "privacy_gated_local_metadata".to_owned(),
        }))
        .unwrap();

    let source_projection = source.project().unwrap();
    let envelopes = source.envelopes().cloned().collect::<Vec<_>>();
    let mut relay = OpaqueRelay::default();
    relay.push(&envelopes).unwrap();

    let wire = relay.all_events_in_wire_form();
    assert!(!wire.contains("Drafted the launch checklist"));
    assert!(!wire.contains("Local metadata was accepted"));
    assert!(!wire.contains("android_media_projection"));
    assert!(!wire.contains("privacy_gated_local_metadata"));

    let (_, replay_batch) = relay.pull_after(0);
    let mut destination = EventLog::new("mac", root);
    for envelope in replay_batch {
        destination.ingest(envelope).unwrap();
    }

    let destination_projection = destination.project().unwrap();
    assert_eq!(destination_projection, source_projection);
    let card = &destination_projection.timeline_cards["capture:v1:android:2026-08-02T10:00:00Z"];
    assert_eq!(card.source, "android_media_projection");
    assert_eq!(card.derivation_mode, "privacy_gated_local_metadata");
    let chat_item = destination_projection
        .chat_context
        .iter()
        .find(|item| item.id == card.id)
        .expect("captured card should be available to destination chat");
    assert_eq!(chat_item.kind, "timeline_card");
    assert!(chat_item.content.contains("Drafted the launch checklist"));
    assert!(chat_item.content.contains("privacy_gated_local_metadata"));
}
