# Unified platform validation log

This log records the validation performed on the development Mac for the
unified multi-device foundation. It deliberately separates source/build proof
from target-device release gates.

Last rechecked: 2026-08-02.

## Latest continuation regression sweep

- Host-independent checks were rerun after the external-automation cleanup:
  shared Rust tests passed 50 unit tests plus 3 integration tests, clippy with
  warnings denied passed, the iOS package passed all 34 tests, and the opaque
  relay passed typecheck plus 13 tests across 5 files.
- A full matrix rerun on this checkout reproduced those results: Rust format,
  tests, and clippy passed; `swift test --package-path clients/ios` passed 34
  tests; Android `:app:verifyDayflowCoreNative` and `:app:testDebugUnitTest`
  passed; `npm run check` plus Wrangler dry-run passed; and the native,
  product-surface, test-scheme, and diff guards passed. The Android build again
  emitted only the known FSEvents stream warning.
- Android's required native-ABI export verifier and JVM unit suite passed when
  Gradle was run with the discovered SDK at
  `/opt/homebrew/share/android-commandlinetools`. The documented Android
  README/setup path remains the supported invocation because a raw Gradle
  command without `ANDROID_HOME` or `ANDROID_SDK_ROOT` cannot locate the SDK.
- Mac Swift parsing, iOS plist/entitlement and scheme XML validation, native
  contract/product-surface/test-scheme guards, and `git diff --check` passed.
  `xcodebuild -checkFirstLaunchStatus` also passes, but the normal Mac scheme
  remains intentionally uninvoked while the external root AutomationMode
  writer (PID 68463) is active; the safe setup preflight exits before launching
  an app, Xcode, or automation.
- No current repository automation definition or Dayflow-related launchd entry
  remains. GitHub API access was unavailable during this sweep, so already
  published remote workflow state and any Cursor dashboard automation remain
  explicit external cleanup gates rather than locally verified facts.
- The archived `adhd-companion` runtime is now fail-closed: `npm run dev`,
  `npm run preview`, `npm run tauri`, and the Tauri `beforeDevCommand` all exit
  before starting Vite, a browser, or a desktop window. The three entrypoint
  checks returned status 1 as intended, and ports 5173 and 1420 were not
  listening afterward.
- The exact ignored `adhd-companion/dist-app/ADHD Companion.app` bundle that the
  old login agent referenced was moved to the macOS Trash, and the product
  surface guard now fails if that executable is recreated in the checkout.
  This closes the remaining local stale-binary path without deleting the
  archived source or its audit plist.
- The opaque relay `npx wrangler deploy --dry-run` passed with only the
  `ACCOUNT_RELAY` Durable Object and canonical `DAYFLOW_AUTH` service binding;
  no legacy companion Durable Object or server-owned plaintext state is in the
  deployable Worker input.
- Every repository script that can invoke Xcode now runs the safe setup
  preflight first: the real-database migration check, both XCFramework
  builders, the DMG release builder, and the release metadata path. A live
  test of the migration script stopped at the existing AutomationMode writer
  before creating a build directory or starting `xcodebuild`; native-contract
  guards require these preflight calls to remain present. Both hosted Apple
  workflow jobs also contain the explicit preflight step, and the native
  workflow path filters include each guarded build/migration/release script.
  The native-contract verifier also enforces that each preflight appears before
  the first protected Xcode or release-mutation command.
- ChromeOS adaptive capability detection now separates Android `Context` access
  from pure ARC/window-size classification. JVM coverage verifies Chromebook
  large-window behavior, phone-sized behavior, and a resized ChromeOS window;
  the Compose surface now consumes the capability-derived width, padding, and
  spacing policy rather than only displaying an ARC label. The Android native
  ABI verifier and `:app:testDebugUnitTest` pass with the added tests. Physical
  Chromebook resize, input, and capture behavior remain device gates.

## Latest setup safety slice

- The normal `verify_dayflow_setup.sh` path no longer invokes `xcodebuild -list`.
  On this Mac, Xcode 26.4 on macOS 26.5.2 aborts in
  `DVTCoreDeviceLocator`/`xpc_add_bundle` during that command, despite
  `xcodebuild -checkFirstLaunchStatus` passing. The old unconditional probe was
  therefore capable of producing fresh Xcode crash reports during an ordinary
  setup check.
- Project evaluation remains available only through the explicit
  `--evaluate-project` flag. The safe path checks the license/first-launch state,
  file and contract guards, launch-agent state, single-instance protection, and
  external AutomationMode without opening an app or starting automation.
- The hosted native-client workflow no longer runs `xcodebuild -list`; its Mac
  jobs run the safe setup preflight and non-interactive scheme guard before
  proceeding to build/test. This prevents the known CoreDevice plug-in probe
  and stale AutomationMode session from turning a valid source checkout into a
  fresh automation/Xcode crash before the actual Dayflow target is evaluated.
- On the current host, the safe path still stops before any Xcode command because
  the external root `automationmode-writer` session (PID 68463) is active. The
  user must clear that stale system session with Control-Option-Command-Period
  or restart macOS before a manual Dayflow run.

## Latest cross-client shared-setting contract slice

- Mac, Android, iOS, and Windows now validate the same v1 shared-setting
  namespace before creating an event. Exact settings remain
  `dayflow.theme`, `dayflow.capture.paused`, and
  `dayflow.logical_day_boundary_hour`; dated projection settings must use a
  real Gregorian `YYYY-MM-DD` suffix under `day_goal:` or `daily_standup:`.
  Unknown keys, malformed dates, and non-boolean capture-pause values remain
  rejected before sealing.
- Regression coverage now rejects an impossible leap-day, malformed dated
  keys, and a provider-secret key on each native shell. Rust remains the final
  defense-in-depth boundary for local append, FFI/UniFFI sealing, replay
  ingest, and workspace re-key.
- Host validation passed: `cargo fmt --check`, 50 Rust unit tests, 3 opaque
  relay integration tests, clippy with warnings denied, `swift test
  --package-path clients/ios` with 34 tests, Android `:app:testDebugUnitTest`,
  native-contract/product-surface/test-scheme guards, Mac Swift parsing, and
  `git diff --check`. The Windows helper and MSTest source are wired into both
  projects but still require the Windows SDK/.NET host for execution.
- The Mac Foundation runtime independently round-tripped `2026-02-28` and
  `2026-08-01`, and rejected `2026-02-29` and the non-padded `2026-2-01`,
  matching the shell regression tests and Rust `NaiveDate` boundary.
- The setup script now discovers standard Homebrew and user Android SDK paths
  when `ANDROID_HOME`/`ANDROID_SDK_ROOT` are unset. This Mac has a complete
  SDK at `/opt/homebrew/share/android-commandlinetools`; the Android Gradle
  unit build already passes against that installation. The Android README now
  includes the same shell-local resolution so Gradle does not fall back to a
  missing machine-specific `local.properties` file.
- `verify_dayflow_setup.sh --run-tests` now runs the Android JVM unit suite when
  that discovered SDK and `gradle` are available. It does not start an
  emulator, open Android Studio, launch a client, or invoke UI automation.
- A fresh `:app:connectedDebugAndroidTest` attempt reached the instrumentation
  task but stopped with Gradle's `No connected devices`; `adb` confirmed no
  attached emulator. This does not replace the earlier recorded 4/4 API 36
  emulator result or prove physical Android/ChromeOS behavior.
- The setup preflight now classifies a matching `DVTCoreDeviceLocator` or
  `xpc_add_bundle` crash report as an Xcode CoreDevice plug-in failure, keeping
  it distinct from the already-passing license/first-launch check.
- When `--run-tests` reaches Android, setup now runs Gradle's native ABI/export
  verifier before the JVM suite. Missing or stale Rust libraries produce the
  rebuild command instead of a late Kotlin/UniFFI test failure.
- A fresh UniFFI generation into a temporary directory matched the checked-in
  Swift, Swift FFI header/modulemap, iOS Swift copy, and Kotlin artifacts. The
  shared-core CI workflow now regenerates those artifacts and fails on drift.
- The Mac C ABI boundary was rechecked: the XCFramework header module is named
  `DayflowCoreFFI`, imports `dayflow_core.h`, and matches the Swift
  `import DayflowCoreFFI` in `DayflowCoreBridge.swift`. The native-contract
  guard now protects that module name/header pairing so a future Rust
  XCFramework rebuild cannot silently break the Mac target.

## Latest recovery retry slice

- Recovery restore admission now remains marked on Mac, iOS, Android/ChromeOS,
  and Windows until encrypted events have been projected locally and sync
  health records success. A registration, wrapped-key, network, projection, or
  local-write failure therefore retries with recovery admission instead of
  silently downgrading the next attempt to an ordinary device registration.
- `verify_dayflow_native_contracts.sh` now enforces the source ordering of that
  invariant across all four clients. Rust, iOS package, Android JVM/native
  contract, product-surface, test-scheme, and diff checks passed after the
  change. Windows compilation remains a Windows-host gate.

## Latest retired external automation cleanup

