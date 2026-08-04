use std::collections::BTreeMap;

use crate::crypto::{
    export_recovery_kit_for_keyring, restore_recovery_key_set, seal_event, unwrap_account_key,
    wrap_account_key, wrap_account_key_versioned, AccountKeyRing, DeviceKeyPair,
    DeviceSigningKeyPair,
};
use crate::events::{rekey_envelope, EventPayload};
use crate::{
    export_recovery_kit, logical_day_key, restore_recovery_kit, AccountRootKey, CaptureContext,
    EventEnvelope, EventLog, PrivacyPolicy, EVENT_SCHEMA_VERSION, MAX_LOGICAL_CLOCK,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};

#[derive(Debug, uniffi::Error, thiserror::Error)]
pub enum FfiError {
    #[error("invalid root key")]
    InvalidRootKey,
    #[error("invalid event JSON: {0}")]
    InvalidEventJson(String),
    #[error("core operation failed: {0}")]
    Core(String),
}

impl From<crate::CoreError> for FfiError {
    fn from(error: crate::CoreError) -> Self {
        Self::Core(error.to_string())
    }
}

#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[uniffi::export]
pub fn generate_account_root_key() -> Vec<u8> {
    AccountRootKey::generate().as_bytes().to_vec()
}

#[uniffi::export]
pub fn logical_day_key_ffi(
    timestamp_unix: i64,
    timezone_offset_minutes: i32,
    boundary_hour: u8,
) -> Result<String, FfiError> {
    logical_day_key(timestamp_unix, timezone_offset_minutes, boundary_hour).map_err(Into::into)
}

#[uniffi::export]
pub fn capture_allowed(
    permission_granted: bool,
    user_paused: bool,
    device_locked: bool,
    sleeping: bool,
    private_context: bool,
    drm_content: bool,
) -> bool {
    let context = crate::CaptureContext {
        permission_granted,
        user_paused,
        device_locked,
        sleeping,
        private_context,
        drm_content,
        application_id: None,
        window_title: None,
    };
    matches!(
        PrivacyPolicy::default().decide(&context),
        crate::CaptureDecision::Capture
    )
}

/// Evaluate capture context and user privacy policy together. Native clients
/// pass JSON so platform-specific app/window metadata can reach the same Rust
/// policy instead of silently falling back to a boolean-only default.
#[uniffi::export]
pub fn capture_decision_json(
    context_json: String,
    policy_json: String,
) -> Result<String, FfiError> {
    let context: CaptureContext = serde_json::from_str(&context_json)
        .map_err(|error| FfiError::Core(format!("invalid capture context JSON: {error}")))?;
    let policy: PrivacyPolicy = serde_json::from_str(&policy_json)
        .map_err(|error| FfiError::Core(format!("invalid privacy policy JSON: {error}")))?;
    let decision = policy.decide(&context);
    serde_json::to_string(&serde_json::json!({
        "allowed": matches!(decision, crate::CaptureDecision::Capture),
        "reason": decision.reason(),
    }))
    .map_err(|error| FfiError::Core(error.to_string()))
}

/// Build the exact request string signed by native relay clients. Body bytes
/// are hashed inside Rust so Swift, Kotlin, and C# share one implementation.
#[uniffi::export]
pub fn canonical_device_request(
    method: String,
    path_with_query: String,
    body: Vec<u8>,
    timestamp: i64,
    nonce: String,
    device_id: String,
) -> Result<String, FfiError> {
    crate::request::canonical_device_request(
        &method,
        &path_with_query,
        &body,
        timestamp,
        &nonce,
        &device_id,
    )
    .map_err(|error| FfiError::Core(error.to_string()))
}

#[uniffi::export]
pub fn project_json(envelopes_json: String, account_root_key: Vec<u8>) -> Result<String, FfiError> {
    let root_key: [u8; 32] = account_root_key
        .try_into()
        .map_err(|_| FfiError::InvalidRootKey)?;
    let envelopes: Vec<EventEnvelope> = serde_json::from_str(&envelopes_json)
        .map_err(|error| FfiError::InvalidEventJson(error.to_string()))?;
    let mut log = EventLog::new("uniffi", AccountRootKey::from_bytes(root_key));
    for envelope in envelopes {
        log.ingest(envelope)?;
    }
    serde_json::to_string(&log.project()?).map_err(|error| FfiError::Core(error.to_string()))
}

