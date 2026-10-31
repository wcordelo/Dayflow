# Shared Rust core and FFI contract

## Scope

`shared-core/` owns portable semantics only:

- logical 4 AM day keys with an explicit timezone offset;
- capture privacy decisions;
- canonical event payloads and encrypted envelopes;
- append-only local event behavior, deduplication, and deterministic replay;
- materialized timeline, journal, priority, reflection, settings, and tombstone
  projections;
- account-root-key protection, approved-device wrapping, and recovery kits;
- versioned account key rings, historical event replay, and key-ring recovery;
- an offline outbox with idempotent acknowledgement.

The portable acceptance scenario in
[`shared-core/tests/two_device_sync.rs`](../../shared-core/tests/two_device_sync.rs)
models two devices receiving approved key versions, making offline edits,
retrying after an uncertain relay acknowledgement, replaying duplicate and
out-of-order envelopes, applying a tombstone, and restoring the full key ring.
Its relay double stores only `EventEnvelope` values and has no account key or
plaintext projection path.

Native shells own screen capture, system permissions, secure-store APIs, local
SQLite drivers, notifications, UI, networking, and model/provider integration.
Native sync stores persist only opaque event envelopes and non-sensitive cursors
or logical clocks. Projections are replayed in memory from the encrypted event
log and, on Mac, applied to the existing local read model; the multi-device
sync cache does not persist a second plaintext projection copy.

## Event model

```rust
pub struct EventEnvelope {
    pub event_id: String,
    pub device_id: String,
    pub logical_clock: u64,
    pub schema_version: u16,
    pub key_version: u32,
    pub nonce: String,      // base64, 24 bytes
    pub ciphertext: String, // base64, XChaCha20-Poly1305 payload + tag
}
```

The encrypted payload is a versioned JSON `EventPayload`. The event AAD binds the
event ID, device ID, logical clock, schema version, and key version, so changing
routing metadata invalidates authentication.

Stable aggregate IDs are separate from immutable envelope IDs. In v1, the
cross-device journal aggregate for a logical day is
`mac:v1:journal:<yyyy-mm-dd>` (the historical prefix is retained for wire
compatibility), while each edit uses a fresh device-scoped event ID. Timeline
cards created from the Mac legacy database use
`mac:v1:timeline_card:<record_id>`; capture-derived cards use their originating
device's stable capture ID. Reflections use
`mac:v1:reflection:<yyyy-mm-dd>` so a logical-day reflection converges across
native clients. Newly authored priorities use a globally unique
`dayflow:v1:priority:<uuid>` unless an existing stable ID is being edited;
settings use their setting key as the projection aggregate. The Mac migration
and legacy daily editor may use `daily_standup:<yyyy-mm-dd>` for an encrypted
standup snapshot; this is a content projection key, not a provider or secret
setting.

Supported payloads in v1:

- `CaptureDerived`
- `TimelineCardUpsert`
- `JournalUpsert`
- `PriorityUpsert`
- `ReflectionUpsert`
- `SettingUpsert`
- `Tombstone`

`CaptureDerived` carries optional `source` and `derivation_mode` strings. They
are encrypted with the rest of the payload and default to empty when an older
event is replayed. Native capture adapters must use truthful labels such as
`android_media_projection` / `privacy_gated_local_visual_v1` or
`windows_graphics_capture` / `privacy_gated_local_context_v1`; a bounded local
visual/context derivation must not be labeled as AI-derived unless a local
model actually produced it. The deterministic `TimelineCard` projection
retains the same fields, and local chat context includes them so a card remains
attributable on another device.

Raw screenshots and recordings are not event payloads and never enter the sync
queue by default.

The v1 shared-setting namespace is intentionally allowlisted by each native
shell. It includes `dayflow.theme`, `dayflow.capture.paused`,
`dayflow.logical_day_boundary_hour`, `day_goal:<yyyy-mm-dd>`, and
`daily_standup:<yyyy-mm-dd>`. The last two are encrypted content projections,
not provider credentials or secret configuration. A shell must reject unknown
or secret setting keys before sealing an event. The shared Rust seal, ingest,
and local-workspace re-key boundaries enforce the same allowlist as a
defense-in-depth check; dated projection keys must contain a valid ISO
calendar date, and `dayflow.capture.paused` must be exactly `true` or `false`.

## AI provider boundary

The sync relay is never an inference source: encrypted event envelopes and raw
capture media are not sent to it for model execution. Each native client builds
AI context from its local projections and decrypted event log, then uses the
user-selected local model or provider configuration.