- Removed the repository's scheduled `*/10 * * * *` Cursor Bugbot agent and its
  matching `.cursor/automations/` source file. That agent targeted the archived
  ADHD Companion PR and could create recurring external automation sessions
  unrelated to the unified Dayflow product.
- The product-surface guard now rejects those exact automation definitions if
  they are reintroduced, and its workflow path filter runs when either retired
  definition changes. This is separate from macOS `AutomationMode`: any
  already-created Cursor dashboard automation must still be disabled in the
  Cursor UI, and any remote workflow change requires the normal repository
  publish/review gate.

## Latest canonical relay-request slice

- The Rust core now owns canonical device-request construction, including
  method normalization, path validation, timestamp/nonce/device validation,
  and lowercase SHA-256 hashing of the exact request body. Its fixed wire
  vector is shared by the C ABI, UniFFI bindings, native clients, and Worker
  verification tests.
- Mac and Windows call the C-ABI function; iOS and Android call the generated
  UniFFI function. The clients pass the returned message to the existing Rust
  signing function, so no platform reimplements the signed-string format.
- `cargo test --all-features` passes 50 Rust unit tests plus 3 integration
  tests; clippy with warnings denied, binding generation/parity, the iOS
  package (34 tests), Android JVM tests plus Android instrumentation-test
  compilation, Worker checks (13 tests), native contract guards, C-header
  syntax, and `git diff --check` also pass. The native Mac/iOS/Android/Windows
  smoke-test sources now all assert the same canonical request vector; Windows
  execution remains a Windows SDK gate, and the Mac XCTest awaits a healthy
  Xcode host rerun.

## Latest host-independent recheck

- `cargo test --manifest-path shared-core/Cargo.toml --all-features` passed 50
  unit tests plus 3 integration tests, and clippy with warnings denied passed.
- `swift test --package-path clients/ios` passed all 34 package tests,
  including the generated-Rust canonical request vector. Android
  `:app:testDebugUnitTest` passed with the discovered SDK at
  `/opt/homebrew/share/android-commandlinetools`.
- The opaque relay `npm run check` passed 5 test files and 13 tests. Native
  contract, product-surface, and test-scheme guards passed, and `git diff
  --check` passed.
- The Mac scheme was not invoked because the safe preflight still detects the
  pre-existing root `AutomationMode` writer (PID 68463). The newly added Mac
  canonical-request XCTest is source-checked and will be included in the next
  normal-scheme run after that machine-level session is cleared.

## Latest Android native ABI recheck

- The first API 36 arm64 emulator run exposed a real stale-artifact failure:
  the generated Kotlin binding required
  `uniffi_dayflow_core_fn_func_canonical_device_request`, while the existing
  ABI libraries did not export it. The Gradle file-existence check incorrectly
  accepted those libraries.
- `scripts/build_dayflow_core_android.sh` rebuilt arm64-v8a, armeabi-v7a, and
  x86_64 libraries with the current Rust core. The Gradle `verifyDayflowCoreNative`
  task now checks the required generated-UniFFI export in every ABI before
  `preBuild`, so this stale-binding failure is caught before packaging.
- After the rebuild, `gradle :app:connectedDebugAndroidTest` passed all 7 API
  36 arm64 emulator tests, including the canonical request, recovery-kit, and
  privacy/projection smoke tests. Physical Android/ChromeOS capture,
  consent, battery, resize, and multi-window behavior remain open.
- With the same rebuilt libraries, `:app:assembleDebug`,
  `:app:bundleRelease`, and `:app:testDebugUnitTest` passed; the release AAB
  was produced at `clients/android/app/build/outputs/bundle/release/app-release.aab`.

## Latest native capture status contract slice

- Mac settings, Android/ChromeOS Compose, Windows WinUI, and iOS SwiftUI now
  expose the same four local status fields: `capture_permission`,
  `capture_session`, `capture_paused`, and `derived_sync`. The values are
  derived from each platform's capture adapter and local projection health;
  they are diagnostics only and are not added to relay payloads.
- Malformed shared pause settings fail closed in the visible status as well as
  in the capture decision path. Clearing a pause still permits only a future
  explicit consent/picker action; it never starts capture automatically.
- Privacy-paused states now report `not_active` for permission on Android,
  Windows, and iOS rather than implying that an old platform token remains
  valid. This keeps a pause-before-consent and a pause-after-stop equally
  explicit to the user.
- The iOS package suite passed all 34 tests, including the new status-field
  contract test. Android and Windows have deterministic JVM/MSTest source
  coverage for the same mapping, while their target SDK/toolchain gates remain
  open on this Mac. The Mac XCTest additions are source-checked but await the
  host's CoreDevice plug-in repair.
- Native-contract, product-surface, test-scheme, and diff checks remain the
  required host-independent guards for this slice.

## Latest ChromeOS distribution slice

- The Android/ChromeOS manifest now marks touchscreen and portrait orientation
  as optional. This keeps the same Compose client eligible for non-touch,
  landscape, keyboard-and-mouse Chromebooks instead of allowing Play hardware
  filtering to turn the Chromebook path into a phone-only build.
- The native-contract guard requires the optional-touchscreen declaration. A
  Play Console upload, compatible Chromebook install, resize/multi-window
  capture session, and offline-storage run still require the target Android/
  ChromeOS host and credentials.

## Latest native-client sync health slice

- Android, Windows, and iOS now persist the same bounded replay metadata in
  their account-scoped SQLite outboxes: attempt time, successful replay time,
  one of `unknown`, `synced`, `waiting_for_approval`, or `failed`, and a
  sanitized failure category. The clients show this state alongside the
  encrypted pending-event count after restart; raw relay errors and event
  content are excluded.
- `swift test --package-path clients/ios` passed all 34 package tests,
  including bounded sync-health persistence across a store reopen. Swift
  source parsing, Rust core tests (50 unit plus 3 integration), relay checks
  (5 files / 13 tests), native-contract, product-surface, test-scheme, and
  `git diff --check` validation passed.
- Android now has both a JVM summary test and an instrumented SQLite reopen
  test in source. Windows has the corresponding MSTest source and C# store
  implementation, but this Mac has no .NET/Windows SDK; those remain target
  host gates rather than local pass claims.

## Latest connected-device health slice

- The Mac account workspace now records bounded sync health metadata after a
  full authenticated relay replay and local projection apply: last attempt,
  last successful sync, result state, and a sanitized failure category. Raw
  relay errors, journal text, capture content, and provider responses are not
  persisted in this metadata.
- Connected Devices now shows the real state across restarts: connected only
  after a completed replay, waiting for approval, sync needs attention, not yet
  synced, and the number of encrypted events still queued locally.
- `swiftc -parse` passed for the changed Mac sync models, local store, view model,
  and settings view. Native-contract, product-surface, and test-scheme guards
  passed; shared Rust passed 44 unit plus 3 integration tests; and the relay
  passed 5 files / 12 tests.
- Xcode project evaluation still aborts in the host CoreDevice plug-in before
  project evaluation, so this slice has not been promoted to a new Mac XCTest
  or app-build claim. No app or automation was launched during validation.

## Latest capture-to-chat relay path

- Added and passed `capture_derived_event_replays_from_privacy_gate_through_opaque_relay_into_local_chat` in `shared-core/tests/two_device_sync.rs`.
  The scenario starts with a permitted Android MediaProjection context, seals a
  truthful `CaptureDerived` event, sends it through the ciphertext-only relay
  double, replays it on a Mac device in reverse transport order, and compares
  the deterministic timeline projection and local chat context.
- The serialized relay wire was asserted not to contain the capture title,
  summary, platform source, or derivation mode. This closes the local
  acceptance-path evidence for capture locally → derive timeline → sync
  ciphertext → decrypt on another device → chat reflects the same record.
- `cargo test --manifest-path shared-core/Cargo.toml --features
  uniffi-bindings` now passes 44 unit tests and 3 opaque-relay integration
  tests; clippy with warnings denied also passes.
- The relay check (5 files, 12 tests), Wrangler dry run, native-contract,
  product-surface, test-scheme, and diff checks pass after the addition.

## Latest native recovery binding coverage

- `swift test --package-path clients/ios` passed all 30 package tests. The new
  generated-Rust test exports a two-version recovery kit, restores both key
  versions, checks the active version, and rejects a wrong passphrase.
- The Android instrumentation source now contains the equivalent generated
  UniFFI recovery-kit round trip and wrong-passphrase test, and the Windows
  C-ABI smoke-test source contains the same versioned-key coverage. A local Gradle
  rerun in this session could not start because no Android SDK is installed or
  configured (`ANDROID_HOME` and `ANDROID_SDK_ROOT` are empty); this remains a
  target/host validation item rather than a claimed pass.
- The native-contract guard now requires both recovery tests so the secure
  binding seams cannot regress silently.

## Latest Xcode host diagnosis

- `xcodebuild -checkFirstLaunchStatus` exits successfully, so the current
  failure is not an unfinished license or first-launch task.