/// Replay an envelope stream using the locally retained versioned account keys.
/// The key-ring document never leaves the native process for the relay.
#[uniffi::export]
pub fn project_keyring_json(
    envelopes_json: String,
    key_ring_json: String,
) -> Result<String, FfiError> {
    let envelopes: Vec<EventEnvelope> = serde_json::from_str(&envelopes_json)
        .map_err(|error| FfiError::InvalidEventJson(error.to_string()))?;
    let key_ring = parse_key_ring_json(&key_ring_json)?;
    let mut log = EventLog::with_key_ring("uniffi", key_ring);
    for envelope in envelopes {
        log.ingest(envelope)?;
    }
    serde_json::to_string(&log.project()?).map_err(|error| FfiError::Core(error.to_string()))
}

/// Re-encrypt an existing local event stream when a signed-out local
/// workspace is linked to a Dayflow account. Event IDs, device IDs, logical
/// clocks, and payload semantics remain unchanged; only the authenticated
/// ciphertext and destination key version change.
#[uniffi::export]
pub fn rekey_envelopes_json(
    envelopes_json: String,
    source_key_ring_json: String,
    destination_key_ring_json: String,
) -> Result<String, FfiError> {
    let envelopes: Vec<EventEnvelope> = serde_json::from_str(&envelopes_json)
        .map_err(|error| FfiError::InvalidEventJson(error.to_string()))?;
    let source_key_ring = parse_key_ring_json(&source_key_ring_json)?;
    let destination_key_ring = parse_key_ring_json(&destination_key_ring_json)?;
    let rekeyed = envelopes
        .iter()
        .map(|envelope| rekey_envelope(envelope, &source_key_ring, &destination_key_ring))
        .collect::<Result<Vec<_>, _>>()?;
    serde_json::to_string(&rekeyed).map_err(|error| FfiError::Core(error.to_string()))
}

#[uniffi::export]
pub fn seal_json(
    payload_json: String,
    event_id: String,
    device_id: String,
    logical_clock: u64,
    account_root_key: Vec<u8>,
) -> Result<String, FfiError> {
    let root_key: [u8; 32] = account_root_key
        .try_into()
        .map_err(|_| FfiError::InvalidRootKey)?;
    if event_id.trim().is_empty()
        || device_id.trim().is_empty()
        || logical_clock == 0
        || logical_clock > MAX_LOGICAL_CLOCK
    {
        return Err(FfiError::Core(
            "event ID, device ID, and logical clock are required".to_owned(),
        ));
    }
    let payload: EventPayload = serde_json::from_str(&payload_json)
        .map_err(|error| FfiError::InvalidEventJson(error.to_string()))?;
    payload.validate()?;
    let bytes = serde_json::to_vec(&payload).map_err(|error| FfiError::Core(error.to_string()))?;
    let (nonce, ciphertext) = seal_event(
        &AccountRootKey::from_bytes(root_key),
        &event_id,
        &device_id,
        logical_clock,
        EVENT_SCHEMA_VERSION,
        1,
        &bytes,
    )
    .map_err(FfiError::from)?;
    serde_json::to_string(&EventEnvelope {
        event_id,
        device_id,
        logical_clock,
        schema_version: EVENT_SCHEMA_VERSION,
        key_version: 1,
        nonce,
        ciphertext,
    })
    .map_err(|error| FfiError::Core(error.to_string()))
}