The existing Mac Dayflow Pro hosted provider remains an explicit, optional
backward-compatibility path. When selected, it may receive the activity data
needed for its requested transcription/card/daily operation, but it does not
receive synced ciphertext or become the timeline source of truth. Its endpoint
must pass the same HTTPS-or-loopback validation as account traffic; requests
use an ephemeral cookie-free session and reject redirects so bearer tokens and
activity context cannot silently cross a host or scheme boundary.

## Projection ordering

Clients sort decrypted records by:

```text
(logical_clock ASC, device_id ASC, event_id ASC)
```

The result is deterministic across devices, independent of arrival order. A
tombstone is an operation over a stable aggregate ID. A later edit can
intentionally recreate that ID; the behavior is deterministic and testable.

## FFI

The crate exposes a typed Rust API for native wrappers and a conservative C ABI:

```c
char *dayflow_core_version(void);
char *dayflow_core_seal_json(const char *payload_json,
                             const char *event_id,
                             const char *device_id,
                             uint64_t logical_clock,
                             const unsigned char *root_key,
                             size_t root_key_len);
char *dayflow_core_project_json(const char *envelopes_json,
                                const unsigned char *root_key,
                                size_t root_key_len);
char *dayflow_core_wrap_account_key_json(const unsigned char *root_key,
                                         size_t root_key_len,
                                         const char *recipient_device_id,
                                         const unsigned char *recipient_public_key,
                                         size_t recipient_public_key_len);
char *dayflow_core_unwrap_account_key_json(const char *wrapped_key_json,
                                           const unsigned char *private_key,
                                           size_t private_key_len);
char *dayflow_core_export_recovery_kit_json(const unsigned char *root_key,
                                            size_t root_key_len,
                                            const char *passphrase);
char *dayflow_core_restore_recovery_key_json(const char *kit_json,
                                             const char *passphrase);
char *dayflow_core_project_keyring_json(const char *envelopes_json,
                                        const char *key_ring_json);
char *dayflow_core_seal_key_version_json(const char *payload_json,
                                         const char *event_id,
                                         const char *device_id,
                                         uint64_t logical_clock,
                                         uint32_t key_version,
                                         const unsigned char *root_key,
                                         size_t root_key_len);
char *dayflow_core_wrap_account_key_versioned_json(const unsigned char *root_key,
                                                   size_t root_key_len,
                                                   uint32_t key_version,
                                                   const char *recipient_device_id,
                                                   const unsigned char *recipient_public_key,
                                                   size_t recipient_public_key_len);
char *dayflow_core_export_recovery_kit_keyring_json(const char *key_ring_json,
                                                    const char *passphrase);
char *dayflow_core_restore_recovery_keyring_json(const char *kit_json,
                                                 const char *passphrase);
char *dayflow_core_generate_device_keypair_json(void);
char *dayflow_core_generate_account_root_key_json(void);
char *dayflow_core_generate_device_signing_keypair_json(void);
char *dayflow_core_sign_request_json(const char *message,
                                     const unsigned char *private_key,
                                     size_t private_key_len);
bool dayflow_core_capture_allowed(bool permission_granted,
                                  bool user_paused,
                                  bool device_locked,
                                  bool sleeping,
                                  bool private_context,
                                  bool drm_content);
char *dayflow_core_logical_day_key(long long timestamp_unix,
                                   int timezone_offset_minutes,
                                   unsigned char boundary_hour);
void dayflow_core_free_string(char *value);
```

`seal_json`, `project_json`, their key-ring variants, and the recovery functions are local-only
operations. The root key is supplied by the caller and is never copied into the
relay or a log. Swift and Kotlin wrappers are generated from the UniFFI layer;
C# uses the checked-in header and P/Invoke boundary. Native shells must keep
secret key bytes in their platform secure store and pass them only for the
duration of a core call. Each device also has a separate Ed25519 signing key;
device-scoped relay requests must prove possession of that private key with the
canonical request-signing contract in `SYNC_PROTOCOL.md`. An approved device
wraps the account key with the recipient's X25519 public key; the recipient
unwraps it locally before projecting events. Versioned wrappers bind the
selected `key_version` into the authenticated wrapping context.

The Apple packaging entry points are
[`scripts/build_dayflow_core_xcframework.sh`](../../scripts/build_dayflow_core_xcframework.sh)
and [`scripts/build_dayflow_core_ios_xcframework.sh`](../../scripts/build_dayflow_core_ios_xcframework.sh).
They fail closed when required Rust Apple targets are not installed rather than
silently producing a single-architecture artifact.

## Compatibility rules

- New fields are optional until all clients understand them.
- A client must reject unknown required schema versions without deleting local
  data.
- Key rotation increments `key_version`; old events remain readable while the
  account retains the corresponding prior key version.
- Event IDs are globally unique and immutable.
- User edits append operations; they never overwrite the remote event log.
