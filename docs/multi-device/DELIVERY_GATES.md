# Delivery and acceptance gates

## Phase 0 — feasibility

- Build `shared-core` on macOS and in a non-Apple CI environment.
- Add Rust-to-Swift, Rust-to-Kotlin, and Rust-to-C# binding smoke tests.
- Validate Mac GRDB export/replay equivalence on copied databases (covered by
  `testRustProjectionReplaysIntoACopiedMacReadModel` and the opt-in
  `scripts/verify_dayflow_real_database_migration.sh` real-database check).
  The current development Mac's 14-record database check passed on 2026-08-02;
  the release-candidate representative-database run remains a release gate.
- Run native capture spikes for Windows, Android/ChromeOS, and iOS before
  promising background behavior.

## Phase 1 — Mac foundation

- Current timeline/daily/weekly/journal/chat flows remain unchanged.
- Event/outbox tables are local and contain no raw media.
- Offline replay produces identical projections before and after restart.
- Sync is opt-in and encrypted; server responses are opaque to the client relay.
- Connected Devices reports a persisted last-successful-sync state and queued
  encrypted-event count; “connected” is not shown until local projection apply
  completes.
- Android/ChromeOS, Windows, and iOS use the same persisted health keys and
  bounded states (`unknown`, `synced`, `waiting_for_approval`, `failed`).
  Restarting a client retains the last successful replay, approval wait, or
  sanitized failure category without retaining event content; target-host
  execution remains a separate gate.

## Phase 2 — Android/ChromeOS

- MediaProjection consent, foreground status, stop, lock, sleep, shutdown,
  keyguard/interactivity checks, permission revocation, source resize, and the
  post-consent foreground-service handshake are all visible and tested.
  Repeated starts are ignored while consent or a session is active. A service
  heartbeat turns stale persisted RUNNING/STARTING state into an explicit
  stopped state after process or service death, and screen-off/shutdown never
  auto-resume capture.
- Android/ChromeOS now has a provider-neutral content-free wake entry point:
  an explicit `sync_available` broadcast schedules a bounded `JobService`
  sync, while FCM credentials, provider delivery, and physical background
  execution remain open gates.
- Chromebook keyboard, mouse, resize, multi-window, offline storage, and Play
  packaging are covered.

## Phase 3 — Windows

- Windows.Graphics.Capture picker, visible capture border, multi-monitor, sleep,
  privacy exclusions, single-session/late-picker cancellation, and package
  installation are covered.

## Phase 4 — iOS

- ReplayKit/other permitted capture sessions are explicit, stoppable, and
  guarded against repeated start/stop actions.
- Background/termination behavior is documented from device tests, not assumed.
- In-app activity and journaling remain useful when OS-wide capture is unavailable.

## Required automated tests

- Two-device offline/online replay with deterministic projections.
- Concurrent edits, duplicate delivery, out-of-order delivery, and tombstones.
- Device approval, revocation, and recovery-kit restore are covered by shared-core
  and relay tests; native secure-store and target-device restore tests remain open.
  Versioned key-ring retention, multi-version wrapped-key relay storage, and
  core recovery are implemented. User-facing rotation/distribution is wired in
  the Mac, Windows, Android/ChromeOS, and iOS source clients; two-device
  rotation/replay and native target-device restore remain separate release gates.
- Raw-media non-exfiltration test using a fake relay and network inspection is
  covered locally by the Mac `URLProtocol` test; production two-device network
  inspection remains a release gate.
- Privacy pause tests for private context, DRM, lock, sleep, and permission loss.
- Application/window privacy policy tests through the shared JSON decision ABI.
- Battery/CPU/storage benchmarks per platform.

## Current status