#[uniffi::export]
pub fn seal_json_with_key_version(
    payload_json: String,
    event_id: String,
    device_id: String,
    logical_clock: u64,
    key_version: u32,
    account_root_key: Vec<u8>,
) -> Result<String, FfiError> {
    let root_key: [u8; 32] = account_root_key
        .try_into()
        .map_err(|_| FfiError::InvalidRootKey)?;
    if event_id.trim().is_empty()
        || device_id.trim().is_empty()
        || logical_clock == 0
        || logical_clock > MAX_LOGICAL_CLOCK
        || key_version == 0
    {
        return Err(FfiError::Core(
            "event ID, device ID, logical clock, and key version are required".to_owned(),
        ));
    }
    let payload: EventPayload = serde_json::from_str(&payload_json)
        .map_err(|error| FfiError::InvalidEventJson(error.to_string()))?;
    payload.validate()?;
    let bytes = serde_json::to_vec(&payload).map_err(|error| FfiError::Core(error.to_string()))?;
    let (nonce, ciphertext) = seal_event(
        &crate::AccountRootKey::from_bytes(root_key),
        &event_id,
        &device_id,
        logical_clock,
        EVENT_SCHEMA_VERSION,
        key_version,
        &bytes,
    )
    .map_err(FfiError::from)?;
    serde_json::to_string(&EventEnvelope {
        event_id,
        device_id,
        logical_clock,
        schema_version: EVENT_SCHEMA_VERSION,
        key_version,
        nonce,
        ciphertext,
    })
    .map_err(|error| FfiError::Core(error.to_string()))
}

#[uniffi::export]
pub fn wrap_account_key_json(
    account_root_key: Vec<u8>,
    recipient_device_id: String,
    recipient_public_key: Vec<u8>,
) -> Result<String, FfiError> {
    let root_key: [u8; 32] = account_root_key
        .try_into()
        .map_err(|_| FfiError::InvalidRootKey)?;
    let public_key: [u8; 32] = recipient_public_key
        .try_into()
        .map_err(|_| FfiError::Core("invalid recipient public key".to_owned()))?;
    let wrapped = wrap_account_key(
        &AccountRootKey::from_bytes(root_key),
        &recipient_device_id,
        &public_key,
    )
    .map_err(FfiError::from)?;
    serde_json::to_string(&wrapped).map_err(|error| FfiError::Core(error.to_string()))
}

#[uniffi::export]
pub fn wrap_account_key_json_with_version(
    account_root_key: Vec<u8>,
    key_version: u32,
    recipient_device_id: String,
    recipient_public_key: Vec<u8>,
) -> Result<String, FfiError> {
    let root_key: [u8; 32] = account_root_key
        .try_into()
        .map_err(|_| FfiError::InvalidRootKey)?;
    let public_key: [u8; 32] = recipient_public_key
        .try_into()
        .map_err(|_| FfiError::Core("invalid recipient public key".to_owned()))?;
    let wrapped = wrap_account_key_versioned(
        &crate::AccountRootKey::from_bytes(root_key),
        key_version,
        &recipient_device_id,
        &public_key,
    )
    .map_err(FfiError::from)?;
    serde_json::to_string(&wrapped).map_err(|error| FfiError::Core(error.to_string()))
}

#[uniffi::export]
pub fn unwrap_account_key_json(
    wrapped_key_json: String,
    recipient_private_key: Vec<u8>,
) -> Result<Vec<u8>, FfiError> {
    let private_key: [u8; 32] = recipient_private_key
        .try_into()
        .map_err(|_| FfiError::Core("invalid recipient private key".to_owned()))?;
    let wrapped = serde_json::from_str(&wrapped_key_json)
        .map_err(|error| FfiError::Core(format!("invalid wrapped key JSON: {error}")))?;
    let root_key = unwrap_account_key(&wrapped, &DeviceKeyPair::from_private_bytes(private_key))
        .map_err(FfiError::from)?;
    Ok(root_key.as_bytes().to_vec())
}

#[uniffi::export]
pub fn export_recovery_kit_json(
    account_root_key: Vec<u8>,
    passphrase: String,
) -> Result<String, FfiError> {
    let root_key: [u8; 32] = account_root_key
        .try_into()
        .map_err(|_| FfiError::InvalidRootKey)?;
    let kit = export_recovery_kit(&AccountRootKey::from_bytes(root_key), &passphrase)
        .map_err(FfiError::from)?;
    serde_json::to_string(&kit).map_err(|error| FfiError::Core(error.to_string()))
}

#[uniffi::export]
pub fn restore_recovery_key(kit_json: String, passphrase: String) -> Result<Vec<u8>, FfiError> {
    let kit = serde_json::from_str(&kit_json)
        .map_err(|error| FfiError::Core(format!("invalid recovery kit JSON: {error}")))?;
    let root_key = restore_recovery_kit(&kit, &passphrase).map_err(FfiError::from)?;
    Ok(root_key.as_bytes().to_vec())
}