- The Mac data volume was at 99% capacity and the per-user temporary directory
  contained roughly 45 GB of stale Dayflow/Xcode build and test outputs. The
  identified artifacts were removed after confirming their Xcode workspace
  metadata pointed at this repository and that no process had them open; the
  live Dayflow database, source tree, unrelated project caches, and simulator
  data were not touched.
- `verify_dayflow_real_database_migration.sh` now creates a unique disposable
  DerivedData directory and removes it on every exit; callers can set
  `DAYFLOW_REAL_DB_DERIVED_DATA` or `DAYFLOW_KEEP_REAL_DB_DERIVED_DATA=1` when
  they intentionally need to retain a failed build for inspection. The script
  was exercised against the current failing host: `xcodebuild` exited 134 and
  the disposable-build leftover count was zero.
- Fresh Mac `xcodebuild` project/list, Mac SDK build, and Mac test invocations
  abort before project evaluation in Xcode's CoreDevice/build-system plugin
  while `DVTCoreDeviceLocator` calls `xpc_add_bundle`. The same assertion is
  present in the generated `xcodebuild` crash reports under
  `/Library/Logs/DiagnosticReports/`; restarting the user-owned CoreDevice and
  CoreSimulator service instances, rerunning first launch, and removing the
  project DerivedData cache did not change the result.
- The documented `DVTDisableCoreDeviceLocator` diagnostic was tested as a
  process environment value and in an isolated temporary HOME; neither
  suppresses this Xcode 26.4 failure. No persistent Xcode preference remains
  changed. Mac source parsing, the existing 133-test baseline, and all
  non-Xcode validation remain valid; rerun the two new logical-day XCTest
  cases after repairing or restarting the Xcode host.

## Latest Mac logical-day adapter

- Mac event writing and legacy migration now call the shared Rust C ABI for the
  canonical 4 AM day key, using the timestamp's local timezone offset; the
  existing GRDB/UI day helper remains the local read-model compatibility path.
- The timeline payload encoder accepts an explicit canonical day override, and
  the Mac test suite now covers the Rust ABI boundary transition plus payload
  override behavior. The linked XCFramework exports
  `dayflow_core_logical_day_key` and the native-contract guard checks the seam.
- Swift parsing, native-contract/product-surface/test-scheme guards, and diff
  validation pass. The new XCTest itself still needs a successful Xcode host
  run because the current machine is aborting in CoreDevice plugin discovery
  before project evaluation.

## Latest independent contract rerun

- `cargo fmt --check`, 44 shared-core unit tests, 2 two-device opaque-relay
  integration tests, and clippy with warnings denied passed after the Mac
  logical-day adapter change.
- The relay passed all 5 test files and 12 tests; `npx wrangler deploy
  --dry-run` still exposes only `AccountRelay` and `DAYFLOW_AUTH`.
- `swift test --package-path clients/ios` passed all 29 package tests.
- Native-contract, product-surface, test-scheme, Swift parse, plist lint, and
  `git diff --check` passed. The Mac XCTest command remains separately blocked
  before project evaluation by the host Xcode CoreDevice assertion.

## Latest automation-surface hardening

- `Dayflow/Dayflow/Info.plist` now sets `LSMultipleInstancesProhibited=true`,
  adding a Launch Services single-instance boundary so a stale launcher cannot
  fan out multiple Dayflow app processes. The product-surface guard requires
  this setting to remain present.
- `AgentThreadOpener` no longer invokes `osascript`, AppleScript, or Ghostty.
  Codex source links remain explicit `codex://` URLs; Claude source links use
  Finder to reveal the local transcript instead of focusing or creating a
  terminal window.
- `verify_dayflow_test_scheme.sh` now rejects any leftover `DayflowUITests`
  source and the XCUI launch APIs that caused the repeated app-start path, so
  an Xcode-generated UI target cannot quietly return without failing the guard.
- The Mac app no longer declares `NSAppleEventsUsageDescription`, and the
  product-surface guard rejects `/usr/bin/osascript`, Apple Events usage, and
  Ghostty scripting if they are reintroduced into native product code.
- `swiftc -parse` for the changed opener, plist lint, the product-surface
  guard, the test-scheme guard, and `git diff --check` pass. The exact retired
  launch agent remains disabled with `Disabled=true` and `RunAtLoad=false`.
- A fresh `xcodebuild` attempt on this Mac currently aborts inside Xcode's
  CoreDevice/plugin discovery before project evaluation with a root-owned
  `xpc_add_bundle` assertion; this is a host Xcode service failure, not a
  Dayflow compile diagnostic. The earlier 133-test Mac validation remains the
  source/build evidence, and the build should be rerun after that host state
  is repaired.

## Latest retired-web runtime cleanup

- The development Mac still had a 26-hour-old Vite/Wrangler process tree from
  `/private/tmp/dayflow-origin.../companion-web`, listening on `localhost:5173`
  and `localhost:8787` with additional workerd/esbuild children. Those exact
  two user-owned process groups were stopped; the Codex app server, native
  clients, and deployable relay source were not touched.
- The retired PWA is now absent from both the native product guard and the
  active local runtime. The preserved browser bundle remains migration-only.

## Latest real-database migration check

- `scripts/verify_dayflow_real_database_migration.sh` built the normal Mac
  test bundle and ran the opt-in migration test against an online backup of
  the current `~/Library/Application Support/Dayflow/chunks.sqlite` database.
- 14 legacy records were migrated into the isolated encrypted event workspace;
  the retry migrated zero additional records, and the source row counts were
  unchanged. The live database was not used as the migration destination.
- A release-candidate representative database, signed release packaging, and
  install/upgrade validation remain separate release gates.

## Latest product-boundary guard hardening

- `verify_dayflow_product_surfaces.sh` now scans `Dayflow/`, `clients/`, and
  `shared-core/` source for the retired companion identifiers, Tauri runtime,
  browser-pairing ports, and loopback bridge references while allowing valid
  loopback AI-provider endpoints.
- The same guard verifies Wrangler deploys `workers/api/src/index.ts` and
  rejects retired `StoredState`/companion API terms from deployable relay
  source, leaving compiled migration output outside the product path.
- The product-surface workflow now runs when native client/core paths change,
  so a legacy product dependency cannot be introduced without the guard
  executing.
- The product-surface guard and `git diff --check` pass in the current
  checkout.

## Latest current-worktree completion audit

- Shared core: `cargo fmt --check`, 44 unit tests, 3 opaque-relay integration
  tests, and `cargo clippy --all-targets -- -D warnings` passed.
- Relay: `npm run check` passed 5 test files and 12 tests; the Wrangler dry run
  completed with only the `AccountRelay` Durable Object and canonical
  `DAYFLOW_AUTH` service binding.
- Native clients: the Mac scheme passed 133 non-interactive tests; the iOS
  simulator application build and 29 Swift package tests passed; Android
  `testDebugUnitTest`, `assembleDebug`, and `bundleRelease` passed with the
  packaged Rust ABIs.
- Guards: native-contract, product-surface, test-scheme, and `git diff --check`
  all passed. A final normal Mac build removed test-host-only XCTest,
  XCUIAutomation, and AutomationMode support artifacts from the app bundle.
- Runtime cleanup: no Dayflow, retired ADHD Companion, `xcodebuild`, or
  `xctest` process remained; the exact retired launch agent remains disabled
  with `Disabled=true` and `RunAtLoad=false`.
- Completion remains split at the target boundary: Windows SDK/WinUI/MSIX and
  capture execution, physical Android/ChromeOS and Play behavior, physical iOS
  ReplayKit/background behavior, production auth/push credentials, and
  two-device production inspection/benchmarks still require their target
  hosts, devices, or deployment credentials. They are not promoted from local
  source/build evidence alone.

## Latest iOS capture lifecycle fix

- ReplayKit start completion is now handled explicitly. A successful session
  enters `running` as soon as ReplayKit accepts it instead of waiting for the
  first video sample, and a start error becomes an explicit stopped state.
  Late completion callbacks remain ignored after Stop or a privacy transition.
- `swift test --package-path clients/ios` — 29 package tests passed.
- `xcodebuild -project clients/ios/DayflowMobile.xcodeproj -scheme
  DayflowMobileApp -sdk iphonesimulator ... build` — the installable iOS app
  target built successfully after the ReplayKit lifecycle change.
- The native contract guard now protects the explicit ReplayKit completion
  handler. Physical ReplayKit/background/termination behavior remains a
  target-device gate.

## Latest repository-wide validation sweep

- `cargo fmt --manifest-path shared-core/Cargo.toml --check`, 46 Rust tests,
  and clippy with warnings denied passed, including the two-device opaque-relay
  replay tests.
- The relay `npm run check` passed with 5 test files and 12 tests, and
  `npx wrangler deploy --dry-run` passed with the `AccountRelay` and
  `DAYFLOW_AUTH` bindings.
- The normal Mac `Dayflow` scheme passed all 133 tests. `xcodebuild -list`
  still exposes no UI-test target or scheme.