| Gate | Status |
| --- | --- |
| Portable Rust core, unit tests, and two-device opaque-relay integration test | Implemented in this branch; capture-to-derived-card-to-local-chat relay path is covered by the three-test integration suite |
| Non-Apple shared-core CI | `.github/workflows/dayflow-core.yml` now runs formatting, tests, clippy, release linking, and Swift/Kotlin binding generation smoke checks; hosted-run evidence is still required |
| Native client CI | `.github/workflows/dayflow-native-clients.yml` now defines Mac non-interactive/XCFramework/unsigned-DMG, iOS SDK/package/application-target/unsigned-archive, Android/ChromeOS Gradle/NDK/AAB, and Windows WinUI/C ABI/MSIX jobs; hosted execution is still required |
| Foreground reconnect | Mac, Android, iOS, and Windows source clients coalesce a guarded sync on activation; signed-out/partial setup remains local-only, local workspaces link through immutable rekeyable envelopes, and target-device lifecycle/offline-online replay validation remains open |
| Content-free push wake contract | Relay token registration, revocation cleanup, content-free wake-job dispatch, iOS's exact silent APNs payload validation, Android's exact-signal broadcast-to-`JobService` path, and Windows WNS channel/raw-signal handling are implemented; FCM/WNS provider bindings, credentials, package identity, OS delivery, and target-device background behavior remain release gates |
| Mac local encrypted-event/outbox seam | Implemented in this branch; signed-out `local-workspace-v1` and account-scoped v2 tables use secure key custody, immutable envelopes, clocks, cursors, migration markers, persisted bounded sync health, and crash-safe Rust re-key linking |
| Mac XCTest/unit validation | Passing 133-test baseline with the shared `Dayflow` scheme limited to non-interactive tests, including remote-merge logical-clock replay/rollback, capture-source preference/privacy coverage, shared cross-device capture-pause parsing, copied-database Rust-to-GRDB projection replay, opt-in representative real-database migration/retry validation, relay bootstrap admission, Mac account URL validation, Mac privacy-signal coverage, day-goal migration encoding, encrypted-envelope shape validation, and intercepted raw-media network-boundary inspection; connected-device sync-health source parses and is guard-checked; shared-Rust logical-day and canonical-request XCTest additions are source-checked but await a healthy Xcode host rerun; the project contains no XCTest UI target or scheme |
| Shared privacy decision ABI | Implemented and tested through Rust, Mac C ABI, iOS UniFFI, Android source, and Windows source |
| Cloudflare opaque relay migration | Implemented locally; auth/deploy gate open |
| Mac Rust binary/XCFramework packaging | Implemented locally; native target links the generated XCFramework and the hosted workflow now packages an unsigned DMG |
| Windows shell | Capture + DPAPI/SQLite/signed-relay source, canonical email-code auth, local workspace/linking, complete local projection/chat context, journal/priority/reflection/setting paths, tombstone-backed record deletion, notification-hint cursor consumption, durable four-state sync health, WNS channel registration and exact-signal wake handling, and a C-ABI smoke-test project implemented; the default build is unpackaged WinUI 3 and the same project now has an unsigned single-project MSIX workflow, while native SDK/build/install/signing/device and WNS background gates still require Windows |
| Android/ChromeOS shell | Capture + Keystore/SQLite/signed-relay source, canonical email-code auth, local workspace/linking, complete local projection/chat context, journal/priority/reflection/setting paths, tombstone-backed record deletion, notification-hint cursor consumption, durable four-state sync health, projected shared capture-pause privacy wiring, lock/sleep/shutdown capture stop handling, durable secure-store/device-identity commits, and instrumented UniFFI/secure-store smoke tests implemented; SDK/NDK, Rust ABI libraries with required-UniFFI export verification, debug APK, release AAB, JVM tests, and 7/7 API 36 arm64 emulator instrumentation tests pass locally, while Play upload, physical-device, and ChromeOS capture gates remain |
| iOS shell | SwiftUI application target plus package/ReplayKit + Keychain/SQLite/signed-relay source, canonical email-code auth, local workspace/linking, complete local projection/chat context, journal/priority/reflection/setting paths, tombstone-backed record deletion, notification-hint cursor consumption, durable four-state sync health, exact silent APNs wake validation, and shared capture-pause privacy wiring implemented; package tests now cover fail-closed pause parsing, remote-merge clock advancement, bounded health persistence, the native capture-status contract, the shared-setting date contract, the generated-Rust canonical request vector, and a generated-Rust recovery-kit versioned-key round trip (34 tests), generic device/simulator application-target builds pass locally, and the hosted workflow defines an unsigned archive; TestFlight/signing/device capture gates remain |
| Native AI configuration | Provider route/API-key storage, local projection context, and direct provider execution are source-implemented on Windows, Android/ChromeOS, and iOS; the optional Mac hosted provider is endpoint-hardened and remains outside the sync source-of-truth path; target-client/network validation remains open |
| Native recovery UX | Versioned recovery-kit export/import is source-implemented on Mac, Windows, Android/ChromeOS, and iOS; iOS package, Android generated-UniFFI instrumentation, and Windows C-ABI smoke-test sources now exercise retained key versions and wrong-passphrase rejection; secure-store, file/share, and target-device execution remain open |
| Native device administration | List/approve/revoke operations and native settings surfaces implemented in all clients; native device validation remains open |
| Native key rotation | Source-implemented across Mac, Windows, Android/ChromeOS, and iOS; two-device delivery, offline retry, and target-device replay validation remain open |
| Capture-to-derived event path | Mac display/application/window selection → selected-source or frontmost privacy signals → analysis → timeline → sealed event path is connected and carries capture provenance; Mac journal/priority/reflection edits also feed sealed projections; Android/iOS/Windows capture emits privacy-gated local samples with truthful provenance into account-scoped encrypted outboxes, while platform AI derivation and target-device benchmarks remain open |
| PWA and Tauri retirement | Product-surface boundary and relay-only scope are guarded locally; existing prototype/dist preserved for reviewed migration |

The repository intentionally distinguishes “implemented locally” from “validated
on the target OS.” Windows's conditional MSIX path is source- and CI-defined,
but package generation, signing, installation, and capture gates still require
Windows. Android debug and release bundle configuration plus emulator binding
validation are source-defined/local, while Play upload, physical-device, and
ChromeOS capture gates remain. iOS application-target packaging is locally
validated and an unsigned archive is workflow-defined, while signing, TestFlight,
and physical-device capture remain open. The Mac DMG path is likewise unsigned;
notarization and install/upgrade validation remain release gates.
