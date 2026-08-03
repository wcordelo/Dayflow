# Unified platform requirement audit

Last audited: 2026-08-02.

This is the evidence map for the unified multi-device plan. “Implemented” means
the repository contains the product-path source and a local contract; “verified”
means the relevant build or test ran in this checkout. A target-host or
credential gate is not promoted to verified from source inspection alone.

## Architecture and data contract

| Requirement | Current evidence | State |
| --- | --- | --- |
| One native product family, no companion product | Native Mac, Windows, Android/ChromeOS, and iOS clients; retired PWA/Tauri guards in `MIGRATION_AND_DEPRECATION.md` and `verify_dayflow_product_surfaces.sh` | Implemented and locally guarded |
| Shared Rust domain/privacy/encryption/event/sync core | `shared-core/`, generated Swift/Kotlin bindings, `shared-core/include/dayflow_core.h`, Windows C ABI seam; CI regenerates and diffs checked-in bindings | Implemented; Rust tests, clippy, and binding parity pass locally |
| Four AM logical day boundary | `shared-core/src/day_boundary.rs` and every native bridge | Implemented and tested |
| Append-only events and deterministic projections | `shared-core/src/events.rs`, `projection.rs`, native encrypted SQLite stores, and `capture_derived_event_replays_from_privacy_gate_through_opaque_relay_into_local_chat` | Implemented; duplicate/order/conflict replay and capture-to-chat relay path pass |
| Capture, journal, priority, reflection, setting, and tombstone events | `EventPayload` and native enqueue paths | Implemented and replay-tested |
| Opaque encrypted relay envelopes | Cloudflare Worker/Durable Object under `companion-web/workers/api/src/` | Implemented; relay tests and Wrangler dry-run pass |
| Canonical device-request proof | `shared-core/src/request.rs`, C ABI/UniFFI bindings, native relay clients, and Worker fixed-vector test | Implemented; Rust/Worker vector and native call-site guards pass locally |
| No raw media or plaintext projection on relay | Envelope-only route, explicit field-bounded push wake builder, Mac URLProtocol network test, and opaque-relay capture test asserting title/summary/provenance are absent from wire | Locally verified; production network inspection remains open |
| Truthful native capture status | Mac, Android/ChromeOS, Windows, and iOS status surfaces expose `capture_permission`, `capture_session`, `capture_paused`, and `derived_sync`; malformed shared pause settings remain fail-closed | Implemented in source with Mac/iOS/Android/Windows contract tests; target-device rendering remains open |
| Versioned key rings, device approval, recovery, and revocation | `crypto.rs`, `RECOVERY_AND_DEVICE_APPROVAL.md`, native secure stores, relay admission tests, and stable-ID recovery re-admission cleanup | Source implemented; target-device restore remains open |
| Local-first operation without an account/network | Per-client `local-workspace-v1`, encrypted local outboxes, local journal/projection paths | Implemented in source; target-device restart validation remains open |
| On-device AI context and provider storage | Native projection/chat clients and Keychain/Keystore/DPAPI provider stores | Implemented; target-client/provider network validation remains open |

## Platform delivery

| Client | Implemented source | Verified in this checkout | Remaining evidence |
| --- | --- | --- | --- |
| Mac | Existing app integrated with Rust/GRDB migration, shared Rust logical-day C ABI, event writer, durable per-account sync health, connected-device settings, capture pause, recovery/device administration | Xcode `Dayflow` scheme: 133-test baseline; opt-in migration check moved 14 records through an isolated backup with an idempotent retry and unchanged source row counts; no UI-test target/scheme; logical-day and canonical-request XCTest additions are source-checked but await a healthy Xcode host; changed sync-health/settings Swift parses and product guards pass | Signed DMG, notarization, release-candidate representative DB migration, production two-device network inspection |
| Android | Compose shell, MediaProjection foreground service, lock/sleep/shutdown/privacy lifecycle, resize handling, Keystore/SQLite sync, durable sync health, recovery/device/admin/chat | Debug APK, release AAB, JVM tests, 7/7 API 36 arm64 emulator instrumentation tests, generated-UniFFI recovery-kit versioned-key/wrong-passphrase test, canonical request vector, and host-independent sync-health summary test in source | Physical MediaProjection consent/revocation, battery/storage, Play/ChromeOS install and multi-window |
| ChromeOS | Same Android client with ARC detection, capability-driven adaptive width/padding/spacing, MediaProjection resize path, and optional touchscreen/portrait Play features | Source and Android package build; manifest guard, pure adaptive-capability tests, and Android JVM suite pass | Physical Chromebook keyboard/mouse/resize/multi-window/offline/capture behavior and Play validation |
| Windows | WinUI 3 shell, `Windows.Graphics.Capture` picker/border/frame pool, DPAPI/SQLite/C ABI, durable sync health, local projection/chat | Contract guard only on this Mac; Windows source includes a reopen/persistence health test | Windows SDK restore/build, C ABI tests, MSIX install/upgrade/signing, picker/border/multi-monitor/sleep tests |
| iOS | SwiftUI app target, ReplayKit explicit session, Keychain/SQLite sync, durable sync health, recovery/device/admin/chat | Swift package 34 tests, including generated-Rust versioned recovery-key round trip, wrong-passphrase rejection, bounded sync-health persistence, the native status contract, the shared-setting date contract, and the canonical request vector | Physical ReplayKit lifecycle, background/termination behavior, signing/TestFlight/App Store review |