- Android `:app:testDebugUnitTest`, `:app:assembleDebug`, and
  `:app:bundleRelease` passed with the packaged Rust ABIs.
- Native-contract, product-surface, and test-scheme guards passed, as did
  `git diff --check`.
- After the sweep, no `xcodebuild`, `xctest`, Dayflow app, or retired
  `ADHD Companion` process remained. The exact retired launch agent is still
  disabled with `Disabled=true` and `RunAtLoad=false`; the system-owned
  `automationmode-writer` service remains expected external macOS state.

## Latest recovery re-admission fix

- The relay now supports a recovery-kit restore on a device whose stable ID was
  previously revoked, but only when no approved device remains and the request
  explicitly uses `recovery_mode`.
- Re-admission replaces the old device public keys and clears old wrapped-key
  records, bootstrap grants, and push tokens before the device becomes approved.
  This prevents a restored secure store from receiving ciphertext wrappers for
  an obsolete identity.
- The Durable Object regression test covers a revoked Windows device, removal
  of the last approved device, changed identity material, stale-wrapper
  cleanup, and replay of the existing opaque event history.

## Latest automation/autostart cleanup

- The Mac project now contains only `Dayflow` and `DayflowTests`; the repeated
  UI-test target and launch tests were removed. `xcodebuild -list` and
  `bash scripts/verify_dayflow_test_scheme.sh` confirm that the shared scheme
  has only the non-interactive test target.
- The development Mac still had a loaded `~/Library/LaunchAgents/ADHD
  Companion.plist` that launched the retired Tauri prototype with
  `--autostart`. `scripts/disable_legacy_dayflow_autostart.sh` disabled and
  unloaded that exact agent while preserving the plist for auditability.
- A normal unsigned Mac build succeeded and removed stale XCTest/UI automation
  frameworks from DerivedData. No `xcodebuild`, `xctest`, UI automation, or
  companion app process remains. `automationmode-writer` is still present as a
  launchd-owned macOS developer service; it is not a Dayflow process.

## Latest automation preflight isolation

- The independent host checks passed: all native/product/test-scheme guards,
  the Rust core tests, the iOS package tests, the opaque relay tests, and the
  Xcode first-launch/license check. The current
  `bash scripts/verify_dayflow_setup.sh --run-tests` run now fails fast before
  any `xcodebuild` call because macOS still has a root-owned
  `AutomationMode.framework/automationmode-writer` process from an earlier
  external desktop-control session.
- The setup guard treats that system state as a failure rather than a warning,
  and checks it before project evaluation. Dayflow cannot clear a root-owned
  macOS AutomationMode session from the app or an unprivileged shell; clear it
  with Control-Option-Command-Period or restart macOS, then rerun the
  preflight.
- This is separate from the remaining Xcode CoreDevice plugin abort. The
  license and first-launch state are healthy, and no Dayflow or retired
  companion process was running during the check.

## Latest capture payload privacy recheck

- The shared Rust event boundary now rejects unknown fields on
  `CaptureDerived` and `TimelineCard` payloads before sealing. A regression test
  proves a `screenshot` field cannot enter the encrypted event schema, rather
  than merely relying on the relay to ignore it.
- Windows metadata-only fallback cards now use only a bounded application
  identity. Foreground window titles are deliberately excluded because they
  can contain document, meeting, or message content; a Windows-host test
  covers the generic and application-specific descriptions.
- `cargo test --manifest-path shared-core/Cargo.toml --features
  uniffi-bindings` — 46 tests passed (44 unit tests and 2 integration tests).
  The native contract guard and `git diff --check` also passed.

## Latest push-wake payload recheck

- iOS now validates the complete silent APNs shape before waking sync: the
  payload must contain only `aps.content-available = 1` and
  `kind = sync_available`. Extra journal/capture fields, alert payloads, and
  boolean `content-available` values are rejected by a package test.
- Android now validates the explicit wake action plus the complete extras key
  set before scheduling `JobService`, and validates the scheduled extras again
  before running sync. Provider-specific delivery remains a release gate.
- `swift test --package-path clients/ios` — 29 package tests passed, including
  the exact silent-payload contract. The native contract guard passed.

## Latest native product-path recheck

- `xcodebuild -project Dayflow/Dayflow.xcodeproj -scheme Dayflow ... test` —
  133 Mac tests passed. The app delegate and Connected Devices settings now
  observe one shared `DayflowMultiDeviceViewModel`, so sync state is not split
  between the resident sync path and the settings surface.
- `xcodebuild -project clients/ios/DayflowMobile.xcodeproj -scheme
  DayflowMobileApp -sdk iphonesimulator ... build` — the installable iOS app
  target built successfully with the exact APNs wake contract.
- With `ANDROID_HOME=/opt/homebrew/share/android-commandlinetools`,
  `gradle :app:testDebugUnitTest` passed, and
  `gradle :app:assembleDebug :app:bundleRelease` produced the debug APK and
  release AAB successfully.
- `npm run check` in `companion-web/workers/api` — 5 test files and 12 tests
  passed; `npx wrangler deploy --dry-run` completed with the opaque relay's
  `AccountRelay` and canonical auth bindings.

## Latest replay-correctness recheck

- Native local stores now advance their device-local Lamport clock to the
  highest accepted remote envelope inside the same SQLite transaction as the
  merge. Conflicting batches roll back both the event rows and clock update.
  The portable Rust ingest behavior and Mac, iOS, Android, and Windows store
  implementations now share this invariant.
- `xcodebuild ... -scheme Dayflow ... test` — 133 Mac tests passed with the
  normal non-interactive scheme; no UI-test target or scheme is present.
- `swift test --package-path clients/ios` — 29 package tests passed.
- Android `:app:testDebugUnitTest`, `:app:assembleDebug`, and
  `:app:bundleRelease` passed with the installed SDK/NDK. The new local-store
  replay test also ran in `:app:connectedDebugAndroidTest`: 4/4 API 36 arm64
  emulator instrumentation tests passed.
- `cargo test --manifest-path shared-core/Cargo.toml --features
  uniffi-bindings` — 46 tests passed; `cargo clippy` passed with warnings
  denied. Native contract guards and `git diff --check` passed.
- Windows source and its new store test compile path remain a Windows SDK/
  .NET host gate; no Windows toolchain is installed on this Mac.

## Passed on macOS

- `cargo fmt --manifest-path shared-core/Cargo.toml --check`
- `cargo test --manifest-path shared-core/Cargo.toml --features uniffi-bindings` — 46 tests passed (44 unit tests and 2 integration tests), including two-device offline/online replay through an opaque relay, key-version rotation and recovery, local-workspace rekey retry, uncertain-ack retry, duplicate/out-of-order delivery, tombstones, zero-clock and unsupported-schema rejection, malformed encrypted-field rejection, base64url replay compatibility, legacy capture-payload compatibility, capture provenance replay, unknown capture-media field rejection, every platform privacy pause gate, immutable key-version conflict rejection, and atomic conflict rejection in the portable retry queue.
- `cargo clippy --manifest-path shared-core/Cargo.toml --all-targets --all-features -- -D warnings`
- `bash scripts/generate_dayflow_core_bindings.sh` — Swift and Kotlin UniFFI bindings regenerated from the current Rust API. `ktlint` is not installed, so only generation was performed.
- Fresh Rust release builds for `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios`, followed by a temporary current-source XCFramework package.
- Rebuilt `shared-core/dist/DayflowCore.xcframework` from the current provenance-aware Rust source; the prior generated artifact was preserved outside the repository before replacement.
- `swift build` for `arm64-apple-ios17.0` with the iOS SDK — passed.
- `swift build` for `arm64-apple-ios17.0-simulator` with the iOS Simulator SDK — passed.
- `xcodebuild -project clients/ios/DayflowMobile.xcodeproj -list` — passed;
  the installable `DayflowMobile` application product now uses the distinct
  `DayflowMobileApp` target/module and resolves the local `DayflowMobile`
  package without duplicate Swift output producers.
- After installing the iOS 26.4 simulator runtime with
  `xcodebuild -downloadPlatform iOS`, generic `iOS` and `iOS Simulator`
  application-target builds passed with code signing disabled. The package
  and installable application seams are now locally validated; device capture,
  signing, and TestFlight remain release gates.
- `swift test --package-path clients/ios` — 27 tests passed, including the
  local SQLite conflicting-event-ID guard and atomic conflicting-batch guard.
- Android native gate on this Mac: with the installed SDK selected through
  `ANDROID_HOME=/opt/homebrew/share/android-commandlinetools`, the Rust shared library built for
  `arm64-v8a`, `armeabi-v7a`, and `x86_64`; `gradle
  :app:assembleDebug :app:bundleRelease :app:testDebugUnitTest` passed with the
  generated Kotlin binding, the release AAB, and all three packaged ABIs; and
  `gradle :app:connectedDebugAndroidTest` passed its UniFFI seal/project/privacy
  smoke test on an API 36 arm64 emulator. The Android build now uses AGP 9's
  built-in Kotlin support and compiles against SDK 37 because the selected
  AndroidX dependencies require that API floor.
