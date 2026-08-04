# Archived ADHD Companion prototype

This directory is a historical Tauri v2 prototype and TypeScript state-machine
reference. It is not a shippable Dayflow client or a second product surface.

The unified product is implemented by the native Dayflow clients:

- Mac: SwiftUI/AppKit
- Windows: WinUI 3 + C#
- Android and ChromeOS: Kotlin + Jetpack Compose
- iOS: SwiftUI

Do not launch this prototype as part of a Dayflow run, add user-facing features,
or build browser pairing, a loopback bridge, or server-owned state here. Current
platform work belongs in [`docs/multi-device/`](../docs/multi-device/), and
account/device sync belongs in the opaque relay at
[`companion-web/workers/api/`](../companion-web/workers/api/).

The `dev`, `preview`, and `tauri` commands are fail-closed by design. They do
not start a browser or desktop runtime; use the source/build/test commands below
only for migration review.

The historical readiness material remains available for migration review, but
it is no longer a private-beta launch plan.

## Test (Linux CI / this repo)

```bash
cd adhd-companion
npm install && npm install --prefix engine
npm test                 # engine vitest + all Rust tests (unit + e2e_pipeline)
npm run test:e2e         # capture→monitor→L1–L3→analyze→brief harness
npm run build            # Vite (main + nudge)
cargo check --manifest-path src-tauri/Cargo.toml
```

E2E does **not** require a window server: it exercises the Rust `Pipeline` end-to-end (privacy, debounce/hash dedupe, DRM pause/resume, sleep/wake, escalation, analyze, brief, secrets).

## Layout

- `src-tauri/` — DB, bus, capture, privacy, guards, orchestrator, pipeline, runtime loops, Gemini client, L1 notify + L2/L3 nudge windows, autostart
- `src/` — main UI; `nudge.tsx` dedicated L2/L3 surface
- `engine/` — TS mirror + vitest
- `prompts/`, `schema/`
