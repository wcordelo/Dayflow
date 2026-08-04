# Encrypted sync protocol

## Trust model

The relay authenticates accounts/devices, stores opaque envelopes, assigns pull
cursors, and exposes content-free wake hints. Approved native clients can also
register one platform push token; the relay forwards only a content-free wake
job to an optional provider dispatcher. Native clients still consume the
connection on foreground activation when the dispatcher is not configured. The
relay cannot decrypt timeline, journal,
priority, reflection, settings, or capture-derived content.

The implemented relay uses a Cloudflare Worker and one SQLite-backed Durable
Object per account. The existing plaintext `StoredState` model is not compatible
with this contract and must not remain the source of truth.

## Device lifecycle

1. The first non-recovery device is explicitly admitted by the relay with
   `key_bootstrap_required: true` and creates the account root key locally.
   The relay persists that device-bound admission so a retry after a client
   crash can finish bootstrap, then consumes the grant after the first
   encrypted event is accepted. Existing devices and later registrations must
   restore or receive a wrapped key; they never silently generate a replacement
   key.
2. The device registers a public device key and a display name with the relay.
3. An existing approved device authorizes a new device and sends one wrapped
   record per retained key version; alternatively the user imports a recovery
   kit. A recovery-restored device may use explicit recovery admission only
   when the account has no approved device remaining. If its stable device ID
   is already present as revoked, the relay replaces that record's identity
   material and clears stale wrappers before re-admitting it; ordinary requests
   cannot overwrite a revoked device.
4. The new device stores its private device key and account key ring in the
   platform secure store. It verifies the wrapped record's recipient and key
   version against the authenticated wrapper before decrypting its local event
   stream and beginning cursor-based sync.
5. Revocation prevents future wrapped-key delivery and relay access. Local data is
   not silently deleted; the user explicitly chooses local cleanup.

Each native client also stores an account-scoped `account-key-admitted-v1`
marker in its platform secure store after one of those explicit admissions. It
is continuity state, not a replacement for relay authorization: registration,
device approval, and wrapped-key validation remain required on every sync. The
marker prevents a valid first device from being rejected on its next restart
after the relay consumes the one-time bootstrap grant and therefore returns no
wrapped key for that same device. A raw legacy key ring without this marker
still fails closed until the relay provides a wrapper or the user completes
recovery.

## Push and pull

```text
POST /v1/sync/devices
POST /v1/sync/events       { envelopes: [opaque EventEnvelope] }
GET  /v1/sync/events?cursor=<opaque cursor>
POST /v1/sync/devices/:id/approve
POST /v1/sync/devices/:id/revoke
GET  /v1/sync/devices/:id/wrapped-key
GET  /v1/sync/devices/:id/wrapped-keys
GET  /v1/sync/notifications?cursor=<opaque cursor>
PUT  /v1/sync/notifications     { token: <platform push token> }
DELETE /v1/sync/notifications
```

Every route requires a Dayflow account bearer token validated by the canonical
`DAYFLOW_AUTH` service binding through `GET /v1/me`. Device-scoped routes also require a registered
`X-Dayflow-Device-ID` plus `X-Dayflow-Device-Timestamp`,
`X-Dayflow-Device-Nonce`, and `X-Dayflow-Device-Signature` headers. The
signature covers `dayflow:v1:<timestamp>:<method>:<path+query>:<sha256(body)>:<nonce>:<device_id>`.
The relay verifies the registered Ed25519 public key, enforces a five-minute
clock window, and consumes each nonce once.

The Rust core owns the native construction of that string, including UTF-8 body
hashing and uppercasing the method. The Worker keeps the verifier-side formatter
and pins it to this cross-language vector:

```text
body = {"hello":"opaque"}
sha256(body) = b7e6d00fedcbdee445a53f6b804273eeb7a62879a6891f7bdc4f9b238675a4f4
dayflow:v1:1723456789:POST:/v1/sync/events?cursor=abc:b7e6d00fedcbdee445a53f6b804273eeb7a62879a6891f7bdc4f9b238675a4f4:0123456789abcdef0123456789abcdef:mac-device
```

The Rust unit/ C-ABI tests and Worker test assert the same vector. Native
clients call the generated UniFFI or C-ABI canonical-request function before
passing the returned string to the shared signing function.
The invariants do not:

- push is idempotent by `event_id`;
- pull is cursor-based and repeatable;
- envelopes are returned byte-for-byte or with a documented canonical encoding;
- notification bodies contain no journal/capture content;
- push registration and delivery contain only a provider token, device
  platform, sync sequence, and `sync_available` kind;
- a relay outage never prevents local capture or journaling;
- the relay has no plaintext projection endpoint.

Native outboxes persist only envelope metadata, opaque ciphertext, and
non-sensitive retry/cursor state. Projection JSON is derived on demand and is
not retained as a second plaintext sync cache; existing local UI read models
remain device-local and are updated only after local decryption and replay.

### Durable sync health

Every native outbox uses the same bounded metadata keys so a configured device
can explain its connection state after restart without storing event content:

