use argon2::{Algorithm, Argon2, Params, Version};
use base64::{
    engine::general_purpose::{STANDARD as B64, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD},
    Engine,
};
use chacha20poly1305::{
    aead::{Aead, Payload},
    KeyInit, XChaCha20Poly1305, XNonce,
};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::BTreeMap;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::{CoreError, EVENT_SCHEMA_VERSION};

const ROOT_KEY_BYTES: usize = 32;
pub(crate) const EVENT_NONCE_BYTES: usize = 24;
pub(crate) const EVENT_AUTH_TAG_BYTES: usize = 16;

/// Accept the padded and unpadded standard/base64url spellings used by the
/// relay, while all newly sealed values continue to use padded standard
/// base64 from `B64`.
pub(crate) fn decode_base64(value: &str) -> Option<Vec<u8>> {
    [&B64, &STANDARD_NO_PAD, &URL_SAFE, &URL_SAFE_NO_PAD]
        .iter()
        .find_map(|engine| engine.decode(value).ok())
}
const RECOVERY_SALT_BYTES: usize = 16;
const RECOVERY_KEY_BYTES: usize = 32;

/// The account key never leaves the device in plaintext. It is wrapped for a
/// device or encrypted into a user-held recovery kit before it can cross a trust
/// boundary.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct AccountRootKey([u8; ROOT_KEY_BYTES]);

impl AccountRootKey {
    pub fn generate() -> Self {
        let mut bytes = [0u8; ROOT_KEY_BYTES];
        OsRng.fill_bytes(&mut bytes);
        Self(bytes)
    }

    pub fn from_bytes(bytes: [u8; ROOT_KEY_BYTES]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; ROOT_KEY_BYTES] {
        &self.0
    }
}

/// The locally available account keys, indexed by the envelope key version.
///
/// The relay only stores the version number and opaque ciphertext. Keeping the
/// key ring on the device lets a client replay old events after rotation while
/// sealing new events with the selected active version.
#[derive(Clone)]
pub struct AccountKeyRing {
    keys: BTreeMap<u32, AccountRootKey>,
    active_version: u32,
}

impl AccountKeyRing {
    pub fn new(root_key: AccountRootKey) -> Self {
        let mut keys = BTreeMap::new();
        keys.insert(1, root_key);
        Self {
            keys,
            active_version: 1,
        }
    }

    pub fn with_active_key(version: u32, root_key: AccountRootKey) -> Result<Self, CoreError> {
        if version == 0 {
            return Err(CoreError::InvalidKeyVersion(version));
        }
        let mut keys = BTreeMap::new();
        keys.insert(version, root_key);
        Ok(Self {
            keys,
            active_version: version,
        })
    }

    pub fn from_keys(
        keys: BTreeMap<u32, AccountRootKey>,
        active_version: u32,
    ) -> Result<Self, CoreError> {
        if active_version == 0 || keys.is_empty() || keys.contains_key(&0) {
            return Err(CoreError::InvalidKeyVersion(active_version));
        }
        if !keys.contains_key(&active_version) {
            return Err(CoreError::InvalidKeyVersion(active_version));
        }
        Ok(Self {
            keys,
            active_version,
        })
    }

    pub fn active_version(&self) -> u32 {
        self.active_version
    }

    pub fn active_key(&self) -> &AccountRootKey {
        // `active_version` is always inserted by the constructors and setter.
        self.keys
            .get(&self.active_version)
            .expect("account key ring active version must exist")
    }

    pub fn key(&self, version: u32) -> Result<&AccountRootKey, CoreError> {
        self.keys
            .get(&version)
            .ok_or(CoreError::InvalidKeyVersion(version))
    }

    pub fn insert(&mut self, version: u32, root_key: AccountRootKey) -> Result<(), CoreError> {
        if version == 0 {
            return Err(CoreError::InvalidKeyVersion(version));
        }
        if let Some(existing) = self.keys.get(&version) {
            if existing.as_bytes() == root_key.as_bytes() {
                return Ok(());
            }
            return Err(CoreError::ConflictingKeyVersion(version));
        }
        self.keys.insert(version, root_key);
        Ok(())
    }

    pub fn set_active_version(&mut self, version: u32) -> Result<(), CoreError> {
        self.key(version)?;
        self.active_version = version;
        Ok(())
    }

