# Deprecated product path

`adhd-companion/` is a historical Tauri prototype, not a second Dayflow
product. The unified platform work is moving capture, timeline, journal, chat,
account, and device sync into native Dayflow clients:

- Mac: the existing SwiftUI/AppKit application;
- Windows: WinUI 3 + C#;
- Android and ChromeOS: Kotlin + Jetpack Compose;
- iOS: SwiftUI.

Do not add user-facing features, browser pairing, a loopback bridge, or a new
server-owned state model here. Keep the prototype available only as a source
reference while the native clients reach parity. Migration work belongs in
`docs/multi-device/` and the encrypted relay source belongs in
`companion-web/workers/api/src/`.

The `dev`, `preview`, and `tauri` runtime entrypoints intentionally fail closed
so a stale automation or login item cannot reopen this prototype. Source
inspection, typechecking, build, and test commands remain available for
migration work.
