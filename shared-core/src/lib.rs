//! Dayflow's portable multi-device foundation.
//!
//! This crate intentionally owns only platform-neutral behavior. Capture adapters,
//! secure-store integration, local database drivers, and UI remain native to each
//! client. The public types in this crate are the wire and projection contracts
//! those clients share.

mod crypto;
mod day_boundary;
mod events;
mod ffi;
mod privacy;
mod projection;
mod request;
mod sync;

#[cfg(feature = "uniffi")]
mod uniffi_bindings;

#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();

pub use crypto::{
    export_recovery_kit, export_recovery_kit_for_keyring, open_event, open_event_with_keyring,
    restore_recovery_key_set, restore_recovery_kit, seal_event, seal_event_with_keyring,
    unwrap_account_key, unwrap_account_key_versioned, wrap_account_key, wrap_account_key_versioned,
    AccountKeyRing, AccountRootKey, DeviceKeyPair, DeviceSigningKeyPair, RecoveryKit,
    WrappedAccountKey,
};
pub use day_boundary::{logical_day_key, DEFAULT_LOGICAL_DAY_BOUNDARY_HOUR};
pub use events::{
    rekey_envelope, CaptureDerived, EventEnvelope, EventKind, EventLog, EventPayload, EventRecord,
    JournalEntry, Priority, Reflection, TimelineCard,
};
pub use ffi::{
    dayflow_core_canonical_device_request_json, dayflow_core_capture_decision_json,
    dayflow_core_export_recovery_kit_keyring_json, dayflow_core_free_string,
    dayflow_core_generate_account_root_key_json, dayflow_core_generate_device_signing_keypair_json,
    dayflow_core_logical_day_key, dayflow_core_project_json, dayflow_core_project_keyring_json,
    dayflow_core_rekey_envelopes_json, dayflow_core_restore_recovery_keyring_json,
    dayflow_core_seal_key_version_json, dayflow_core_sign_request_json, dayflow_core_version,
    dayflow_core_wrap_account_key_versioned_json,
};
pub use privacy::{CaptureContext, CaptureDecision, PrivacyPolicy, SkipReason};
pub use projection::{ChatContextItem, ProjectionState};
pub use sync::SyncQueue;

/// Schema version carried by every encrypted event envelope.
pub const EVENT_SCHEMA_VERSION: u16 = 1;
/// Largest logical clock that can cross the JSON/JavaScript relay boundary
/// without losing integer precision.
pub const MAX_LOGICAL_CLOCK: u64 = 9_007_199_254_740_991;

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("invalid timestamp")]
    InvalidTimestamp,
    #[error("logical day boundary hour must be between 0 and 23")]
    InvalidBoundaryHour,
    #[error("timezone offset is outside the supported range")]
    InvalidTimezoneOffset,
    #[error("invalid key material")]
    InvalidKey,
    #[error("unknown account key version: {0}")]
    InvalidKeyVersion(u32),
    #[error("account key version conflicts with retained key: {0}")]
    ConflictingKeyVersion(u32),
    #[error("invalid event envelope")]
    InvalidEnvelope,
    #[error("event ID conflicts with an existing immutable envelope")]
    ConflictingEvent,
    #[error("cryptographic operation failed")]
    Crypto,
    #[error("recovery kit is invalid or uses an unsupported version")]
    InvalidRecoveryKit,
    #[error("serialization failed: {0}")]
    Serialization(String),
    #[error("input contains an interior NUL byte")]
    InteriorNul,
    #[error("logical clock is exhausted")]
    LogicalClockExhausted,
    #[error("shared setting key is not allowed")]
    InvalidSettingKey,
    #[error("shared capture pause setting must be true or false")]
    InvalidSettingValue,
}