    /// Generate and activate the next key version. Historical keys remain in
    /// the ring until the caller deliberately removes them from secure storage.
    pub fn rotate(&mut self) -> Result<(u32, AccountRootKey), CoreError> {
        let version = self
            .keys
            .keys()
            .next_back()
            .copied()
            .and_then(|version| version.checked_add(1))
            .ok_or(CoreError::InvalidKey)?;
        let root_key = AccountRootKey::generate();
        self.keys.insert(version, root_key.clone());
        self.active_version = version;
        Ok((version, root_key))
    }

    pub fn versions(&self) -> impl Iterator<Item = u32> + '_ {
        self.keys.keys().copied()
    }

    pub fn key_material(&self) -> impl Iterator<Item = (u32, &AccountRootKey)> + '_ {
        self.keys.iter().map(|(version, key)| (*version, key))
    }
}

/// A device key pair used only to wrap the account root key for an approved peer.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct DeviceKeyPair {
    private_key: [u8; ROOT_KEY_BYTES],
}

impl DeviceKeyPair {
    pub fn generate() -> Self {
        let secret = StaticSecret::random_from_rng(OsRng);
        Self {
            private_key: secret.to_bytes(),
        }
    }

    pub fn public_key(&self) -> [u8; ROOT_KEY_BYTES] {
        PublicKey::from(&StaticSecret::from(self.private_key)).to_bytes()
    }

    pub fn from_private_bytes(bytes: [u8; ROOT_KEY_BYTES]) -> Self {
        Self { private_key: bytes }
    }

    pub fn private_bytes(&self) -> &[u8; ROOT_KEY_BYTES] {
        &self.private_key
    }
}

/// A device signing key pair used to prove control of a registered device to
/// the relay. It is intentionally separate from the X25519 wrapping key: the
/// latter only encrypts the account root key for a peer and must never be
/// reused as a signing key.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct DeviceSigningKeyPair {
    private_key: [u8; ROOT_KEY_BYTES],
}

impl DeviceSigningKeyPair {
    pub fn generate() -> Self {
        Self {
            private_key: SigningKey::generate(&mut OsRng).to_bytes(),
        }
    }

    pub fn from_private_bytes(bytes: [u8; ROOT_KEY_BYTES]) -> Self {
        Self { private_key: bytes }
    }

    pub fn private_bytes(&self) -> &[u8; ROOT_KEY_BYTES] {
        &self.private_key
    }

    pub fn public_key(&self) -> [u8; ROOT_KEY_BYTES] {
        VerifyingKey::from(&SigningKey::from_bytes(&self.private_key)).to_bytes()
    }