#[uniffi::export]
pub fn export_recovery_kit_keyring_json(
    key_ring_json: String,
    passphrase: String,
) -> Result<String, FfiError> {
    let key_ring = parse_key_ring_json(&key_ring_json)?;
    let kit = export_recovery_kit_for_keyring(&key_ring, &passphrase).map_err(FfiError::from)?;
    serde_json::to_string(&kit).map_err(|error| FfiError::Core(error.to_string()))
}

#[uniffi::export]
pub fn restore_recovery_keyring_json(
    kit_json: String,
    passphrase: String,
) -> Result<String, FfiError> {
    let kit = serde_json::from_str(&kit_json)
        .map_err(|error| FfiError::Core(format!("invalid recovery kit JSON: {error}")))?;
    let key_ring = restore_recovery_key_set(&kit, &passphrase).map_err(FfiError::from)?;
    let keys = key_ring
        .key_material()
        .map(|(version, key)| (version.to_string(), B64.encode(key.as_bytes())))
        .collect::<BTreeMap<_, _>>();
    serde_json::to_string(&KeyRingWire {
        active_key_version: key_ring.active_version(),
        keys,
    })
    .map_err(|error| FfiError::Core(error.to_string()))
}

#[uniffi::export]
pub fn generate_device_private_key() -> Vec<u8> {
    DeviceKeyPair::generate().private_bytes().to_vec()
}

#[uniffi::export]
pub fn device_public_key(private_key: Vec<u8>) -> Result<Vec<u8>, FfiError> {
    let bytes: [u8; 32] = private_key
        .try_into()
        .map_err(|_| FfiError::InvalidRootKey)?;
    Ok(DeviceKeyPair::from_private_bytes(bytes)
        .public_key()
        .to_vec())
}

#[uniffi::export]
pub fn generate_device_signing_private_key() -> Vec<u8> {
    DeviceSigningKeyPair::generate().private_bytes().to_vec()
}

#[uniffi::export]
pub fn device_signing_public_key(private_key: Vec<u8>) -> Result<Vec<u8>, FfiError> {
    let bytes: [u8; 32] = private_key
        .try_into()
        .map_err(|_| FfiError::InvalidRootKey)?;
    Ok(DeviceSigningKeyPair::from_private_bytes(bytes)
        .public_key()
        .to_vec())
}

#[uniffi::export]
pub fn sign_request(message: String, private_key: Vec<u8>) -> Result<Vec<u8>, FfiError> {
    let bytes: [u8; 32] = private_key
        .try_into()
        .map_err(|_| FfiError::InvalidRootKey)?;
    if message.is_empty() {
        return Err(FfiError::Core("request message is required".to_owned()));
    }
    Ok(DeviceSigningKeyPair::from_private_bytes(bytes)
        .sign(message.as_bytes())
        .to_vec())
}

#[derive(serde::Deserialize, serde::Serialize)]
struct KeyRingWire {
    active_key_version: u32,
    keys: BTreeMap<String, String>,
}

fn parse_key_ring_json(value: &str) -> Result<AccountKeyRing, FfiError> {
    let wire: KeyRingWire = serde_json::from_str(value)
        .map_err(|error| FfiError::Core(format!("invalid key-ring JSON: {error}")))?;
    let keys = wire
        .keys
        .into_iter()
        .map(|(version, encoded)| {
            let version = version
                .parse::<u32>()
                .map_err(|_| FfiError::Core("key-ring version is not an integer".to_owned()))?;
            let bytes: [u8; 32] = B64
                .decode(encoded)
                .map_err(|_| FfiError::Core("key-ring key is not valid base64".to_owned()))?
                .try_into()
                .map_err(|_| FfiError::Core("key-ring keys must contain 32 bytes".to_owned()))?;
            Ok((version, crate::AccountRootKey::from_bytes(bytes)))
        })
        .collect::<Result<BTreeMap<_, _>, FfiError>>()?;
    AccountKeyRing::from_keys(keys, wire.active_key_version).map_err(FfiError::from)
}
