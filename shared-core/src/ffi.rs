use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use crate::crypto::{
    export_recovery_kit_for_keyring, restore_recovery_key_set, seal_event, unwrap_account_key,
    wrap_account_key, wrap_account_key_versioned, AccountKeyRing, DeviceKeyPair,
    DeviceSigningKeyPair,
};
use crate::events::{rekey_envelope, EventPayload};
use crate::request::canonical_device_request;
use crate::{
    export_recovery_kit, logical_day_key, restore_recovery_kit, AccountRootKey, EventEnvelope,
    EventLog, PrivacyPolicy, RecoveryKit, EVENT_SCHEMA_VERSION, MAX_LOGICAL_CLOCK,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};

/// Stable C ABI entry point used by the Windows C# shell and the future Apple
/// XCFramework wrapper. The richer typed API remains the Rust/UniFFI surface;
/// this JSON boundary keeps the first native integrations versionable.
#[no_mangle]
pub extern "C" fn dayflow_core_version() -> *mut c_char {
    into_c_string(env!("CARGO_PKG_VERSION"))
}

/// Apply the same privacy decision used by the UniFFI clients before a native
/// capture adapter processes a frame. A false result is fail-closed.
#[no_mangle]
pub extern "C" fn dayflow_core_capture_allowed(
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

/// Calculate the canonical Dayflow logical day for native clients that use the
/// C ABI. The result is `{ "day": "YYYY-MM-DD" }` or `{ "error": "..." }`.
#[no_mangle]
pub extern "C" fn dayflow_core_logical_day_key(
    timestamp_unix: i64,
    timezone_offset_minutes: i32,
    boundary_hour: u8,
) -> *mut c_char {
    match logical_day_key(timestamp_unix, timezone_offset_minutes, boundary_hour) {
        Ok(day) => into_c_string(&serde_json::json!({ "day": day }).to_string()),
        Err(error) => into_c_string(&serde_json::json!({ "error": error.to_string() }).to_string()),
    }
}

/// Evaluate a complete capture context against a serialized privacy policy.
/// The returned JSON is `{ "allowed": bool, "reason": string }` or an
/// `{ "error": string }` object. The returned pointer must be freed with
/// `dayflow_core_free_string`.
///
/// # Safety
///
/// Both arguments must be valid, NUL-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_capture_decision_json(
    context_json: *const c_char,
    policy_json: *const c_char,
) -> *mut c_char {
    let result = (|| {
        if context_json.is_null() || policy_json.is_null() {
            return Err("capture context and privacy policy are required".to_owned());
        }
        let context_json = CStr::from_ptr(context_json)
            .to_str()
            .map_err(|_| "capture context JSON is not UTF-8".to_owned())?;
        let policy_json = CStr::from_ptr(policy_json)
            .to_str()
            .map_err(|_| "privacy policy JSON is not UTF-8".to_owned())?;
        let context: crate::CaptureContext = serde_json::from_str(context_json)
            .map_err(|error| format!("invalid capture context JSON: {error}"))?;
        let policy: crate::PrivacyPolicy = serde_json::from_str(policy_json)
            .map_err(|error| format!("invalid privacy policy JSON: {error}"))?;
        let decision = policy.decide(&context);
        serde_json::to_string(&serde_json::json!({
            "allowed": matches!(decision, crate::CaptureDecision::Capture),
            "reason": decision.reason(),
        }))
        .map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Generate a fresh account root key in the shared core. Native clients place
/// the returned bytes directly into their platform secure store.
#[no_mangle]
pub extern "C" fn dayflow_core_generate_account_root_key_json() -> *mut c_char {
    let root_key = AccountRootKey::generate();
    into_c_string(&serde_json::json!({ "root_key": B64.encode(root_key.as_bytes()) }).to_string())
}

/// Project encrypted event envelopes locally. The server cannot call this
/// function because it never receives the root key. On failure the returned JSON
/// has the shape `{ "error": "..." }` so callers can surface a useful native
/// diagnostic without an exception ABI.
///
/// # Safety
///
/// `envelopes_json` must be a valid, NUL-terminated UTF-8 C string. `root_key`
/// must point to at least `root_key_len` readable bytes, and `root_key_len` must
/// be exactly 32. The returned pointer must be released with
/// `dayflow_core_free_string`.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_project_json(
    envelopes_json: *const c_char,
    root_key: *const u8,
    root_key_len: usize,
) -> *mut c_char {
    let result = (|| {
        if envelopes_json.is_null() || root_key.is_null() || root_key_len != 32 {
            return Err("invalid null pointer or root-key length".to_owned());
        }
        let input = CStr::from_ptr(envelopes_json)
            .to_str()
            .map_err(|_| "envelopes JSON is not UTF-8".to_owned())?;
        let bytes = std::slice::from_raw_parts(root_key, root_key_len);
        let root_key: [u8; 32] = bytes
            .try_into()
            .map_err(|_| "root key must contain 32 bytes".to_owned())?;
        let envelopes: Vec<EventEnvelope> = serde_json::from_str(input)
            .map_err(|error| format!("invalid envelope JSON: {error}"))?;
        let mut log = EventLog::new("ffi", AccountRootKey::from_bytes(root_key));
        for envelope in envelopes {
            log.ingest(envelope)
                .map_err(|error| format!("invalid envelope: {error}"))?;
        }
        serde_json::to_string(&log.project().map_err(|error| error.to_string())?)
            .map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Project envelopes with all historical account keys currently available on
/// the device. `key_ring_json` is a native-only JSON document of the form
/// `{ "active_key_version": 2, "keys": { "1": "…", "2": "…" } }`.
/// The relay never receives this document.
///
/// # Safety
///
/// Both arguments must be valid, NUL-terminated UTF-8 C strings. The returned
/// pointer must be released with `dayflow_core_free_string`.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_project_keyring_json(
    envelopes_json: *const c_char,
    key_ring_json: *const c_char,
) -> *mut c_char {
    let result = (|| {
        if envelopes_json.is_null() || key_ring_json.is_null() {
            return Err("envelopes and key-ring JSON are required".to_owned());
        }
        let envelopes_text = CStr::from_ptr(envelopes_json)
            .to_str()
            .map_err(|_| "envelopes JSON is not UTF-8".to_owned())?;
        let key_ring_text = CStr::from_ptr(key_ring_json)
            .to_str()
            .map_err(|_| "key-ring JSON is not UTF-8".to_owned())?;
        let envelopes: Vec<EventEnvelope> = serde_json::from_str(envelopes_text)
            .map_err(|error| format!("invalid envelope JSON: {error}"))?;
        let key_ring = parse_key_ring_json(key_ring_text)?;
        let mut log = EventLog::with_key_ring("ffi", key_ring);
        for envelope in envelopes {
            log.ingest(envelope)
                .map_err(|error| format!("invalid envelope: {error}"))?;
        }
        serde_json::to_string(&log.project().map_err(|error| error.to_string())?)
            .map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Re-encrypt an opaque envelope stream when a local workspace is linked to a
/// different account key-ring. Event identity and logical clocks are retained.
/// Both key-ring documents stay inside the native process.
///
/// # Safety
///
/// All three arguments must be valid, NUL-terminated UTF-8 C strings. The
/// returned pointer must be released with `dayflow_core_free_string`.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_rekey_envelopes_json(
    envelopes_json: *const c_char,
    source_key_ring_json: *const c_char,
    destination_key_ring_json: *const c_char,
) -> *mut c_char {
    let result = (|| {
        if envelopes_json.is_null()
            || source_key_ring_json.is_null()
            || destination_key_ring_json.is_null()
        {
            return Err("envelopes and both key-rings are required".to_owned());
        }
        let envelopes_text = CStr::from_ptr(envelopes_json)
            .to_str()
            .map_err(|_| "envelopes JSON is not UTF-8".to_owned())?;
        let source_text = CStr::from_ptr(source_key_ring_json)
            .to_str()
            .map_err(|_| "source key-ring JSON is not UTF-8".to_owned())?;
        let destination_text = CStr::from_ptr(destination_key_ring_json)
            .to_str()
            .map_err(|_| "destination key-ring JSON is not UTF-8".to_owned())?;
        let envelopes: Vec<EventEnvelope> = serde_json::from_str(envelopes_text)
            .map_err(|error| format!("invalid envelope JSON: {error}"))?;
        let source_key_ring = parse_key_ring_json(source_text)?;
        let destination_key_ring = parse_key_ring_json(destination_text)?;
        let rekeyed = envelopes
            .iter()
            .map(|envelope| rekey_envelope(envelope, &source_key_ring, &destination_key_ring))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&rekeyed).map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Seal one local event payload into the relay envelope format. This is the
/// native-client write boundary: callers provide a stable event ID and logical
/// clock, while the Rust core owns authenticated encryption and wire encoding.
/// The returned JSON is an `EventEnvelope` and must be released with
/// `dayflow_core_free_string`.
///
/// # Safety
///
/// All string pointers must be valid, NUL-terminated UTF-8 C strings. `root_key`
/// must point to exactly 32 readable bytes.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_seal_json(
    payload_json: *const c_char,
    event_id: *const c_char,
    device_id: *const c_char,
    logical_clock: u64,
    root_key: *const u8,
    root_key_len: usize,
) -> *mut c_char {
    let result = (|| {
        if payload_json.is_null()
            || event_id.is_null()
            || device_id.is_null()
            || root_key.is_null()
            || root_key_len != 32
        {
            return Err("invalid null pointer or root-key length".to_owned());
        }

        let payload_json = CStr::from_ptr(payload_json)
            .to_str()
            .map_err(|_| "payload JSON is not UTF-8".to_owned())?;
        let event_id = CStr::from_ptr(event_id)
            .to_str()
            .map_err(|_| "event ID is not UTF-8".to_owned())?;
        let device_id = CStr::from_ptr(device_id)
            .to_str()
            .map_err(|_| "device ID is not UTF-8".to_owned())?;
        if event_id.trim().is_empty()
            || device_id.trim().is_empty()
            || logical_clock == 0
            || logical_clock > MAX_LOGICAL_CLOCK
        {
            return Err("event ID, device ID, and logical clock are required".to_owned());
        }

        let payload: EventPayload = serde_json::from_str(payload_json)
            .map_err(|error| format!("invalid event payload JSON: {error}"))?;
        payload.validate().map_err(|error| error.to_string())?;
        let bytes = serde_json::to_vec(&payload).map_err(|error| error.to_string())?;
        let root_key_bytes = std::slice::from_raw_parts(root_key, root_key_len);
        let root_key: [u8; 32] = root_key_bytes
            .try_into()
            .map_err(|_| "root key must contain 32 bytes".to_owned())?;
        let (nonce, ciphertext) = seal_event(
            &AccountRootKey::from_bytes(root_key),
            event_id,
            device_id,
            logical_clock,
            EVENT_SCHEMA_VERSION,
            1,
            &bytes,
        )
        .map_err(|error| error.to_string())?;

        serde_json::to_string(&EventEnvelope {
            event_id: event_id.to_owned(),
            device_id: device_id.to_owned(),
            logical_clock,
            schema_version: EVENT_SCHEMA_VERSION,
            key_version: 1,
            nonce,
            ciphertext,
        })
        .map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Version-aware event sealing. The original `dayflow_core_seal_json` remains
/// available for v1 clients and deliberately seals with key version 1.
///
/// # Safety
///
/// The string pointers must be valid, NUL-terminated UTF-8 C strings. `root_key`
/// must point to exactly 32 readable bytes. The returned pointer must be
/// released with `dayflow_core_free_string`.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_seal_key_version_json(
    payload_json: *const c_char,
    event_id: *const c_char,
    device_id: *const c_char,
    logical_clock: u64,
    key_version: u32,
    root_key: *const u8,
    root_key_len: usize,
) -> *mut c_char {
    let result = (|| {
        if payload_json.is_null()
            || event_id.is_null()
            || device_id.is_null()
            || root_key.is_null()
            || root_key_len != 32
        {
            return Err("invalid null pointer or root-key length".to_owned());
        }
        if key_version == 0 {
            return Err("key version must be greater than zero".to_owned());
        }
        let payload_json = CStr::from_ptr(payload_json)
            .to_str()
            .map_err(|_| "payload JSON is not UTF-8".to_owned())?;
        let event_id = CStr::from_ptr(event_id)
            .to_str()
            .map_err(|_| "event ID is not UTF-8".to_owned())?;
        let device_id = CStr::from_ptr(device_id)
            .to_str()
            .map_err(|_| "device ID is not UTF-8".to_owned())?;
        if event_id.trim().is_empty()
            || device_id.trim().is_empty()
            || logical_clock == 0
            || logical_clock > MAX_LOGICAL_CLOCK
        {
            return Err("event ID, device ID, and logical clock are required".to_owned());
        }
        let payload: EventPayload = serde_json::from_str(payload_json)
            .map_err(|error| format!("invalid event payload JSON: {error}"))?;
        payload.validate().map_err(|error| error.to_string())?;
        let bytes = serde_json::to_vec(&payload).map_err(|error| error.to_string())?;
        let root_key_bytes = std::slice::from_raw_parts(root_key, root_key_len);
        let root_key: [u8; 32] = root_key_bytes
            .try_into()
            .map_err(|_| "root key must contain 32 bytes".to_owned())?;
        let (nonce, ciphertext) = seal_event(
            &AccountRootKey::from_bytes(root_key),
            event_id,
            device_id,
            logical_clock,
            EVENT_SCHEMA_VERSION,
            key_version,
            &bytes,
        )
        .map_err(|error| error.to_string())?;
        serde_json::to_string(&EventEnvelope {
            event_id: event_id.to_owned(),
            device_id: device_id.to_owned(),
            logical_clock,
            schema_version: EVENT_SCHEMA_VERSION,
            key_version,
            nonce,
            ciphertext,
        })
        .map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Wrap the account root key for an approved device. The returned JSON is the
/// opaque wrapped-key document sent to the relay by an already trusted device.
///
/// # Safety
///
/// `recipient_device_id` must be a valid NUL-terminated UTF-8 C string.
/// `root_key` and `recipient_public_key` must each point to exactly 32 readable
/// bytes. The returned pointer must be released with
/// `dayflow_core_free_string`.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_wrap_account_key_json(
    root_key: *const u8,
    root_key_len: usize,
    recipient_device_id: *const c_char,
    recipient_public_key: *const u8,
    recipient_public_key_len: usize,
) -> *mut c_char {
    let result = (|| {
        if root_key.is_null()
            || recipient_device_id.is_null()
            || recipient_public_key.is_null()
            || root_key_len != 32
            || recipient_public_key_len != 32
        {
            return Err("root key and recipient public key must contain 32 bytes".to_owned());
        }
        let root_key_bytes = std::slice::from_raw_parts(root_key, root_key_len);
        let root_key: [u8; 32] = root_key_bytes
            .try_into()
            .map_err(|_| "root key must contain 32 bytes".to_owned())?;
        let recipient_device_id = CStr::from_ptr(recipient_device_id)
            .to_str()
            .map_err(|_| "recipient device ID is not UTF-8".to_owned())?;
        if recipient_device_id.trim().is_empty() {
            return Err("recipient device ID is required".to_owned());
        }
        let recipient_public_key_bytes =
            std::slice::from_raw_parts(recipient_public_key, recipient_public_key_len);
        let recipient_public_key: [u8; 32] = recipient_public_key_bytes
            .try_into()
            .map_err(|_| "recipient public key must contain 32 bytes".to_owned())?;
        let wrapped = wrap_account_key(
            &AccountRootKey::from_bytes(root_key),
            recipient_device_id,
            &recipient_public_key,
        )
        .map_err(|error| error.to_string())?;
        serde_json::to_string(&wrapped).map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Wrap a selected historical/current account key for a peer device. The
/// `key_version` is authenticated inside the wrapped document as well as
/// carried in the relay record.
///
/// # Safety
///
/// `root_key` and `recipient_public_key` must each point to exactly 32 readable
/// bytes. `recipient_device_id` must be a valid, NUL-terminated UTF-8 C string.
/// The returned pointer must be released with `dayflow_core_free_string`.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_wrap_account_key_versioned_json(
    root_key: *const u8,
    root_key_len: usize,
    key_version: u32,
    recipient_device_id: *const c_char,
    recipient_public_key: *const u8,
    recipient_public_key_len: usize,
) -> *mut c_char {
    let result = (|| {
        if root_key.is_null()
            || recipient_device_id.is_null()
            || recipient_public_key.is_null()
            || root_key_len != 32
            || recipient_public_key_len != 32
        {
            return Err("root key and recipient public key must contain 32 bytes".to_owned());
        }
        let root_key_bytes = std::slice::from_raw_parts(root_key, root_key_len);
        let root_key: [u8; 32] = root_key_bytes
            .try_into()
            .map_err(|_| "root key must contain 32 bytes".to_owned())?;
        let recipient_device_id = CStr::from_ptr(recipient_device_id)
            .to_str()
            .map_err(|_| "recipient device ID is not UTF-8".to_owned())?;
        if recipient_device_id.trim().is_empty() || key_version == 0 {
            return Err("recipient device ID and key version are required".to_owned());
        }
        let recipient_public_key_bytes =
            std::slice::from_raw_parts(recipient_public_key, recipient_public_key_len);
        let recipient_public_key: [u8; 32] = recipient_public_key_bytes
            .try_into()
            .map_err(|_| "recipient public key must contain 32 bytes".to_owned())?;
        let wrapped = wrap_account_key_versioned(
            &AccountRootKey::from_bytes(root_key),
            key_version,
            recipient_device_id,
            &recipient_public_key,
        )
        .map_err(|error| error.to_string())?;
        serde_json::to_string(&wrapped).map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Unwrap an account root key delivered to this device by an approved peer.
/// The returned JSON contains base64 key bytes for placement in the platform
/// secure store; the private key is never serialized by this function.
///
/// # Safety
///
/// `wrapped_key_json` must be a valid NUL-terminated UTF-8 C string and
/// `private_key` must point to exactly 32 readable bytes. The returned pointer
/// must be released with `dayflow_core_free_string`.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_unwrap_account_key_json(
    wrapped_key_json: *const c_char,
    private_key: *const u8,
    private_key_len: usize,
) -> *mut c_char {
    let result = (|| {
        if wrapped_key_json.is_null() || private_key.is_null() || private_key_len != 32 {
            return Err("wrapped key and private key are required".to_owned());
        }
        let wrapped_key_json = CStr::from_ptr(wrapped_key_json)
            .to_str()
            .map_err(|_| "wrapped key is not UTF-8".to_owned())?;
        let wrapped = serde_json::from_str(wrapped_key_json)
            .map_err(|error| format!("invalid wrapped key JSON: {error}"))?;
        let private_key_bytes = std::slice::from_raw_parts(private_key, private_key_len);
        let private_key: [u8; 32] = private_key_bytes
            .try_into()
            .map_err(|_| "private key must contain 32 bytes".to_owned())?;
        let root_key =
            unwrap_account_key(&wrapped, &DeviceKeyPair::from_private_bytes(private_key))
                .map_err(|error| error.to_string())?;
        // Keep the original C ABI response shape stable. Version-aware native
        // clients read `key_version` from the authenticated wrapped document;
        // older clients only need the root key field.
        Ok(serde_json::json!({ "root_key": B64.encode(root_key.as_bytes()) }).to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Export a password-protected recovery kit as JSON. The passphrase is used
/// only for this call and is never placed in the returned document.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_export_recovery_kit_json(
    root_key: *const u8,
    root_key_len: usize,
    passphrase: *const c_char,
) -> *mut c_char {
    let result = (|| {
        if root_key.is_null() || root_key_len != 32 || passphrase.is_null() {
            return Err("invalid null pointer, passphrase, or root-key length".to_owned());
        }
        let root_key_bytes = std::slice::from_raw_parts(root_key, root_key_len);
        let root_key: [u8; 32] = root_key_bytes
            .try_into()
            .map_err(|_| "root key must contain 32 bytes".to_owned())?;
        let passphrase = CStr::from_ptr(passphrase)
            .to_str()
            .map_err(|_| "passphrase is not UTF-8".to_owned())?;
        let kit = export_recovery_kit(&AccountRootKey::from_bytes(root_key), passphrase)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&kit).map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Restore a root key from a recovery-kit JSON document. The return value is a
/// small JSON object containing base64 key bytes so the caller can place them
/// directly in its platform secure store. The passphrase never leaves this
/// synchronous call.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_restore_recovery_key_json(
    kit_json: *const c_char,
    passphrase: *const c_char,
) -> *mut c_char {
    let result = (|| {
        if kit_json.is_null() || passphrase.is_null() {
            return Err("recovery kit and passphrase are required".to_owned());
        }
        let kit_json = CStr::from_ptr(kit_json)
            .to_str()
            .map_err(|_| "recovery kit is not UTF-8".to_owned())?;
        let passphrase = CStr::from_ptr(passphrase)
            .to_str()
            .map_err(|_| "passphrase is not UTF-8".to_owned())?;
        let kit: RecoveryKit = serde_json::from_str(kit_json)
            .map_err(|error| format!("invalid recovery kit JSON: {error}"))?;
        let root_key = restore_recovery_kit(&kit, passphrase).map_err(|error| error.to_string())?;
        Ok(serde_json::json!({ "root_key": B64.encode(root_key.as_bytes()) }).to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Export a password-protected recovery kit containing every key version in a
/// native key-ring JSON document. The key-ring and passphrase are used only by
/// this call and never enter the relay request path.
///
/// # Safety
///
/// Both arguments must be valid, NUL-terminated UTF-8 C strings. The returned
/// pointer must be released with `dayflow_core_free_string`.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_export_recovery_kit_keyring_json(
    key_ring_json: *const c_char,
    passphrase: *const c_char,
) -> *mut c_char {
    let result = (|| {
        if key_ring_json.is_null() || passphrase.is_null() {
            return Err("key-ring JSON and passphrase are required".to_owned());
        }
        let key_ring_json = CStr::from_ptr(key_ring_json)
            .to_str()
            .map_err(|_| "key-ring JSON is not UTF-8".to_owned())?;
        let passphrase = CStr::from_ptr(passphrase)
            .to_str()
            .map_err(|_| "passphrase is not UTF-8".to_owned())?;
        let key_ring = parse_key_ring_json(key_ring_json)?;
        let kit = export_recovery_kit_for_keyring(&key_ring, passphrase)
            .map_err(|error| error.to_string())?;
        serde_json::to_string(&kit).map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Restore a complete native key-ring JSON document from an encrypted
/// recovery kit. The returned key bytes must be placed in the platform secure
/// store immediately and must not be logged.
///
/// # Safety
///
/// Both arguments must be valid, NUL-terminated UTF-8 C strings. The returned
/// pointer must be released with `dayflow_core_free_string`.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_restore_recovery_keyring_json(
    kit_json: *const c_char,
    passphrase: *const c_char,
) -> *mut c_char {
    let result = (|| {
        if kit_json.is_null() || passphrase.is_null() {
            return Err("recovery kit and passphrase are required".to_owned());
        }
        let kit_json = CStr::from_ptr(kit_json)
            .to_str()
            .map_err(|_| "recovery kit is not UTF-8".to_owned())?;
        let passphrase = CStr::from_ptr(passphrase)
            .to_str()
            .map_err(|_| "passphrase is not UTF-8".to_owned())?;
        let kit: RecoveryKit = serde_json::from_str(kit_json)
            .map_err(|error| format!("invalid recovery kit JSON: {error}"))?;
        let key_ring =
            restore_recovery_key_set(&kit, passphrase).map_err(|error| error.to_string())?;
        let keys = key_ring
            .key_material()
            .map(|(version, key)| (version.to_string(), B64.encode(key.as_bytes())))
            .collect::<BTreeMap<_, _>>();
        serde_json::to_string(&KeyRingWire {
            active_key_version: key_ring.active_version(),
            keys,
        })
        .map_err(|error| error.to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Generate a device key pair for platform secure-store custody. The private
/// key is returned only to the caller so it can be stored in Keychain,
/// Android Keystore, or the Windows credential boundary; it is never sent to
/// the relay.
#[no_mangle]
pub extern "C" fn dayflow_core_generate_device_keypair_json() -> *mut c_char {
    let pair = DeviceKeyPair::generate();
    into_c_string(
        &serde_json::json!({
            "private_key": B64.encode(pair.private_bytes()),
            "public_key": B64.encode(pair.public_key()),
        })
        .to_string(),
    )
}

/// Generate the separate Ed25519 signing key pair used for authenticated
/// relay requests. The private key is returned only so the native client can
/// place it in its platform secure store; it must never be sent to the relay.
#[no_mangle]
pub extern "C" fn dayflow_core_generate_device_signing_keypair_json() -> *mut c_char {
    let pair = DeviceSigningKeyPair::generate();
    into_c_string(
        &serde_json::json!({
            "private_key": B64.encode(pair.private_bytes()),
            "public_key": B64.encode(pair.public_key()),
        })
        .to_string(),
    )
}

/// Sign the canonical request string used by the opaque relay. The signature
/// is returned as base64 JSON so C ABI consumers do not need a second binary
/// allocation convention.
///
/// # Safety
///
/// `message` must be a valid NUL-terminated UTF-8 C string and `private_key`
/// must point to exactly 32 readable bytes.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_sign_request_json(
    message: *const c_char,
    private_key: *const u8,
    private_key_len: usize,
) -> *mut c_char {
    let result = (|| {
        if message.is_null() || private_key.is_null() || private_key_len != 32 {
            return Err("request message and a 32-byte signing key are required".to_owned());
        }
        let message = CStr::from_ptr(message)
            .to_str()
            .map_err(|_| "request message is not UTF-8".to_owned())?;
        if message.is_empty() {
            return Err("request message is required".to_owned());
        }
        let private_key_bytes = std::slice::from_raw_parts(private_key, private_key_len);
        let private_key: [u8; 32] = private_key_bytes
            .try_into()
            .map_err(|_| "signing key must contain 32 bytes".to_owned())?;
        let signature =
            DeviceSigningKeyPair::from_private_bytes(private_key).sign(message.as_bytes());
        Ok(serde_json::json!({ "signature": B64.encode(signature) }).to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Build the canonical request string used by the opaque relay. The result is
/// `{ "request": "..." }` or `{ "error": "..." }` and must be freed with
/// `dayflow_core_free_string`.
///
/// # Safety
///
/// The string arguments must be valid NUL-terminated UTF-8 C strings. `body`
/// must point to `body_len` readable bytes, or be null when `body_len` is zero.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_canonical_device_request_json(
    method: *const c_char,
    path_with_query: *const c_char,
    body: *const u8,
    body_len: usize,
    timestamp: i64,
    nonce: *const c_char,
    device_id: *const c_char,
) -> *mut c_char {
    let result = (|| {
        if method.is_null()
            || path_with_query.is_null()
            || nonce.is_null()
            || device_id.is_null()
            || (body_len > 0 && body.is_null())
        {
            return Err("request components are required".to_owned());
        }
        let method = CStr::from_ptr(method)
            .to_str()
            .map_err(|_| "request method is not UTF-8".to_owned())?;
        let path_with_query = CStr::from_ptr(path_with_query)
            .to_str()
            .map_err(|_| "request path is not UTF-8".to_owned())?;
        let nonce = CStr::from_ptr(nonce)
            .to_str()
            .map_err(|_| "request nonce is not UTF-8".to_owned())?;
        let device_id = CStr::from_ptr(device_id)
            .to_str()
            .map_err(|_| "request device ID is not UTF-8".to_owned())?;
        let body = if body_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(body, body_len)
        };
        let request =
            canonical_device_request(method, path_with_query, body, timestamp, nonce, device_id)
                .map_err(|error| error.to_string())?;
        Ok(serde_json::json!({ "request": request }).to_string())
    })();

    match result {
        Ok(json) => into_c_string(&json),
        Err(error) => into_c_string(&format!("{{\"error\":{}}}", serde_json::json!(error))),
    }
}

/// Free strings returned from the C ABI with the same allocator that created
/// them. Callers must not use `free()` from a different runtime.
///
/// # Safety
///
/// `value` must be either null or a pointer previously returned by one of this
/// crate's string-returning C ABI functions, and it must not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn dayflow_core_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

fn into_c_string(value: &str) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| {
            CString::new("{\"error\":\"interior NUL\"}").expect("literal has no NUL")
        })
        .into_raw()
}

#[derive(serde::Deserialize, serde::Serialize)]
struct KeyRingWire {
    active_key_version: u32,
    keys: BTreeMap<String, String>,
}

fn parse_key_ring_json(value: &str) -> Result<AccountKeyRing, String> {
    let wire: KeyRingWire =
        serde_json::from_str(value).map_err(|error| format!("invalid key-ring JSON: {error}"))?;
    let keys = wire
        .keys
        .into_iter()
        .map(|(version, encoded)| {
            let version = version
                .parse::<u32>()
                .map_err(|_| "key-ring version is not an integer".to_owned())?;
            let bytes: [u8; 32] = B64
                .decode(encoded)
                .map_err(|_| "key-ring key is not valid base64".to_owned())?
                .try_into()
                .map_err(|_| "key-ring keys must contain 32 bytes".to_owned())?;
            Ok((version, AccountRootKey::from_bytes(bytes)))
        })
        .collect::<Result<BTreeMap<_, _>, String>>()?;
    AccountKeyRing::from_keys(keys, wire.active_key_version).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn c_abi_seals_and_projects_an_event() {
        let payload = CString::new(
            r#"{"kind":"JournalUpsert","value":{"id":"journal-1","day":"2026-08-01","body":"hello"}}"#,
        )
        .unwrap();
        let event_id = CString::new("event-1").unwrap();
        let device_id = CString::new("mac-1").unwrap();
        let root = [7_u8; 32];
        let envelope_json = unsafe {
            dayflow_core_seal_json(
                payload.as_ptr(),
                event_id.as_ptr(),
                device_id.as_ptr(),
                1,
                root.as_ptr(),
                root.len(),
            )
        };
        assert!(!envelope_json.is_null());
        let envelope_text = unsafe { CStr::from_ptr(envelope_json).to_owned() };
        unsafe { dayflow_core_free_string(envelope_json) };

        let envelopes = CString::new(format!("[{}]", envelope_text.to_str().unwrap())).unwrap();
        let projection_json =
            unsafe { dayflow_core_project_json(envelopes.as_ptr(), root.as_ptr(), root.len()) };
        assert!(!projection_json.is_null());
        let projection_text = unsafe {
            CStr::from_ptr(projection_json)
                .to_string_lossy()
                .into_owned()
        };
        unsafe { dayflow_core_free_string(projection_json) };
        assert!(projection_text.contains("journal-1"));
    }

    #[test]
    fn c_abi_rejects_secret_shared_setting_before_sealing() {
        let payload = CString::new(
            r#"{"kind":"SettingUpsert","value":{"key":"dayflow.provider.api_key","value":"secret"}}"#,
        )
        .unwrap();
        let event_id = CString::new("event-setting-1").unwrap();
        let device_id = CString::new("mac-1").unwrap();
        let root = [7_u8; 32];
        let envelope_json = unsafe {
            dayflow_core_seal_json(
                payload.as_ptr(),
                event_id.as_ptr(),
                device_id.as_ptr(),
                1,
                root.as_ptr(),
                root.len(),
            )
        };
        let result = unsafe { CStr::from_ptr(envelope_json).to_string_lossy().into_owned() };
        unsafe { dayflow_core_free_string(envelope_json) };
        assert!(result.contains("shared setting key is not allowed"));
        assert!(!result.contains("ciphertext"));
    }

    #[test]
    fn c_abi_capture_decision_accepts_application_and_window_policy() {
        let context = CString::new(
            r#"{"permission_granted":true,"user_paused":false,"device_locked":false,"sleeping":false,"private_context":false,"drm_content":false,"application_id":"com.example.bank","window_title":"Password reset"}"#,
        )
        .unwrap();
        let policy = CString::new(
            r#"{"ignore_private_context":true,"pause_on_drm":true,"blocked_application_ids":["com.example.bank"],"blocked_window_title_fragments":["password"]}"#,
        )
        .unwrap();
        let result =
            unsafe { dayflow_core_capture_decision_json(context.as_ptr(), policy.as_ptr()) };
        let text = unsafe { CStr::from_ptr(result).to_string_lossy().into_owned() };
        unsafe { dayflow_core_free_string(result) };
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["allowed"], false);
        assert_eq!(value["reason"], "blocked_application");
    }

    #[test]
    fn c_abi_logical_day_key_uses_the_four_am_boundary() {
        let before = dayflow_core_logical_day_key(14_399, 0, 4);
        let at_boundary = dayflow_core_logical_day_key(14_400, 0, 4);
        let before_json = unsafe { CStr::from_ptr(before).to_string_lossy().into_owned() };
        let boundary_json = unsafe { CStr::from_ptr(at_boundary).to_string_lossy().into_owned() };
        unsafe {
            dayflow_core_free_string(before);
            dayflow_core_free_string(at_boundary);
        }
        assert_ne!(before_json, boundary_json);
    }

    #[test]
    fn c_abi_recovery_and_device_material_are_json_contracts() {
        let root = [9_u8; 32];
        let passphrase = CString::new("correct horse battery staple").unwrap();
        let kit_json = unsafe {
            dayflow_core_export_recovery_kit_json(root.as_ptr(), root.len(), passphrase.as_ptr())
        };
        let kit_text = unsafe { CStr::from_ptr(kit_json).to_owned() };
        unsafe { dayflow_core_free_string(kit_json) };
        assert!(kit_text.to_str().unwrap().contains("argon2id"));

        let restored = unsafe {
            dayflow_core_restore_recovery_key_json(
                CString::new(kit_text.to_str().unwrap()).unwrap().as_ptr(),
                passphrase.as_ptr(),
            )
        };
        let restored_text = unsafe { CStr::from_ptr(restored).to_string_lossy().into_owned() };
        unsafe { dayflow_core_free_string(restored) };
        assert!(restored_text.contains("root_key"));

        let device = dayflow_core_generate_device_keypair_json();
        let device_text = unsafe { CStr::from_ptr(device).to_string_lossy().into_owned() };
        unsafe { dayflow_core_free_string(device) };
        assert!(device_text.contains("private_key"));
        assert!(device_text.contains("public_key"));
    }

    #[test]
    fn c_abi_keyring_recovery_round_trips_all_versions() {
        let key_ring = serde_json::json!({
            "active_key_version": 2,
            "keys": {
                "1": B64.encode([9_u8; 32]),
                "2": B64.encode([8_u8; 32])
            }
        })
        .to_string();
        let key_ring_json = CString::new(key_ring).unwrap();
        let passphrase = CString::new("correct horse battery staple").unwrap();
        let kit = unsafe {
            dayflow_core_export_recovery_kit_keyring_json(
                key_ring_json.as_ptr(),
                passphrase.as_ptr(),
            )
        };
        let kit_text = unsafe { CStr::from_ptr(kit).to_string_lossy().into_owned() };
        unsafe { dayflow_core_free_string(kit) };

        let kit_json = CString::new(kit_text).unwrap();
        let restored = unsafe {
            dayflow_core_restore_recovery_keyring_json(kit_json.as_ptr(), passphrase.as_ptr())
        };
        let restored_text = unsafe { CStr::from_ptr(restored).to_string_lossy().into_owned() };
        unsafe { dayflow_core_free_string(restored) };
        let restored: serde_json::Value = serde_json::from_str(&restored_text).unwrap();
        assert_eq!(restored["active_key_version"], 2);
        assert_eq!(restored["keys"]["1"], B64.encode([9_u8; 32]));
        assert_eq!(restored["keys"]["2"], B64.encode([8_u8; 32]));
    }

    #[test]
    fn c_abi_device_key_wrap_round_trips() {
        let root = [3_u8; 32];
        let device = DeviceKeyPair::generate();
        let recipient = CString::new("phone-1").unwrap();
        let wrapped = unsafe {
            dayflow_core_wrap_account_key_json(
                root.as_ptr(),
                root.len(),
                recipient.as_ptr(),
                device.public_key().as_ptr(),
                32,
            )
        };
        let wrapped_text = unsafe { CStr::from_ptr(wrapped).to_string_lossy().into_owned() };
        unsafe { dayflow_core_free_string(wrapped) };
        assert!(wrapped_text.contains("recipient_device_id"));

        let private = device.private_bytes().to_vec();
        let wrapped_json = CString::new(wrapped_text).unwrap();
        let restored = unsafe {
            dayflow_core_unwrap_account_key_json(
                wrapped_json.as_ptr(),
                private.as_ptr(),
                private.len(),
            )
        };
        let restored_text = unsafe { CStr::from_ptr(restored).to_string_lossy().into_owned() };
        unsafe { dayflow_core_free_string(restored) };
        assert_eq!(
            restored_text,
            serde_json::json!({ "root_key": B64.encode(root) }).to_string()
        );
    }

    #[test]
    fn c_abi_signing_key_pair_signs_a_request() {
        let pair = DeviceSigningKeyPair::generate();
        let message = CString::new("dayflow:v1:1:GET:/v1/sync/events:abc:mac-1").unwrap();
        let signed = unsafe {
            dayflow_core_sign_request_json(
                message.as_ptr(),
                pair.private_bytes().as_ptr(),
                pair.private_bytes().len(),
            )
        };
        let signed_text = unsafe { CStr::from_ptr(signed).to_string_lossy().into_owned() };
        unsafe { dayflow_core_free_string(signed) };
        let value: serde_json::Value = serde_json::from_str(&signed_text).unwrap();
        let signature = B64.decode(value["signature"].as_str().unwrap()).unwrap();
        let signature = ed25519_dalek::Signature::from_slice(&signature).unwrap();
        let public = ed25519_dalek::VerifyingKey::from_bytes(&pair.public_key()).unwrap();
        use ed25519_dalek::Verifier;
        public.verify(message.as_bytes(), &signature).unwrap();
    }

    #[test]
    fn c_abi_canonical_request_matches_the_wire_vector() {
        let method = CString::new("post").unwrap();
        let path = CString::new("/v1/sync/events?cursor=abc").unwrap();
        let nonce = CString::new("0123456789abcdef0123456789abcdef").unwrap();
        let device_id = CString::new("mac-device").unwrap();
        let body = br#"{"hello":"opaque"}"#;
        let result = unsafe {
            dayflow_core_canonical_device_request_json(
                method.as_ptr(),
                path.as_ptr(),
                body.as_ptr(),
                body.len(),
                1_723_456_789,
                nonce.as_ptr(),
                device_id.as_ptr(),
            )
        };
        let json = unsafe { CStr::from_ptr(result).to_string_lossy().into_owned() };
        unsafe { dayflow_core_free_string(result) };
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            value["request"],
            "dayflow:v1:1723456789:POST:/v1/sync/events?cursor=abc:b7e6d00fedcbdee445a53f6b804273eeb7a62879a6891f7bdc4f9b238675a4f4:0123456789abcdef0123456789abcdef:mac-device"
        );
    }
}