## Sync wake and capture truthfulness

- The relay stores durable content-free notification hints and accepts signed
  push-token registration/removal. The iOS SwiftUI client now registers APNs
  tokens after account admission and accepts only the exact silent payload
  shape (`aps.content-available = 1` plus `kind = sync_available`).
  Android/ChromeOS now expose a provider-neutral explicit-broadcast to
  `JobService` wake path that rejects extra wake fields before scheduling and
  before execution. Windows now requests a WNS channel after admission and
  routes only the exact content-free wake signal into the same coalesced sync;
  FCM/WNS token delivery and background execution remain release gates.
- The optional `DAYFLOW_PUSH_DISPATCHER` boundary receives only platform token,
  device ID, sequence, and `sync_available`; provider credentials remain outside
  the relay.
- Native clients expose registration transports and consume foreground hints.
  APNs/FCM/WNS credentials, provider delivery, and OS background execution are
  intentionally release gates rather than simulated locally. The Android
  receiver accepts only the exact `sync_available` signal and never treats
  notification content as an event payload. iOS rejects extra APNs fields and
  alert payloads. Windows also validates a raw WNS payload as exactly
  `{ "kind": "sync_available" }` before waking.
- Android, iOS, and Windows currently emit truthful privacy-gated metadata cards
  when their capture adapters have not run a local visual model. They do not
  label metadata as AI-derived or sync raw frames. The shared event schema
  rejects unknown capture/timeline fields before sealing, and the Windows
  metadata-only fallback excludes foreground window titles. The Mac retains its
  existing local analysis pipeline.

## Connected-device health

- The Mac now persists only bounded account-scoped sync health metadata: last
  attempt time, last successful replay time, result state, and a short failure
  category. It never stores raw relay errors or event content in the diagnostic
  metadata.
- Connected Devices now surfaces “connected,” “waiting for approval,” “needs
  attention,” “not synced yet,” and the encrypted event queue count. This state
  survives a restart, so a configured relay is not presented as connected until
  a full authenticated pull, projection, and local apply have completed.
- The Swift source parse, native-contract, product-surface, test-scheme, Rust,
  and relay checks pass for this slice. A normal Mac XCTest/build rerun remains
  subject to the host's CoreDevice plug-in abort documented below.
- Android, Windows, and iOS now use the same four-state durable health contract
  and persist only timestamps plus sanitized failure categories. Their native
  account surfaces show the replay result and encrypted queue after restart;
  Android's JVM and iOS package tests cover the host-independent summary/store
  seams, while Windows has a target-host test source that awaits the Windows
  SDK.

## Security and product-surface checks

- Mac Gemini text, activity-card, transcription, dashboard, upload, file-status,
  onboarding test-connection, and Gemma fallback requests now send API keys in
  `x-goog-api-key`; first-party Dayflow sources contain no `?key=` construction.
- Native relay/auth/provider endpoints reject credentials, query strings,
  fragments, non-HTTPS remote HTTP, redirects, cookies, and cache reuse as
  applicable to the client.
- The normal Mac scheme contains only non-interactive unit tests. The removed UI
  suite cannot recreate the multi-launch `AutomationMode` incident, and
  `LSMultipleInstancesProhibited=true` adds a Launch Services single-instance
  boundary for the shipped Mac app.
- Dayflow agent source links do not use AppleScript, `osascript`, or Ghostty
  control; Claude links reveal the local transcript in Finder and the product
  guard rejects those automation surfaces if they return.
- The retired ten-minute Cursor/GitHub Bugbot automation for the old companion
  PR has been removed from the repository. The product-surface guard rejects
  both its former workflow path and Cursor automation source path if they are
  reintroduced; a dashboard-created Cursor automation remains an external
  manual cleanup item.
- The browser/Tauri prototypes are migration material only; the product-surface
  guard rejects new user-facing web source and scans native product code for
  legacy companion, Tauri, browser-pairing, and loopback-bridge references. It
  also verifies Wrangler points at the opaque relay source rather than the
  preserved compiled companion output.
- The archived companion's dev, preview, and Tauri runtime entrypoints now fail
  closed, so a stale login item or automation cannot reopen that product path;
  source/build/test commands remain available for migration review.
- All repository-provided Xcode/build/release scripts run the AutomationMode
  setup preflight before invoking Xcode, so the machine-level safety boundary
  cannot be bypassed by an opt-in migration or packaging command.

## Release gates that cannot be proven on this Mac

1. Windows SDK, WinUI, MSIX, and `Windows.Graphics.Capture` execution.
2. Physical Android/ChromeOS MediaProjection and Play behavior.
3. Physical iOS ReplayKit, background/termination, signing, and TestFlight.
4. Production `DAYFLOW_AUTH` deployment and provider dispatcher credentials.
5. Two-device production network inspection, secure-store restore, and
   platform battery/CPU/storage benchmarks.

These are explicitly tracked in [DELIVERY_GATES.md](DELIVERY_GATES.md) and
[VALIDATION_LOG.md](VALIDATION_LOG.md); they are not silently treated as
complete because source contracts are green.
