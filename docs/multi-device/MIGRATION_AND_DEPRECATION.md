# Mac migration and PWA deprecation

## Mac database migration

The existing Mac database remains the source for current timeline, journal, and
chat UI while the event model is introduced incrementally.

Canonical local paths:

```text
~/Library/Application Support/Dayflow/chunks.sqlite
~/Library/Application Support/Dayflow/recordings/
```

Migration rules:

1. Never delete or rewrite raw recordings as part of event migration.
2. Add the event/outbox tables through the existing GRDB migration path.
3. Use stable IDs for imported derived records, such as
   `mac:v1:timeline_card:<record_id>`, `mac:v1:journal:<day>`, and
   `mac:v1:day_goal:<day>`.
4. Mark each imported event with a migration version so a crash/retry is
   idempotent. If an immutable envelope is durable but its marker is not, the
   retry reuses that envelope before recording the missing marker.
5. Keep current projections readable throughout the rollout; the Rust projection
   becomes authoritative only after replay equivalence is proven.
6. Run before/after comparisons for timeline cards, journal entries, priorities,
   daily standups, and chat context on a copy of the user's database.

The current Mac seam creates both the account-scoped and signed-out
`local-workspace-v1` encrypted event tables without changing existing UI
behavior. `DayflowMacEventWriter` seals live journal, priority, reflection,
setting, deletion, and capture-derived edits into the local workspace before
account setup, so offline use does not depend on authentication. After relay
admission, `DayflowMultiDeviceViewModel` copies those immutable envelopes into
the account outbox and invokes the Rust re-key seam when the local and account
key rings differ; the source ciphertext and local key remain intact for crash
safe retry. `DayflowMigrationCoordinator` now exports existing
timeline cards, journal entries, daily standups, and standup task priorities
into stable, Rust-sealed envelopes, records idempotent migration markers, and
places those envelopes in the local outbox. `DayflowMultiDeviceViewModel` can
replay the local encrypted stream through Rust and import the authenticated
projection back into the existing timeline/journal/daily read models without
uploading it or generating echo events. Historical day-goal plans are included
even when their days have no timeline activity. Subsequent Mac journal,
timeline-card, day-goal, and daily-standup writes append new encrypted events after their
legacy write succeeds. Daily standup snapshots use the encrypted
`daily_standup:<day>` setting aggregate; the Mac importer applies that
projection to the existing standup table without invoking the public save path.

The checked-in test covers those consumers on a synthetic copied database. The
representative real-database comparison is now available through
`scripts/verify_dayflow_real_database_migration.sh`. It creates an online
SQLite backup, runs the actual migration against an isolated copy, checks
idempotent retry and source row-count preservation, and never writes to the
source database. The check is intentionally opt-in and should be run again on
the release candidate's representative Mac data before replacing the existing
write paths. The current UI intentionally remains readable during that gate;
the raw-media network boundary remains a separate production two-device gate.

## PWA disposition

`companion-web/` is migration material, not a second product surface. The source
under `companion-web/workers/api/src/` is now the unified encrypted relay path;
the existing `dist/` bundle remains untouched until the auth binding and deploy
cutover are reviewed.

- Freeze user-facing feature work.
- Keep only auth, account/device, encrypted relay, and emergency recovery paths
  after the relay migration.
- Remove local browser pairing and the Mac loopback bridge from the product path.
- Do not preserve plaintext Durable Object `StoredState` as a cross-device truth.
- Keep a minimal account/recovery page only if native clients cannot safely expose
  that flow.

The earlier compiled browser assets remain untracked and untouched in this
checkout. They are not referenced by the new relay source and must not be
reintroduced as a user-facing product surface during migration. The
`scripts/verify_dayflow_product_surfaces.sh` guard also scans native product
source for the retired companion identifiers, Tauri runtime, browser-pairing
ports, and loopback bridge names; its workflow runs when either the retired
surfaces or native client/core paths change. It also proves Wrangler deploys
`workers/api/src/index.ts` and rejects the retired companion API terms from
that deployable relay source; compiled `workers/api/dist/` output is not a
deployment input.

The archived `adhd-companion` runtime entrypoints (`npm run dev`, `npm run
preview`, `npm run tauri`, and the Tauri `beforeDevCommand`) fail closed. This
prevents a stale login item or automation from reopening the retired browser or
desktop surface while leaving source/build/test commands available for
migration review.
