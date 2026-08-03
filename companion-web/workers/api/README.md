# Dayflow encrypted sync relay

This is the source for the unified Dayflow account relay. The older files under
`dist/` are compiled migration artifacts and are intentionally not used by this
Worker.

## Contract

- The Worker delegates bearer-token validation to the canonical Dayflow auth
  service through the `DAYFLOW_AUTH` service binding.
- Each account is routed to one SQLite-backed `AccountRelay` Durable Object.
- The relay stores device public keys, approval state, wrapped account keys,
  event routing metadata, and opaque ciphertext only.
- Device-scoped requests also carry an Ed25519 signature over the method, path,
  body hash, timestamp, nonce, and device ID. The relay stores only the public
  signing key and rejects expired or replayed proofs.
- `event_id` is idempotent. Pull uses an opaque cursor assigned by the relay.
- A normal second device is pending until an approved device sends a wrapped
  account key. Recovery mode can admit a restored device only when no approved
  device remains.
- Notification hints contain only `sync_available` and a sequence cursor; they
  contain no journal, capture, or decrypted event content.
- Approved devices can register one APNs/FCM/WNS-equivalent token through the
  signed notification route. When `DAYFLOW_PUSH_DISPATCHER` is configured, the
  relay forwards only `{ device_id, platform, token, sequence,
  kind: "sync_available" }` wake jobs; provider credentials and OS delivery
  remain outside the relay. Dispatcher failures never fail encrypted event
  sync, and foreground hint polling remains the fallback.

## Local validation

```sh
npm install
npm run types
npm run check
npx wrangler deploy --dry-run
```

The test configuration supplies a fake auth service binding. It does not prove
production authentication. Before deployment, the `DAYFLOW_AUTH` service name
in `wrangler.jsonc` must point at the deployed canonical Dayflow auth Worker,
and the two-device network inspection gate must pass. The test suite includes
both direct Durable Object contract tests and an HTTP-boundary test covering
account authentication, device signatures, nonce replay rejection, and the
absence of plaintext event fields in pulled responses.

## Auth service response

For a request containing `Authorization: Bearer ...`, the relay calls the
canonical auth service at `GET /v1/me` without forwarding the sync request body.
The canonical Dayflow response is accepted in its existing shape:

```json
{
  "user": {
    "id": "account-id"
  }
}
```

The service may also return the smaller adapter shape for deployments that
already expose a relay identity contract:

```json
{
  "account_id": "account-id",
  "subject": "user-or-session-subject"
}
```

The relay does not store or interpret the bearer token, and it never forwards
event request bodies to the auth service.