    pub fn sign(&self, message: &[u8]) -> [u8; 64] {
        SigningKey::from_bytes(&self.private_key)
            .sign(message)
            .to_bytes()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WrappedAccountKey {
    pub version: u16,
    #[serde(default = "default_key_version")]
    pub key_version: u32,
    pub recipient_device_id: String,
    pub ephemeral_public_key: String,
    pub nonce: String,
    pub ciphertext: String,
}

fn default_key_version() -> u32 {
    1
}

/// Password-protected recovery material. This structure is safe to copy to a
/// user-selected location, but the passphrase itself must never be persisted by
/// Dayflow.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RecoveryKit {
    pub version: u16,
    pub kdf: String,
    pub salt: String,
    pub nonce: String,
    pub ciphertext: String,
}

pub fn seal_event(
    root_key: &AccountRootKey,
    event_id: &str,
    device_id: &str,
    logical_clock: u64,
    schema_version: u16,
    key_version: u32,
    plaintext: &[u8],
) -> Result<(String, String), CoreError> {
    seal_event_with_key(
        root_key,
        event_id,
        device_id,
        logical_clock,
        schema_version,
        key_version,
        plaintext,
    )
}

pub fn seal_event_with_keyring(
    key_ring: &AccountKeyRing,
    event_id: &str,
    device_id: &str,
    logical_clock: u64,
    schema_version: u16,
    key_version: u32,
    plaintext: &[u8],
) -> Result<(String, String), CoreError> {
    seal_event_with_key(
        key_ring.key(key_version)?,
        event_id,
        device_id,
        logical_clock,
        schema_version,
        key_version,
        plaintext,
    )
}

pub fn seal_event_with_key(
    root_key: &AccountRootKey,
    event_id: &str,
    device_id: &str,
    logical_clock: u64,
    schema_version: u16,
    key_version: u32,
    plaintext: &[u8],
) -> Result<(String, String), CoreError> {
    if key_version == 0 {
        return Err(CoreError::InvalidKeyVersion(key_version));
    }
    let mut nonce = [0u8; EVENT_NONCE_BYTES];
    OsRng.fill_bytes(&mut nonce);
    seal_event_with_nonce(
        root_key,
        event_id,
        device_id,
        logical_clock,
        schema_version,
        key_version,
        nonce,
        plaintext,
    )
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn seal_event_with_nonce(
    root_key: &AccountRootKey,
    event_id: &str,
    device_id: &str,
    logical_clock: u64,
    schema_version: u16,
    key_version: u32,
    nonce: [u8; EVENT_NONCE_BYTES],
    plaintext: &[u8],
) -> Result<(String, String), CoreError> {
    if key_version == 0 {
        return Err(CoreError::InvalidKeyVersion(key_version));
    }
    let cipher =
        XChaCha20Poly1305::new_from_slice(root_key.as_bytes()).map_err(|_| CoreError::Crypto)?;
    let aad = event_aad(
        event_id,
        device_id,
        logical_clock,
        schema_version,
        key_version,
    );
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| CoreError::Crypto)?;
    Ok((B64.encode(nonce), B64.encode(ciphertext)))
}

#[allow(clippy::too_many_arguments)]
pub fn open_event(
    root_key: &AccountRootKey,
    event_id: &str,
    device_id: &str,
    logical_clock: u64,
    schema_version: u16,
    key_version: u32,
    nonce_b64: &str,
    ciphertext_b64: &str,
) -> Result<Vec<u8>, CoreError> {
    open_event_with_key(
        root_key,
        event_id,
        device_id,
        logical_clock,
        schema_version,
        key_version,
        nonce_b64,
        ciphertext_b64,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn open_event_with_keyring(
    key_ring: &AccountKeyRing,
    event_id: &str,
    device_id: &str,
    logical_clock: u64,
    schema_version: u16,
    key_version: u32,
    nonce_b64: &str,
    ciphertext_b64: &str,
) -> Result<Vec<u8>, CoreError> {
    open_event_with_key(
        key_ring.key(key_version)?,
        event_id,
        device_id,
        logical_clock,
        schema_version,
        key_version,
        nonce_b64,
        ciphertext_b64,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn open_event_with_key(
    root_key: &AccountRootKey,
    event_id: &str,
    device_id: &str,
    logical_clock: u64,
    schema_version: u16,
    key_version: u32,
    nonce_b64: &str,
    ciphertext_b64: &str,
) -> Result<Vec<u8>, CoreError> {
    if key_version == 0 {
        return Err(CoreError::InvalidKeyVersion(key_version));
    }
    let nonce = decode_base64(nonce_b64).ok_or(CoreError::Crypto)?;
    if nonce.len() != EVENT_NONCE_BYTES {
        return Err(CoreError::Crypto);
    }
    let ciphertext = decode_base64(ciphertext_b64).ok_or(CoreError::Crypto)?;
    let cipher =
        XChaCha20Poly1305::new_from_slice(root_key.as_bytes()).map_err(|_| CoreError::Crypto)?;
    let aad = event_aad(
        event_id,
        device_id,
        logical_clock,
        schema_version,
        key_version,
    );
    cipher
        .decrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: ciphertext.as_ref(),
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| CoreError::Crypto)
}

pub fn wrap_account_key(
    root_key: &AccountRootKey,
    recipient_device_id: &str,
    recipient_public_key: &[u8; ROOT_KEY_BYTES],
) -> Result<WrappedAccountKey, CoreError> {
    wrap_account_key_versioned(root_key, 1, recipient_device_id, recipient_public_key)
}

pub fn wrap_account_key_versioned(
    root_key: &AccountRootKey,
    key_version: u32,
    recipient_device_id: &str,
    recipient_public_key: &[u8; ROOT_KEY_BYTES],
) -> Result<WrappedAccountKey, CoreError> {
    if key_version == 0 {
        return Err(CoreError::InvalidKeyVersion(key_version));
    }
    let ephemeral_secret = StaticSecret::random_from_rng(OsRng);
    let ephemeral_public = PublicKey::from(&ephemeral_secret);
    let recipient = PublicKey::from(*recipient_public_key);
    let shared = ephemeral_secret.diffie_hellman(&recipient);
    let wrapping_key = derive_shared_key(shared.as_bytes())?;
    let cipher = XChaCha20Poly1305::new_from_slice(&wrapping_key).map_err(|_| CoreError::Crypto)?;

    let mut nonce = [0u8; EVENT_NONCE_BYTES];
    OsRng.fill_bytes(&mut nonce);
    let aad = account_key_aad(EVENT_SCHEMA_VERSION, key_version, recipient_device_id);
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: root_key.as_bytes(),
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| CoreError::Crypto)?;

    Ok(WrappedAccountKey {
        version: EVENT_SCHEMA_VERSION,
        key_version,
        recipient_device_id: recipient_device_id.to_owned(),
        ephemeral_public_key: B64.encode(ephemeral_public.to_bytes()),
        nonce: B64.encode(nonce),
        ciphertext: B64.encode(ciphertext),
    })
}

pub fn unwrap_account_key(
    wrapped: &WrappedAccountKey,
    recipient_private_key: &DeviceKeyPair,
) -> Result<AccountRootKey, CoreError> {
    unwrap_account_key_versioned(wrapped, recipient_private_key).map(|(_, key)| key)
}

pub fn unwrap_account_key_versioned(
    wrapped: &WrappedAccountKey,
    recipient_private_key: &DeviceKeyPair,
) -> Result<(u32, AccountRootKey), CoreError> {
    if wrapped.version != EVENT_SCHEMA_VERSION {
        return Err(CoreError::InvalidKey);
    }
    if wrapped.key_version == 0 {
        return Err(CoreError::InvalidKeyVersion(wrapped.key_version));
    }
    let ephemeral_public =
        decode_base64(&wrapped.ephemeral_public_key).ok_or(CoreError::InvalidKey)?;
    let ephemeral_public: [u8; ROOT_KEY_BYTES] = ephemeral_public
        .try_into()
        .map_err(|_| CoreError::InvalidKey)?;
    let nonce = decode_base64(&wrapped.nonce).ok_or(CoreError::Crypto)?;
    if nonce.len() != EVENT_NONCE_BYTES {
        return Err(CoreError::Crypto);
    }
    let ciphertext = decode_base64(&wrapped.ciphertext).ok_or(CoreError::Crypto)?;

    let private = StaticSecret::from(recipient_private_key.private_key);
    let shared = private.diffie_hellman(&PublicKey::from(ephemeral_public));
    let wrapping_key = derive_shared_key(shared.as_bytes())?;
    let cipher = XChaCha20Poly1305::new_from_slice(&wrapping_key).map_err(|_| CoreError::Crypto)?;
    let aad = account_key_aad(
        wrapped.version,
        wrapped.key_version,
        &wrapped.recipient_device_id,
    );
    let bytes = cipher
        .decrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: ciphertext.as_ref(),
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| CoreError::Crypto)?;
    let bytes: [u8; ROOT_KEY_BYTES] = bytes.try_into().map_err(|_| CoreError::InvalidKey)?;
    Ok((wrapped.key_version, AccountRootKey::from_bytes(bytes)))
}

pub fn export_recovery_kit(
    root_key: &AccountRootKey,
    passphrase: &str,
) -> Result<RecoveryKit, CoreError> {
    export_recovery_kit_payload(root_key.as_bytes(), passphrase)
}

/// Export all locally retained key versions. The recovery kit remains opaque;
/// the relay and file provider never see the key-ring JSON in plaintext.
pub fn export_recovery_kit_for_keyring(
    key_ring: &AccountKeyRing,
    passphrase: &str,
) -> Result<RecoveryKit, CoreError> {
    let payload = RecoveryKeySetPayload {
        active_key_version: key_ring.active_version,
        keys: key_ring
            .key_material()
            .map(|(version, key)| (version, B64.encode(key.as_bytes())))
            .collect(),
    };
    let bytes = serde_json::to_vec(&payload)
        .map_err(|error| CoreError::Serialization(error.to_string()))?;
    export_recovery_kit_payload(&bytes, passphrase)
}

fn export_recovery_kit_payload(payload: &[u8], passphrase: &str) -> Result<RecoveryKit, CoreError> {
    if passphrase.is_empty() {
        return Err(CoreError::InvalidRecoveryKit);
    }
    let mut salt = [0u8; RECOVERY_SALT_BYTES];
    OsRng.fill_bytes(&mut salt);
    let wrapping_key = derive_passphrase_key(passphrase, &salt)?;
    let cipher = XChaCha20Poly1305::new_from_slice(&wrapping_key).map_err(|_| CoreError::Crypto)?;
    let mut nonce = [0u8; EVENT_NONCE_BYTES];
    OsRng.fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: payload,
                aad: b"dayflow:recovery-kit:v1",
            },
        )
        .map_err(|_| CoreError::Crypto)?;
    Ok(RecoveryKit {
        version: EVENT_SCHEMA_VERSION,
        kdf: "argon2id".to_owned(),
        salt: B64.encode(salt),
        nonce: B64.encode(nonce),
        ciphertext: B64.encode(ciphertext),
    })
}