- iOS relay endpoint hardening: remote HTTP is rejected before any request is
  built, while HTTPS and loopback HTTP remain supported; the package test now
  covers this invariant (27 tests passed, including atomic conflicting-batch
  rejection in the local SQLite store).
- Android and Windows relay source clients now enforce the same HTTPS/loopback
  endpoint rule before opening a socket; native SDK compilation remains a host
  gate.
- Endpoint-policy parity now rejects credentials, query strings, and fragments
  in configured account, relay, and provider base URLs on Mac, iOS, Android,
  and Windows. Native default transports also disable redirects, cookies, and
  cache reuse before bearer-token or local-activity requests are sent.
- Apple relay clients now encode device identifiers with a strict unreserved
  URL character set so malformed relay data cannot escape a device route
  segment. The portable capture event test also asserts the exact metadata-only
  key set and the Mac payload test proves a local video path is omitted.
- `xcodebuild ... -only-testing:DayflowTests/DayflowMultiDeviceTests/testCaptureSyncNeverSendsRawMediaToRelay test` — passed; a fake
  `URLProtocol` inspected the actual Mac sync request after sealing a
  capture-derived card and found no local recording path, filename, screenshot
  marker, or raw media bytes in the network body. The production two-device
  network inspection gate remains open.
- Native Android and Windows transports disable automatic redirects, and the
  iOS account/sync/provider clients use a no-redirect URLSession by default so
  an accepted HTTPS endpoint cannot silently downgrade or change host.
- The optional Mac Dayflow Pro hosted provider now uses the same HTTPS/loopback
  endpoint validation, an ephemeral cookie-free URLSession, and fail-closed
  redirect handling; hosted AI remains explicitly user-selected and outside
  the encrypted sync relay's source-of-truth path.
- Mac relay cursors are now stored in the account-scoped SQLite sync metadata and
  are advanced only after the corresponding pulled envelope batch is merged.
- Relay wrapped-key approval is immutable per device and key version: exact
  retries remain idempotent, while replacement documents are rejected as
  conflicts; the Durable Object suite covers this guard.
- Native sync source hardening: Mac, iOS, Android/ChromeOS, and Windows now
  reject a wrapped account key whose embedded recipient does not match the
  local device or whose decrypted bytes differ from an already retained key
  version; sign-out stops the account-scoped capture session on each native
  shell.
- Cross-client journal identity hardening: Mac, iOS, Android/ChromeOS, and
  Windows now use the shared stable `mac:v1:journal:<day>` aggregate ID while
  retaining a fresh device-scoped envelope ID for every edit. The checked-in
  v1 envelope fixture is deserialized and round-tripped by the Rust core.
- Mac deletion hardening: single-card, day, batch, and range-replacement
  deletes now emit tombstones after successful transactions even when a card
  has no local video URL; failed transactions emit neither media cleanup nor a
  tombstone.
- Mac migration retry hardening: a durable event with a missing migration
  marker is reused on retry instead of being resealed with a new logical clock
  under the same immutable event ID.
- Mac sync fail-closed hardening: account-scoped event merge errors, including
  a conflicting immutable event ID or a missing account key, now propagate to
  the sync view model instead of being converted into a successful zero-event
  merge that could advance the cursor.
- Portable event conflict hardening: the Rust event log now rejects a different
  envelope for an existing immutable event ID, matching the native SQLite
  stores and relay behavior.
- Portable retry-queue hardening: duplicate envelopes remain idempotent, while
  conflicting event IDs fail closed and a conflicting batch leaves the queue
  unchanged.
- Portable envelope-shape hardening: the Rust core and opaque relay now require
  base64-decodable fields, a 24-byte XChaCha nonce, and at least a 16-byte
  authentication tag before an envelope can enter local replay or relay
  storage. The relay still never decrypts or inspects plaintext.
- Plaintext projection-cache removal: Mac, Android, iOS, and Windows now
  rebuild projections from encrypted local envelopes instead of reading a
  second plaintext sync cache. The Mac schema retains its legacy cache table
  only for rollback compatibility and never reads or deletes it across account
  boundaries; iOS removes its legacy cache on open and the Android/Windows
  stores never create one.
- Capture lifecycle hardening: Android persists a five-second status heartbeat,
  Windows forwards at most one derived metadata sample per minute, and iOS
  bounds ReplayKit sample-handler work before applying its one-minute event
  throttle.
- Mac capture-source hardening: the settings surface now persists active-display,
  specific-display, application, or window selection; the recorder resolves the
  selection through a fresh ScreenCaptureKit snapshot, uses the matching
  `SCContentFilter`, refuses stale sources instead of silently falling back, and
  re-evaluates selected application/window privacy titles before persistence.
  The native scheme build and capture-source preference round-trip test passed;
  interactive TCC/source behavior still requires a manual Mac capture session.
- Android capture status now requires an enabled notification channel before
  requesting MediaProjection consent; Windows source lifecycle now handles
  selected-source close, session lock, suspend/resume, and foreground process /
  title context before privacy evaluation. These remain target-device gates.
- Native capture session concurrency hardening: Windows now ignores repeated
  picker starts and invalidates late picker results after Stop/privacy/lifecycle
  transitions; Android keeps the UI in `STARTING` until the foreground service
  has attached the MediaProjection token, rejects duplicate consent flows, and
  ignores a consent result that arrives after Stop; iOS guards ReplayKit
  against overlapping starts, ignores redundant stops, and drops stale frame
  or stop callbacks from an older session generation.
  Windows' free-threaded Direct3D frame pipeline also snapshots frames before
  invoking privacy callbacks and refuses resize/recreate work for a closed or
  replaced frame pool.
  The iOS package tests (27) and portable Rust tests (45) pass after this
  change; Windows and Android target-host compilation/device behavior remain
  release gates.
- Native capture setup now requires a locally retained account key before the
  capture action is offered; Android reports local event-queue failures instead
  of leaving a running capture session that silently produces no timeline event.
- Windows capture now carries the privacy-approved foreground identity into
  local derivation, recreates its Direct3D frame pool after a source resize,
  and refreshes the local projection immediately after a queued sample.
- Android/ChromeOS capture now listens for display and configuration changes,
  handles `MediaProjection.Callback.onCapturedContentResize()` for app-window
  projection, resizes the virtual display, and replaces the ImageReader surface
  on the capture thread so Chromebook window resizing does not keep a stale
  frame buffer. Native resize behavior remains a target-device gate.
- Android refreshes the in-memory projection while the app is foregrounded so
  locally queued capture cards become visible without waiting for relay sync.
- Native clients now attempt one guarded encrypted sync when returning to the
  foreground: Mac observes Dayflow account activation, Android uses
  `onResume`, iOS uses `scenePhase`, and Windows uses WinUI window activation.
  Signed-out or partially configured clients remain local-only, and an
  in-flight sync cannot be duplicated. Target-device lifecycle validation is
  still open.
- Android sync now closes its SQLite helper in a `finally` block, including
  authentication, key-admission, relay, and projection failures; a failed
  foreground retry cannot leave the account database open until process exit.
- Android and Windows local outbox enqueue now keep immutable-event conflict
  preflight and insertion in one SQLite transaction. Capture, journal, and
  foreground sync writers cannot race past the conflict check and silently
  discard a different envelope with the same event ID; the native contract
  guard checks these seams without requiring the target SDKs.
- iOS local outbox enqueue now uses `BEGIN IMMEDIATE` around immutable-event
  conflict preflight and insertion as well, covering separate SQLite store
  instances opened by capture, journal, and foreground sync. The iOS package
  test verifies that a conflicting enqueue rolls back cleanly and the next
  valid event can still be written.
- Envelope validation is now consistent across the Mac, iOS, Android/ChromeOS,
  and Windows local stores: IDs, positive logical clocks, JSON-relay-safe clock
  range, schema version, key version, nonce, and ciphertext are checked before
  persistence. The iOS package test covers unsupported schema, missing key
  version, and clock-overflow inputs; the shared Rust core also rejects an
  unsupported schema before ingest.
- The portable Rust event log now fails with an explicit logical-clock
  exhaustion error instead of saturating at the JSON-safe maximum; no envelope
  is sealed or ingested outside the relay's precise integer range.
- The iOS application target no longer hard-codes `SDKROOT = iphoneos`; Xcode
  now selects the device or simulator SDK from the requested destination. After
  installing the iOS 26.4 runtime, generic device and simulator application
  builds passed locally; physical-device signing and capture remain explicit
  release gates.
- The native-client workflow now builds the installable iOS application target
  for both `generic/platform=iOS` and `generic/platform=iOS Simulator`, in
  addition to the package device/simulator builds.
- Windows local outbox enqueue and merge now reject incomplete envelopes,
  zero key versions, and logical clocks outside the JSON relay's safe range before
  entering the atomic transaction; the native contract guard covers this
  target-host validation seam.
- The macOS shared-core XCFramework builder now enables the `uniffi` feature
  while compiling both Apple architectures, keeping the packaged Rust symbols
  aligned with the generated native binding contract used by the client family.
