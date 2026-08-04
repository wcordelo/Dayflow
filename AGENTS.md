# AGENTS.md

## Cursor Cloud specific instructions

Dayflow remains a **native macOS 14+ application** written in Swift (SwiftUI +
AppKit), built through `Dayflow/Dayflow.xcodeproj`, and is now the first client
in a unified multi-device product family. The repository also contains the
portable Rust core under `shared-core/`, an iOS Swift package/application under
`clients/ios/`, Android/ChromeOS and Windows native client sources, and the
Cloudflare encrypted relay source under `companion-web/workers/api/`. The old
browser/Tauri companion surfaces are migration material and are not user-facing
product paths.

The macOS application and Apple-native targets cannot be built, tested, linted,
or run on the Linux Cloud Agent VM. The reasons are fundamental, not fixable via
dependency installation:

- The code depends on Apple's closed-source, macOS-only frameworks — `SwiftUI`,
  `AppKit`, `ScreenCaptureKit`, `AVFoundation`, `Combine`, `CoreGraphics`, and
  `Sparkle`. These do not exist in the open-source Swift toolchain for Linux.
- Building requires **Xcode**, which only runs on macOS.
- The `DayflowTests` target uses `@testable import Dayflow`, so the macOS XCTest
  suite requires the full macOS app module and cannot run on Linux.

The portable Rust core and Cloudflare relay have separate Linux-compatible
checks. Android, Windows, and iOS packaging/device checks belong on their
respective hosted or physical target environments and are intentionally not
simulated by installing unrelated SDKs into a Linux VM.

Because of this, do **not** attempt to install Xcode, Apple SDKs, Android SDKs,
the Windows SDK, or SPM dependencies into a Linux VM merely to make an
out-of-host target buildable. Use the repository's portable checks locally and
the native-client workflow on the appropriate hosted runner. The update script
is intentionally a no-op.

### How to actually build/run (macOS only)

Development of the Mac app must happen on a macOS 14+ machine with Xcode. See
`README.md` ("Build From Source"): generate the shared Rust XCFramework, open
`Dayflow/Dayflow.xcodeproj`, select the `Dayflow` scheme, and run. Xcode/SPM
resolves the existing Mac dependencies automatically from
`Dayflow/Dayflow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

Portable validation is documented in `docs/multi-device/VALIDATION_LOG.md`.
Native-client commands and target-host gates are documented in
`docs/multi-device/DELIVERY_GATES.md` and
`.github/workflows/dayflow-native-clients.yml`.

To exercise the core flow (record → analyze → timeline/chat) you also need one AI
provider selected in Settings: a local server (Ollama on `:11434` or LM Studio on
`:1234`), a Gemini API key, or the Codex/Claude CLIs. Local SQLite storage lives
at `~/Library/Application Support/Dayflow/` and is created automatically.