pub fn restore_recovery_kit(
    kit: &RecoveryKit,
    passphrase: &str,
) -> Result<AccountRootKey, CoreError> {
    let bytes = restore_recovery_payload(kit, passphrase)?;
    let bytes: [u8; ROOT_KEY_BYTES] = bytes
        .try_into()
        .map_err(|_| CoreError::InvalidRecoveryKit)?;
    Ok(AccountRootKey::from_bytes(bytes))
}

/// Restore a complete key ring from a key-ring recovery kit. Older v1 kits
/// remain supported by `restore_recovery_kit` and contain only key version 1.
pub fn restore_recovery_key_set(
    kit: &RecoveryKit,
    passphrase: &str,
) -> Result<AccountKeyRing, CoreError> {
    let bytes = restore_recovery_payload(kit, passphrase)?;
    let payload: RecoveryKeySetPayload =
        serde_json::from_slice(&bytes).map_err(|_| CoreError::InvalidRecoveryKit)?;
    let keys = payload
        .keys
        .into_iter()
        .map(|(version, encoded)| {
            let bytes: [u8; ROOT_KEY_BYTES] = B64
                .decode(encoded)
                .map_err(|_| CoreError::InvalidRecoveryKit)?
                .try_into()
                .map_err(|_| CoreError::InvalidRecoveryKit)?;
            Ok((version, AccountRootKey::from_bytes(bytes)))
        })
        .collect::<Result<BTreeMap<_, _>, CoreError>>()?;
    AccountKeyRing::from_keys(keys, payload.active_key_version)
}

