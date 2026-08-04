# Native Dayflow clients

The native clients share the Rust event/privacy/encryption core in
`shared-core/` and use the encrypted relay contract in
`docs/multi-device/SYNC_PROTOCOL.md`.

| Client | Shell | Capture consent boundary | Local-first status |
| --- | --- | --- | --- |
| macOS | Existing SwiftUI/AppKit app | ScreenCaptureKit permissions and privacy gates | Existing product with Rust event, migration, and sync seams |
| Windows | WinUI 3 + C# | `GraphicsCapturePicker`, system capture border | Native shell, capture pipeline, DPAPI/SQLite sync session, signed relay, device admin, provider store, direct provider-backed chat, recovery UI, and local capture-event writer |
| Android/ChromeOS | Kotlin + Jetpack Compose | MediaProjection consent for every session | Native shell, foreground capture, Keystore/SQLite sync session, signed relay, device admin, provider store, direct provider-backed chat, recovery UI, and local capture-event writer |
| iOS | SwiftUI | ReplayKit where the OS permits an explicit session | Native shell, Keychain/SQLite sync session, signed relay, device admin, provider store, direct provider-backed chat, recovery UI, capture-event writer, and privacy gate |

The Windows and Android build toolchains are not installed on this Mac, so
their source is validated by contract review only in this checkout. Run the
platform commands in each client README on the corresponding host.
The repository contains `.github/workflows/dayflow-native-clients.yml` to make
those host-specific build gates repeatable in CI; a hosted run is still needed
before claiming native release readiness.
Run `bash scripts/verify_dayflow_native_contracts.sh` on any host to catch
binding-copy, native-library, and workflow drift before invoking a platform
toolchain.

The non-Mac provider stores keep routing metadata and API secrets separate and
device-local. Chat builds a bounded prompt from the local projection and calls
the selected provider directly; the Dayflow relay is never used for inference.
The `enqueueCaptureDerived` seams accept only locally derived metadata, seal it
through Rust, and persist the opaque envelope in the local outbox. Each event
also carries a backward-compatible `source` and `derivation_mode` label so a
timeline card remains understandable after it arrives on another device. The
current Android/iOS/Windows capture adapters use privacy-gated metadata modes;
platform AI workers and target-device behavior still need native integration
validation.
All native relay clients require HTTPS in production and permit HTTP only for
loopback development endpoints.
