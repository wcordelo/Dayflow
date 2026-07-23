# AGENTS.md

## Cursor Cloud specific instructions

Dayflow is a **native macOS 14+ application** written in Swift (SwiftUI + AppKit),
built exclusively with **Xcode** via `Dayflow/Dayflow.xcodeproj`. There is no
`Package.swift`, no web/backend service, and no JS/Python tooling in this repo.

**This project cannot be built, tested, linted, or run on the Linux Cloud Agent VM.**
The reasons are fundamental, not fixable via dependency installation:

- The code depends on Apple's closed-source, macOS-only frameworks — `SwiftUI`,
  `AppKit`, `ScreenCaptureKit`, `AVFoundation`, `Combine`, `CoreGraphics`, and
  `Sparkle`. These do not exist in the open-source Swift toolchain for Linux.
- Building requires **Xcode**, which only runs on macOS.
- The `DayflowTests` target uses `@testable import Dayflow`, so even the XCTest
  suite requires the full macOS app module and cannot run on Linux.

Because of this, do **not** attempt to install a Swift toolchain, Xcode, or SPM
dependencies on the Linux VM — none of it will make the app buildable. The update
script is intentionally a no-op.

### How to actually build/run (macOS only)

Development must happen on a macOS 14+ machine with Xcode. See `README.md`
("Build From Source"): open `Dayflow/Dayflow.xcodeproj`, select the `Dayflow`
scheme, and run. Xcode/SPM resolves dependencies automatically from
`Dayflow/Dayflow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

To exercise the core flow (record → analyze → timeline/chat) you also need one AI
provider selected in Settings: a local server (Ollama on `:11434` or LM Studio on
`:1234`), a Gemini API key, or the Codex/Claude CLIs. Local SQLite storage lives
at `~/Library/Application Support/Dayflow/` and is created automatically.