fn restore_recovery_payload(kit: &RecoveryKit, passphrase: &str) -> Result<Vec<u8>, CoreError> {
    if kit.version != EVENT_SCHEMA_VERSION || kit.kdf != "argon2id" || passphrase.is_empty() {
        return Err(CoreError::InvalidRecoveryKit);
    }
    let salt = decode_base64(&kit.salt).ok_or(CoreError::InvalidRecoveryKit)?;
    let nonce = decode_base64(&kit.nonce).ok_or(CoreError::InvalidRecoveryKit)?;
    if salt.len() != RECOVERY_SALT_BYTES || nonce.len() != EVENT_NONCE_BYTES {
        return Err(CoreError::InvalidRecoveryKit);
    }
    let wrapping_key = derive_passphrase_key(passphrase, &salt)?;
    let cipher = XChaCha20Poly1305::new_from_slice(&wrapping_key).map_err(|_| CoreError::Crypto)?;
    let ciphertext = decode_base64(&kit.ciphertext).ok_or(CoreError::InvalidRecoveryKit)?;
    cipher
        .decrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: ciphertext.as_ref(),
                aad: b"dayflow:recovery-kit:v1",
            },
        )
        .map_err(|_| CoreError::InvalidRecoveryKit)
}

#[derive(Debug, Serialize, Deserialize)]
struct RecoveryKeySetPayload {
    active_key_version: u32,
    keys: BTreeMap<u32, String>,
}

fn account_key_aad(schema_version: u16, key_version: u32, recipient_device_id: &str) -> String {
    if key_version == 1 {
        // Preserve the v1 wire format so devices that were registered before
        // key-ring support can still unwrap their existing account key.
        format!(
            "dayflow:account-key:v{}:{}",
            schema_version, recipient_device_id
        )
    } else {
        format!(
            "dayflow:account-key:v{}:key{}:{}",
            schema_version, key_version, recipient_device_id
        )
    }
}