- iOS ReplayKit callbacks now capture only a sendable frame-rate gate outside
  `MainActor`; session state and privacy decisions remain on the main actor.
  Android capture-service privacy JSON and account identity are volatile across
  the main and frame threads, preventing a stale update from being mistaken for
  a synchronized capture decision.
- Mac first-class edits now emit sealed `PriorityUpsert` and
  `ReflectionUpsert` events after successful daily/journal writes; the Rust
  projection and Mac GRDB importer expose those records to local views and
  chat context, including tombstones for removed priorities or cleared
  reflections.
- Mac migration now includes existing daily standup snapshots and task
  priorities. The importer applies encrypted `daily_standup:<day>` settings to
  the legacy standup read model without calling the public save path, so replay
  cannot generate an event echo.
- Mac priority IDs use the cross-client `dayflow:v1:priority:<uuid>` contract;
  legacy Mac priority IDs are recognized when cleaning up older local edits.
- Native projection models now retain complete timeline cards, journal entries,
  priorities, reflections, settings, and chat context on iOS, Android/ChromeOS,
  and Windows. Those clients can also author priority, reflection, and shared
  setting events locally; pending encrypted outbox counts are shown as
  local-only status rather than implying server sync.
- Native projection surfaces now expose deletion actions for timeline cards,
  journal entries, priorities, and reflections. Each action appends an encrypted
  tombstone and immediately rebuilds the local projection, so delete behavior
  is an event operation on Android/ChromeOS, iOS, Windows, and Mac rather than
  a client-only disappearance.
- Native clients now create a `local-workspace-v1` before account setup. Local
  journal, priority, reflection, setting, deletion, and capture-derived writes
  rebuild projections offline; account linking copies immutable envelopes into
  the account outbox and rekeys whenever destination key bytes differ, even if
  both source and destination rings use key version 1. Deterministic rekeyed
  duplicates are accepted after an interrupted copy; unrelated same-ID
  conflicts fail closed. The local source ciphertext and key ring remain
  untouched because SQLite and the platform secure store cannot commit
  atomically; an already-authenticated account copy is compared by decrypted
  projection after later account-key rotation, so signed-out/local projection
  remains readable through crashes and retries.
  The Android, iOS, and Windows shells restore this local projection after
  sign-out instead of presenting an empty disconnected state.
- The Mac now follows the same signed-out workspace contract: Keychain-backed
  local key material is created on demand, live GRDB writes seal into the local
  outbox, and account admission copies/rekeys those envelopes without mutating
  the source mirror. The Mac C ABI bridge and regression test cover re-keying a
  journal envelope while preserving event identity and decrypted projection.
- Mac, Windows, Android/ChromeOS, and iOS now consume the relay's content-free
  notification-hint cursor independently from encrypted event replay. Hint
  failures are advisory and do not turn a successful event sync into an error.
- Native shared-setting authoring is restricted to non-secret Dayflow keys
  (including the cross-device capture-pause preference); provider routes and
  API keys remain in platform secure storage and are not exposed to the event
  writer UI.
- Pending native device registration remains an explicit waiting state until
  an already-approved device delivers the wrapped account key; it no longer
  reports a missing-key error as a generic sync failure.
- Capture-derived events now carry optional encrypted `source` and
  `derivation_mode` provenance. Android/iOS/Windows writers emit truthful
  privacy-gated metadata labels, the Rust projection preserves them, and local
  chat context includes the provenance; legacy payloads default both fields to
  empty and still replay.
- Mac capture now supplies the frontmost application and window title to the
  shared privacy decision before a screenshot can be persisted. Conservative
  title rules cover private browsing, meeting windows, protected playback, and
  sensitive-code/password windows; blocked applications still produce a
  redacted placeholder rather than raw content. The Mac test suite covers these
  signal decisions without opening the user's database.
- Mac migration now includes persisted day-goal plans, including days with no
  timeline activity, as stable `day_goal:<day>` setting events. The Mac test
  suite verifies the portable day-goal snapshot contract.
- The relay now authorizes account-key creation only for the first non-recovery
  device and persists that device-bound bootstrap grant for crash-safe
  registration retries. The grant is consumed after the first accepted
  encrypted event, preventing a later local-key loss from authorizing a
  replacement key. Recovery registrations and later devices return
  `key_bootstrap_required: false`; Android, Windows, and iOS fail closed unless
  a wrapped key or recovery kit is available. All native shells also reject a
  pre-existing local account key when it has neither that admission grant nor a
  wrapped-key/recovery path, preventing an older client from silently forking
  an account. Mac consumes the same explicit admission signal and generates its
  first key only after the relay grants bootstrap.
- The shared setting allowlist now includes encrypted
  `daily_standup:<yyyy-mm-dd>` snapshots on Android, Windows, and iOS, matching
  the Mac migration and the v1 core contract. The Mac account client now
  rejects non-HTTPS/non-loopback service URLs and refuses HTTP redirects.
- The Mac event writer now trims shared setting keys and values before sealing
  them and rejects malformed `dayflow.capture.paused` values, matching the
  fail-closed validation already used by Android, Windows, and iOS. The Mac
  regression test covers normalization, secret-key rejection, and the invalid
  pause value; the native contract guard requires both the implementation and
  test to remain present.
- The shared Rust event boundary now validates the same v1 setting namespace
  during local append, FFI/UniFFI sealing, remote ingest, and workspace re-key.
  Unknown or secret keys, malformed ISO dates, and non-boolean capture-pause
  values are rejected before ciphertext is persisted or emitted. Rust unit
  and C-ABI tests cover rejection and confirm an invalid setting does not
  advance the local logical clock.
- Mac Settings now exposes the same encrypted `dayflow.capture.paused` control
  consumed by every native client. Toggling “Pause across devices” appends the
  setting to the local/account outbox, replays the local projection immediately,
  and notifies ScreenCaptureKit capture without waiting for a relay round trip.
- The Mac projection importer now has a copied-database GRDB equivalence test
  covering timeline, journal, daily standup, priority, reflection, settings,
  and local chat context. It uses SQLite's online backup API and verifies that
  replaying the copy does not mutate the source database.
- `scripts/verify_dayflow_real_database_migration.sh` — passed against the
  developer Mac's existing SQLite database. The harness copied the live DB via
  SQLite's online backup API, migrated 14 representative records (timeline,
  journal, and day-goal data) into an isolated temporary store, verified the
  encrypted event count and migration markers, retried idempotently, and
  confirmed the source row counts were unchanged. The normal scheme cannot
  enable this check through an arbitrary `xcodebuild` environment variable, so
  the script runs the already-built test bundle directly and keeps the real-DB
  check explicitly opt-in.
- `xcodebuild -project Dayflow/Dayflow.xcodeproj -scheme Dayflow ... test` — 131 tests passed without UI automation, including the capture-source preference/privacy tests, intercepted raw-media network-boundary test, and native encrypted-envelope shape gate. The local invocation used `CODE_SIGNING_ALLOWED=NO` because this development Mac has no matching Mac Development certificate; the opt-in real-database test is skipped unless run through its dedicated script.
- `bash scripts/verify_dayflow_test_scheme.sh` — passed; the normal scheme has
  only unit tests and the project contains no UI-test target or scheme. This
  prevents XCTest desktop control, repeated launch metrics, and the macOS
  AutomationMode overlay from being started through Dayflow.
- `bash scripts/verify_dayflow_native_contracts.sh` — passed; generated Swift
  bindings, Kotlin/C ABI seams, native-library guards, Android deny-by-default
  network security with loopback-only cleartext exceptions, Windows packaging
  mode, shared Mac capture-pause authoring, and the native-client CI workflow are internally consistent. The
  Android workflow pins the SDK platform using the valid `platforms;android-37`
  package path rather than a dotted API-level path.
- Native client CI pins Gradle 9.5.0 for the checked-in AGP 9.3.x project and
  builds the installable iOS application target alongside its package; hosted
  Android/iOS/Windows builds remain unobserved from this Mac checkout. The
  Android job now also provisions an x86_64 emulator for the generated UniFFI
  smoke test, and the Windows job runs its C-ABI smoke-test project.
- Latest local rerun: shared-core 45 tests and clippy passed, iOS package 27
  tests passed, the Mac `Dayflow` scheme passed all 131 unit tests, Android
  assemble/JVM/AAB tasks and its API 36 emulator smoke test passed, all three
  workflow YAML files parsed, and the relay suite's 11 tests plus Wrangler
  dry-run passed. The native activation-sync contract was included in the
  latest contract check; Android's numeric relay logical-clock decode and
  tombstone-authoring seams are covered in source, while Windows hosted SDK,
  Android/ChromeOS Play and real-device capture gates remain unobserved from
  this Mac.
- Final source audit: local-workspace linking keeps the source mirror and
  secure-store key unchanged across crashes, accepts an already-authenticated
  destination envelope after key rotation only when decrypted projections
  match, restores local projections for signed-in devices still waiting for
  approval, and carries the source device clock into the account outbox before
  allocating another event. The iOS package, native contract guard, relay
  checks, and diff checks passed after this audit.
