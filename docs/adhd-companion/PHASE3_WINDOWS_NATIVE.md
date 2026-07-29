# Phase 3 — Windows native companion (parked)

Not on the private-beta critical path (ChromeOS cannot run Tauri for typical users).

When revisited (PLATFORM-RETHINK §9):

- Wire `wineventhook` + `windows-capture` into `adhd-companion/src-tauri`
- Always-on-top L2/L3 (no Spaces problem on Windows)
- `secrets.rs` → Windows Credential Manager
- Sync via same cloud `CompanionStateDO` / user account
- Ship `.msi` via tauri-bundler

Until then: PWA + Web Push is the Windows delivery vehicle.