fn event_aad(
    event_id: &str,
    device_id: &str,
    logical_clock: u64,
    schema_version: u16,
    key_version: u32,
) -> String {
    format!(
        "dayflow:event:v{}:{}:{}:{}:{}:{}",
        EVENT_SCHEMA_VERSION, event_id, device_id, logical_clock, schema_version, key_version
    )
}

fn derive_shared_key(shared_secret: &[u8; 32]) -> Result<[u8; 32], CoreError> {
    let hkdf = Hkdf::<Sha256>::new(None, shared_secret);
    let mut output = [0u8; 32];
    hkdf.expand(b"dayflow:account-key-wrap:v1", &mut output)
        .map_err(|_| CoreError::Crypto)?;
    Ok(output)
}

fn derive_passphrase_key(
    passphrase: &str,
    salt: &[u8],
) -> Result<[u8; RECOVERY_KEY_BYTES], CoreError> {
    let params =
        Params::new(19 * 1024, 3, 1, Some(RECOVERY_KEY_BYTES)).map_err(|_| CoreError::Crypto)?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut output = [0u8; RECOVERY_KEY_BYTES];
    argon2
        .hash_password_into(passphrase.as_bytes(), salt, &mut output)
        .map_err(|_| CoreError::Crypto)?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_encryption_authenticates_metadata() {
        let root = AccountRootKey::generate();
        let (nonce, ciphertext) =
            seal_event(&root, "event-1", "device-a", 1, 1, 1, b"hello").unwrap();
        assert_eq!(
            open_event(&root, "event-1", "device-a", 1, 1, 1, &nonce, &ciphertext).unwrap(),
            b"hello"
        );
        assert!(open_event(&root, "event-1", "device-a", 2, 1, 1, &nonce, &ciphertext).is_err());
    }

    #[test]
    fn device_wrap_round_trips() {
        let root = AccountRootKey::generate();
        let device = DeviceKeyPair::generate();
        let wrapped = wrap_account_key(&root, "phone", &device.public_key()).unwrap();
        assert_eq!(wrapped.key_version, 1);
        let recovered = unwrap_account_key(&wrapped, &device).unwrap();
        assert_eq!(root.as_bytes(), recovered.as_bytes());
    }

    #[test]
    fn versioned_device_wrap_and_keyring_recovery_round_trip() {
        let first = AccountRootKey::generate();
        let device = DeviceKeyPair::generate();
        let mut ring = AccountKeyRing::new(first.clone());
        let (version, second) = ring.rotate().unwrap();
        assert_eq!(version, 2);

        let wrapped =
            wrap_account_key_versioned(&second, version, "phone", &device.public_key()).unwrap();
        let (recovered_version, recovered) =
            unwrap_account_key_versioned(&wrapped, &device).unwrap();
        assert_eq!(recovered_version, version);
        assert_eq!(recovered.as_bytes(), second.as_bytes());

        let kit = export_recovery_kit_for_keyring(&ring, "correct horse battery staple").unwrap();
        let restored = restore_recovery_key_set(&kit, "correct horse battery staple").unwrap();
        assert_eq!(restored.active_version(), 2);
        assert_eq!(restored.versions().collect::<Vec<_>>(), vec![1, 2]);
        assert_eq!(restored.key(1).unwrap().as_bytes(), first.as_bytes());
        assert_eq!(restored.key(2).unwrap().as_bytes(), second.as_bytes());
        assert!(restore_recovery_key_set(&kit, "wrong").is_err());
    }

    #[test]
    fn key_ring_rejects_a_different_key_for_an_existing_version() {
        let first = AccountRootKey::generate();
        let mut ring = AccountKeyRing::new(first.clone());
        assert!(ring.insert(1, first).is_ok());
        assert!(matches!(
            ring.insert(1, AccountRootKey::generate()),
            Err(CoreError::ConflictingKeyVersion(1))
        ));
    }

    #[test]
    fn recovery_kit_round_trips_and_rejects_wrong_passphrase() {
        let root = AccountRootKey::generate();
        let kit = export_recovery_kit(&root, "correct horse battery staple").unwrap();
        let recovered = restore_recovery_kit(&kit, "correct horse battery staple").unwrap();
        assert_eq!(root.as_bytes(), recovered.as_bytes());
        assert!(restore_recovery_kit(&kit, "wrong").is_err());
    }
}