- Windows unpackaged-shell storage hardening: the WinUI 3 client no longer
  depends on package-identity `ApplicationData.Current`; key, sync, and
  recovery-pending state use the per-user Local AppData path and DPAPI-backed
  storage instead. The native contract guard now prevents this regression.
- Windows C ABI and relay-signing hardening: every JSON-returning Rust boundary
  now rejects the shared core's `{ "error": ... }` response before the shell
  can treat it as a recovery kit, key material, envelope, projection, or
  signature. Canonical relay timestamps are formatted with invariant decimal
  ASCII text for both the signed message and request header; the native contract
  guard prevents regressions in both seams.
- Windows packaging path: the default unpackaged WinUI 3 project now switches
  to single-project MSIX when `DayflowPackaging=true`, with x64/x86/ARM64
  publish profiles, an unsigned package manifest, and a hosted workflow step
  that verifies an `.msix` artifact. A Windows host is still required to
  execute the package build, install/upgrade tests, signing, and capture UX.
- Android release artifact path: the native-client workflow now runs
  `:app:bundleRelease` and requires `app-release.aab` in addition to the debug
  and JVM-test tasks, then uploads the bundle for review. The current Mac
  session now reruns the Rust ABI build plus the debug APK, release AAB, and
  JVM-test tasks successfully; Play upload and target-device installation
  remain separate gates.
- Android capture restart hardening: persisted `RUNNING`, `STARTING`, and
  consent states now require a fresh service heartbeat; stale state becomes an
  explicit stopped status after service/process death, and the Android JVM test
  covers the boundary. The current Mac Gradle test passes; MediaProjection
  lifecycle and Chromebook behavior remain target-device gates.

## Current environment recheck (2026-08-02)

- Account-key admission continuity: Mac, Android/ChromeOS, Windows, and iOS
  now persist an account-scoped secure-store admission marker after relay
  bootstrap, validated wrapped-key delivery, or recovery restore. This fixes
  the legitimate first-device restart case where the relay has consumed its
  one-time bootstrap grant and correctly returns no wrapped key for that same
  device. A legacy local key ring without an admission marker still fails
  closed until it receives a wrapped key or completes recovery.
- Post-fix local validation: `bash scripts/verify_dayflow_native_contracts.sh`,
  `git diff --check`, `swift test --package-path clients/ios` (27 tests),
  `cargo test --manifest-path shared-core/Cargo.toml --all-features` (44
  tests), and the Mac `xcodebuild ... test` (131 tests) all passed.
- Mac local-store reads now have throwing forms for pending events, complete
  event replay, and immutable migration lookups. Sync, projection rebuild,
  local-workspace linking, and migration retries use those forms so a database
  or malformed-row failure cannot be converted into an empty event stream and
  treated as a successful sync. The compatibility read helpers remain
  non-throwing only for non-critical status/UI callers; the Mac scheme still
  passes all 131 unit tests after this change.
- Windows session validation now applies the same shared endpoint policy as the
  transport before persisting or reconnecting a session, rejecting relay URLs
  with credentials, query strings, or fragments instead of failing later during
  the first sync request. A Windows-host MSTest regression covers the accepted
  HTTPS/loopback cases and these rejected forms; this Mac has no .NET/Windows
  SDK, so the test remains a target-host gate.
- The portable capture replay test now also asserts that the replayed timeline
  card is present in deterministic local `chat_context`, including its title
  and derivation provenance. This closes the capture → encrypted replay →
  timeline/chat acceptance seam without moving any raw media into the event.
- Native Gemini chat requests now send the API key in `x-goog-api-key` instead
  of putting it in the URL query string on Android/ChromeOS, iOS, and Windows.
  The source guard requires the header and rejects the old query construction;
  the local provider route and relay never receive that secret.
- Post-change native checks: `swift test --package-path clients/ios` passed all
  27 tests, `gradle :app:testDebugUnitTest` passed, and the native-contract
  guard passed again. Windows compilation remains a Windows-host gate.
- Mac event writes now fail closed if account identity and account scope diverge
  during sign-out; they cannot crash on a force-unwrapped scope or fall back to
  the signed-out workspace while an account identity is still present.
- Account-scoped writes on Mac, Android/ChromeOS, iOS, and Windows now require
  the local `account-key-admitted-v1` marker in addition to a stored key-ring.
  A signed-in but pending device continues in its local workspace, while an
  admitted device can author account events; this prevents legacy/restored
  key material from creating an account outbox the relay must later reject.
- Android capture now asks the same admitted-workspace selector used by local
  journal/timeline writes for its service account ID. A pending signed-in
  device therefore captures into `local-workspace-v1` instead of accidentally
  sending an unadmitted account scope to the foreground service.
- Android foreground refresh, pending counts, and provider settings now use
  that same effective workspace, so a pending device cannot display or save
  state under an unadmitted account scope while its capture remains local.
- iOS provider loading/saving now follows the same effective workspace during
  approval waits, then switches to the account workspace only after admission;
  the pending-device UI cannot mix local projections with account-scoped
  provider state.
- The Android capture service repeats the admission check immediately before
  queuing a derived sample, making the service itself resilient to stale UI
  intents during sign-out or approval changes; it also requires the service
  account to match the durable active session, so a late callback after sign-out
  falls back to the local workspace.
- The Android, iOS, and Windows capture-enqueue APIs now repeat the same
  admission decision internally, so direct or stale callers cannot create an
  account-scoped capture event before approval.
- The opaque relay now accepts approved-device push-token registration and
  removal through the signed notification route, removes tokens on device
  revocation, and emits only content-free wake jobs to an optional
  `DAYFLOW_PUSH_DISPATCHER` service binding. Relay event sync remains successful
  when that provider binding is absent or unavailable; native clients expose
  matching registration transports and keep foreground hint polling as the
  fallback.
- Final host-available verification after the admission-boundary correction:
  shared Rust formatting, 45 Rust tests, and clippy passed; the relay check
  passed with 5 files and 11 tests; native-contract, product-surface, and
  test-scheme guards passed; Android debug APK/release AAB/JVM tests passed;
  iOS passed all 27 package tests; and the normal Mac scheme passed its 131
  unit tests. Windows compilation and OS push-provider delivery remain target
  host/credential gates, while current native clients continue to use the
  relay's content-free notification hints on foreground activation.
- Final normal Mac scheme rerun after these changes: `xcodebuild -quiet
  -project Dayflow/Dayflow.xcodeproj -scheme Dayflow -destination
  'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY='' test` exited
  successfully. `xcodebuild -list` still exposes only the `Dayflow` and
  `MarkdownUI` schemes, and no `xcodebuild`/`xctest` process remained after
  completion; the two observed `AutomationMode` processes remain pre-existing
  external system state from the earlier UI automation incident.
- Current local Android recheck: with `ANDROID_HOME=/opt/homebrew/share/android-commandlinetools`,
  `:app:assembleDebug`, `:app:bundleRelease`, and `:app:testDebugUnitTest`
  passed. `:app:connectedDebugAndroidTest` was not executed because this
  shell had no connected device; the earlier API 36 arm64 emulator result
  remains recorded above.
- Mac Gemini provider hardening: text, activity-card, transcription, dashboard,
  upload, file-status, onboarding test-connection, and Gemma fallback requests
  now carry the API key in the `x-goog-api-key` header instead of a URL query.
  The Mac unit suite covers the request seam, and the native contract guard
  rejects `?key=` in the first-party Dayflow sources.
- iOS push-wake product path: the SwiftUI application now registers APNs
  tokens only after account-key admission, unregisters the token on sign-out,
  and accepts only the content-free `kind: sync_available` remote-notification
  payload before awaiting the normal encrypted sync. Generic iOS Simulator
  application build passed; APNs entitlements, dispatcher credentials, and
  physical background delivery remain release gates.
- Android/ChromeOS push-wake product path: the native client now accepts only
  the explicit `app.dayflow.android.action.SYNC_WAKE` plus
  `kind=sync_available`, schedules a network-aware `JobService`, and runs the
  same guarded encrypted cursor sync without consuming notification content.
  `gradle :app:assembleDebug :app:bundleRelease :app:testDebugUnitTest`
  passed after this path was added. FCM token delivery, provider credentials,
  and physical background execution remain release gates.
- Windows push-wake product path: the WinUI client now requests a WNS channel
  after account-key admission, registers the channel URI through the signed
  relay route, unregisters it during sign-out, and routes only the exact
  one-field `{"kind":"sync_available"}` raw signal into the coalesced
  encrypted sync. The C# contract test covers content-bearing and malformed
  payload rejection. Windows SDK compilation, package identity, WNS
  credentials, and background delivery remain target-host/release gates.
