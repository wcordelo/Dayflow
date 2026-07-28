# ADHD Companion

Tauri v2 product + TypeScript engine (contract **v2.3**).

**Private beta / Mac next steps:** see [`docs/adhd-companion/BETA_READINESS.md`](../docs/adhd-companion/BETA_READINESS.md) — end-to-end playbook (what’s done vs what needs a Mac).

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

## Mac product run

```bash
npm run tauri dev
```

Native ScreenCaptureKit / NSPanel collection behaviors / real Keychain still finalize on Mac (`cfg(macos)` hooks + `M0_RUNBOOK.md`). Linux uses EventBus injectors + idle simulator; Rust-resident ticks run either way.

## Layout

- `src-tauri/` — DB, bus, capture, privacy, guards, orchestrator, pipeline, runtime loops, Gemini client, L1 notify + L2/L3 nudge windows, autostart
- `src/` — main UI; `nudge.tsx` dedicated L2/L3 surface
- `engine/` — TS mirror + vitest
- `prompts/`, `schema/`
