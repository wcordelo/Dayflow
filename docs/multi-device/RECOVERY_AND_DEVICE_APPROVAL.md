# Recovery and device approval

## Keys

- Generate a random 32-byte account root key locally through `shared-core` on
  the first trusted device. After rotation, retain the active key plus every
  historical version still needed to replay local events.
- Store device private keys in the platform secure store, never in UserDefaults,
  logs, sync payloads, or analytics.
- Encrypt event payloads with XChaCha20-Poly1305 and bind envelope metadata as
  associated data.
- Wrap the account root key to an approved device's X25519 public key using an
  ephemeral sender key and a derived symmetric wrapping key.
- The relay returns `key_bootstrap_required: true` only for the persisted,
  device-bound admission grant created when it admits the first non-recovery
  device into an account with no prior device. This remains retryable if that
  client crashes before storing its root key, and is consumed after that
  device successfully accepts its first encrypted event. Existing devices,
  recovery registrations, and later devices must receive a wrapped key or a
  recovery kit; native clients fail closed instead of generating a replacement
  key that could fork the account.
- If a device was previously revoked, recovery admission may re-use its stable
  device ID only after every approved device is gone and the request explicitly
  carries `recovery_mode`. The relay replaces the device public keys and clears
  stale wrapped keys and push tokens before marking it approved, so a restored
  secure store cannot accidentally receive wrappers encrypted for the old
  identity. A revoked device cannot use this path while another approved device
  remains.

`shared-core` implements these primitives and tests round trips plus wrong-key,
wrong-passphrase, key-version replay, and key-ring recovery rejection. Native
secure stores remain shell responsibilities. Every client now has source-level
registration, device approval/revocation, versioned wrapped-key delivery,
encrypted outbox, local projection wiring, and key-ring recovery-kit
export/import surfaces. The Mac client has the complete first-party Settings
flow; Windows, Android/ChromeOS, and iOS still need their platform SDK,
packaging, secure-store, and target-device validation gates.

## Recovery kit

The recovery kit is a user-exported JSON document containing:

- version and KDF identifier (`argon2id`);
- random salt;
- random XChaCha20-Poly1305 nonce;
- ciphertext containing the active key version and all locally retained account
  key versions. Older single-root v1 kits remain importable.

The passphrase is never persisted or transmitted. A wrong passphrase fails closed.
The UI must explain that anyone with both the kit and its passphrase can restore
the account.

## Approval UX

Adding a device must show the exact device name and request approval on an already
trusted device. A recovery-kit restore can use explicit recovery admission only
when no approved device remains; otherwise it still waits for an existing trusted
device. Revoking a device must show when its last sync occurred and clarify that
local data on the revoked device remains local until the user removes it.

## Key rotation

Key rotation is an account operation:

1. generate a new root key and increment `key_version`;
2. wrap the new key to every remaining approved device while preserving the
   historical wrapped-key records;
3. write future events under the new key version;
4. keep old key versions only as long as local historical events require;
5. re-encrypt only when the user explicitly requests historical migration.

The portable core, local key rings, multi-version relay storage, and native
source seams are implemented. Mac, Windows, Android/ChromeOS, and iOS expose a
user-facing rotate action that distributes the new version to every approved
peer before activating it locally. Two-device delivery, offline retry, and
historical replay remain release-gate tests on their target platforms.

Each native client stores an encrypted pending candidate in its platform secure
store before the first peer delivery. If a later peer is offline or rejects the
request, the next attempt reuses the same key and version rather than issuing a
different key under the same version. The candidate is promoted to the active
key-ring only after all approved peers have accepted it.