- Android local recheck: with the installed JDK 21, Android SDK/Build Tools 37,
  NDK 27.2.12479018, and Rust Android targets, `bash
  scripts/build_dayflow_core_android.sh` succeeded and
  `gradle :app:assembleDebug :app:bundleRelease :app:testDebugUnitTest`
  completed successfully. The resulting debug APK and release AAB were
  produced locally. A new API 36 arm64 `dayflow-api36` AVD also ran
  `gradle :app:connectedDebugAndroidTest` successfully (three instrumentation
  tests); physical Android/Chromebook install, MediaProjection consent, resize,
  and multi-window behavior remain target-device gates.
- Android shared privacy wiring: the decrypted projected
  `dayflow.capture.paused` setting now reaches the MediaProjection controller
  and active service, including settings arriving from another device after
  sync. An invalid pause value fails closed, and the Android JVM test covers
  pause, resume, and malformed-value handling. The compile and JVM test tasks
  pass locally; Android lock/DRM/private-window signals and physical capture
  behavior remain target-device gates.
- Admission-routing recheck: the Android debug APK, release AAB, JVM tests,
  and native-contract guard pass after routing capture, projection refresh,
  pending counts, provider settings, and the foreground service through the
  effective admitted workspace. The development Mac still has only the two
  pre-existing `AutomationMode` system processes; no Xcode build/test process
  is active.
- Android lock/sleep lifecycle hardening: the foreground service now refuses
  to start while the device is non-interactive or keyguard-locked, registers
  screen-off and shutdown receivers, and transitions capture to an explicit
  privacy-paused state without auto-resuming. The new lifecycle assertions,
  full debug APK/release AAB/JVM build, and API 36 arm64 emulator
  instrumentation pass locally; physical lock, sleep, permission-revocation,
  and MediaProjection behavior remain target-device gates.
- Android secure-store durability: account/device/recovery admission state now
  uses checked synchronous commits for key material, recovery markers, and the
  physical device identity before sync can proceed. An API 36 instrumentation
  test reads back a committed Keystore-backed value immediately and verifies
  that separate sync-session instances retain one device identity.
- Windows secure-store durability: DPAPI-protected key writes now use a
  write-through temporary file, an explicit disk flush, and an atomic replace;
  the native contract guard and a Windows-host DPAPI round-trip test protect
  the seam. Windows execution remains a host gate because this Mac has no
  WinUI/.NET Windows SDK toolchain.
- Cross-client shared capture pause wiring: Mac projection import and recorder,
  Windows projection and capture adapter, Android projection/service, and iOS
  SwiftUI projection and ReplayKit session now consume the same decrypted
  `dayflow.capture.paused` setting. Missing/`false` clears the pause, `true`
  pauses capture, malformed values fail closed, and clearing never starts a
  session automatically. Mac, Android, and iOS tests/builds pass locally;
  Windows compilation and target-device lifecycle validation remain open.
- Native contract guard expansion: `verify_dayflow_native_contracts.sh` now
  protects the Android synchronous secure-store and device-identity seams,
  Android lock/sleep/shutdown tests, and the shared capture-pause plumbing and
  fail-closed tests on all four native clients, plus the relay rule that rejects
  recovery admission while an approved device remains. The expanded guard,
  product surface guard, test-scheme guard, and `git diff --check` pass.
- Apple package artifacts: the native-client workflow now archives the Mac app
  into an unsigned DMG and archives the full iOS `.xcarchive` into a zip for
  review/export. Signing, notarization, TestFlight export, and install-on-device
  validation remain intentionally separate release gates.
- Xcode scheme XML validation and `git diff --check` — passed.

The repository now includes `.github/workflows/dayflow-core.yml` for the
non-Apple feasibility gate. Its hosted Linux run has not been observed from
this local macOS session, so CI execution remains an explicit evidence gate.
The repository also includes `.github/workflows/dayflow-native-clients.yml`
with hosted macOS, iOS, Android/ChromeOS, and Windows build jobs; none of those
hosted jobs has been observed from this local session yet.

## Passed for the encrypted relay

- `npm run types` — Wrangler generated the local type contract for
  `ACCOUNT_RELAY` and `DAYFLOW_AUTH`.
- `npm run check` in `companion-web/workers/api` — 5 test files and 11 tests passed, including the canonical `/v1/me` auth-binding boundary, the no-body-forwarding assertion, and recovery-admission enforcement.
- `npx wrangler deploy --dry-run` — upload/binding validation passed; no deploy
  or credential mutation was performed.
- `bash scripts/verify_dayflow_product_surfaces.sh` — deprecated browser/Tauri
  markers are present, the relay boundary is documented, and no new web source
  exists outside the preserved `apps/web/dist/` migration artifact; the
  historical Tauri bundle is disabled. The same guard is wired to the
  lightweight `dayflow-product-surfaces` workflow for changes limited to these
  retired paths.
- Relay coverage includes direct Durable Object behavior and the HTTP boundary:
  account authentication, device signatures, nonce replay rejection, opaque
  event return, first-device approval and key-bootstrap admission,
  pending-device gating, recovery admission rejection while an approved device
  remains, key versions, cursor pull, idempotent push, and conflicting event-ID
  rejection.

## Still requires target hosts/devices

- Windows: .NET/Windows App SDK restore, WinUI build/package, MSIX install and
  upgrade, signing, and `Windows.Graphics.Capture` picker/border/sleep/
  multi-monitor tests require a Windows 11 host. The architecture-specific Rust
  DLL build/copy seam and conditional single-project MSIX workflow are explicit
  in the repository, but neither the package nor the capture lifecycle has been
  executed on a Windows host here.
- Android/ChromeOS: the Android SDK, Gradle, NDK, debug APK, JVM tests, and
  generated UniFFI smoke test now pass locally on an Android emulator. Play
  packaging, a physical Android device, MediaProjection consent/stop/revocation
  behavior, and Chromebook resize/multi-window tests remain open. The Gradle
  `preBuild` guard requires all three ABI-specific Rust libraries produced by
  `scripts/build_dayflow_core_android.sh`.
- iOS: package and generic device/simulator application-target builds pass;
  TestFlight packaging, signing, ReplayKit lifecycle, background/termination
  behavior, and physical-device capture tests remain open.
- Cross-device production readiness: canonical `DAYFLOW_AUTH` deployment,
  two-device network inspection proving raw media never leaves its source,
  native secure-store recovery, and battery/CPU/storage benchmarks remain
  release gates.

## Automation isolation

The shared `Dayflow` scheme contains only `DayflowTests`; the project no longer
contains a UI-test target or scheme. The old UI suite included a repeated launch
performance metric and a per-configuration launch test, which could start five
or more app instances and leave macOS `AutomationMode` active after failure.
The latest normal-scheme rerun passed 133 unit tests, showed no active
`xcodebuild` or `xctest`, and did not create new AutomationMode processes. The
only AutomationMode processes observed afterward were pre-existing system
state from the earlier automation session. Any overlay that remains on a
development Mac is external machine state and must be cleared with the system
shortcut or a reboot.

## Latest safe setup preflight

- `bash scripts/verify_dayflow_setup.sh` stops at the actual host gate: an
  external root `AutomationMode` writer is still active. It does not invoke
  Xcode project evaluation, open Dayflow, or start automation. The developer
  directory, Xcode first-launch/license state, single-instance plist setting,
  non-interactive test scheme, native product boundaries, native client
  contracts, disabled legacy autostart, and absence of Dayflow or retired
  companion runtimes are checked before that stop.
- `bash scripts/verify_dayflow_setup.sh --run-tests` uses the same safe process
  guard and then runs the host-available Rust, iOS package, Android JVM, and
  opaque relay suites when their prerequisites are present. `--evaluate-project`
  is a separate opt-in diagnostic because this Xcode host aborts in its
  CoreDevice plug-in during `xcodebuild -list` even though the license check
  passes; it is not part of the manual setup path.
- The current preflight stops before later prerequisite warnings because the
  external `AutomationMode` writer is a hard safety failure. Direct host
  validation found the Android SDK at
  `/opt/homebrew/share/android-commandlinetools`, and the Android JVM suite
  passes against it. The remaining blocker is machine-level AutomationMode,
  which is cleared with Control-Option-Command-Period or a restart.

## Native readiness implementation on Linux Cloud Agent — 2026-08-05

- `bash scripts/verify_dayflow_native_contracts.sh` passes after adding the
  Android product routes, bounded local visual derivation, Windows product
  routes, Windows privacy preferences/classification, release identity guards,
  and the target-host acceptance checklist.
- `./clients/android/gradlew` bootstraps the pinned Gradle 9.6.1 distribution.
  Android unit tests could not run in this Linux checkout because no Android
  SDK is installed; no `local.properties` or machine-specific SDK path was
  created.
- Windows WinUI/MSIX build and capture tests could not run because .NET and the
  Windows SDK are unavailable on Linux. The physical Windows and Chromebook
  acceptance matrix is recorded in
  `docs/multi-device/NATIVE_CLIENT_ACCEPTANCE_CHECKLIST.md`.
- `cargo test --workspace` could not run with the installed Cargo 1.83 because
  the resolved dependency set requires the stabilized `edition2024` feature;
  the hosted Rust workflow remains the authoritative compatible toolchain.