| Key | Meaning |
| --- | --- |
| `last_sync_at` | Unix timestamp of the latest replay attempt |
| `last_successful_sync_at` | Unix timestamp after the complete local Rust projection replay succeeds |
| `last_sync_state` | `unknown`, `synced`, `waiting_for_approval`, or `failed` |
| `last_sync_failure` | Sanitized category such as `authentication`, `admission`, `relay_server`, `invalid_response`, or `local_storage` |

The encrypted pending-event count is read from the outbox, not copied into a
second projection. A successful replay clears the previous failure category;
approval waits and failures retain the last successful timestamp. Raw relay
errors, journal text, capture metadata, and provider responses are never
persisted as health diagnostics. Mac, Windows, Android/ChromeOS, and iOS expose
this same state in their account surfaces.

The singular wrapped-key route remains a compatibility route returning the
highest retained version. New clients use wrapped-keys to retrieve the full
opaque set needed to replay historical events.

### Local workspace linking

Each native client creates a device-local `local-workspace-v1` before account
setup. Journal, priority, reflection, setting, deletion, and capture-derived
events are sealed into that workspace immediately, so offline use does not
depend on authentication. The UI labels this state as local-only and tracks
the encrypted pending count.

After account admission resolves the destination key ring, the client copies
local envelopes into the account outbox. It preserves event IDs and device
identity, skips exact IDs already copied after an interrupted attempt, and uses
the Rust `rekey_envelopes_json` seam whenever the destination key bytes differ
from the source key bytes, including the common case where both key rings call
their first key version `1`. An interrupted link accepts the same deterministic
destination envelope on retry; an unrelated same-ID envelope is rejected. The
local workspace keeps its source ciphertext and key ring because SQLite and the
platform secure store cannot commit atomically. If a retry finds an older valid
destination envelope after key rotation, it compares the decrypted projection
before accepting the existing account copy; an unrelated same-ID envelope is
rejected. The local workspace records the linked account ID and refuses to link
the same local records to a different account.

### Notification hints

`GET /v1/sync/notifications?cursor=<opaque cursor>` returns only a cursor and
content-free `{ sequence, kind: "sync_available" }` hints. Mac, Windows,
Android/ChromeOS, and iOS persist a notification cursor separately from the
encrypted-event cursor and advance it only after the response is decoded and
validated. An approved device may `PUT` its current APNs, FCM, WNS, or
platform-equivalent token to the same device-proof route; `DELETE` removes it,
and revocation removes it automatically. The relay stores the token only as a
wake address and never combines it with event content.

When `DAYFLOW_PUSH_DISPATCHER` is configured as a Cloudflare service binding,
each newly-created hint is sent to that dispatcher as a batch with
`schema_version: 1` and `{ device_id, platform, token, sequence,
kind: "sync_available" }` entries. The dispatcher owns APNs/FCM/WNS credentials
and is responsible for sending a silent/content-free wake notification. A
dispatcher outage is advisory: the event push still succeeds, the durable hint
cursor remains available, and foreground activation remains the fallback.

The relay accepts only the envelope's routing metadata and opaque base64 text.
It validates the nonce/ciphertext encoding and minimum authenticated-envelope
shape, but never decrypts, inspects plaintext, or infers an event kind. The
current JavaScript boundary requires `logical_clock` to be an integer in
`1...Number.MAX_SAFE_INTEGER`; every native allocator and local store enforces
the same upper bound so a clock cannot be persisted locally and then become
unrepresentable at the relay. The Rust core remains the canonical logical-clock
implementation and fails explicitly when the bound is exhausted.

## Conflict behavior

Clients merge by event ID, decrypt locally, sort by the projection ordering in
`CORE_CONTRACT.md`, and rebuild projections. Duplicate and out-of-order delivery
are expected, not exceptional. A transport retry must not create a second journal
entry or timeline card. An exact duplicate envelope is a no-op; a different
envelope for an existing event ID is a conflict and is rejected before relay
mutation. Native local stores apply the same immutable-ID check before SQLite
insert, so a conflicting delivery cannot be silently hidden by `INSERT OR IGNORE`.
Native clients also compare the decrypted bytes of a newly delivered wrapped
account key against any locally retained key with the same version. A mismatch
fails closed instead of silently keeping one of two possible account keys.
Wrapped account-key documents are immutable per `(device_id, key_version)` at the
relay as well: an exact retry is idempotent, while a different document is
rejected as a conflict rather than replacing the key delivered to that device.

## Relay migration requirements

Before enabling cross-device sync in production:

- add an encrypted-envelope storage table separate from the current plaintext
  state;
- stop writing new plaintext `StoredState` records;
- retain a bounded, audited migration read path only if existing users need their
  companion state imported;
- prove with an integration test and network inspection that raw media and
  decrypted event payloads never leave a source device.

The local relay contract tests now cover first-device approval, pending-device
gating, wrapped-key delivery, idempotent event push, cursor pull, content-free
notification hints, push-token registration/removal, and the HTTP boundary from
account authentication through device proof and nonce replay rejection.
Production activation still requires wiring `DAYFLOW_AUTH` to the deployed
canonical auth Worker, configuring a provider dispatcher with platform
credentials, and running the two-device network inspection gate.
