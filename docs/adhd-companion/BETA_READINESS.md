# Archived private-beta readiness — end-to-end playbook

> **Archived:** this playbook describes the retired Tauri companion prototype.
> It is retained for migration review only. Do not use it to launch a separate
> Dayflow product; use [`docs/multi-device/`](../multi-device/) for the current
> native-client delivery plan.

**Audience:** developers (Mac) + agents  
**Historical goal:** Private beta on a real Mac — installable, shame-sensitive, no Terminal.
**Historical product code:** `adhd-companion/` (Tauri v2)
**Binding decisions:** [IMPLEMENTATION_CONTRACT.md](./IMPLEMENTATION_CONTRACT.md) (v2.3)

This document is retained for migration review. The current delivery path is
the native-client plan under `docs/multi-device/`.

**Privacy:** Do not commit end-user names, emails, API keys, or machine identifiers. Use generic “beta user” language in docs and issues.

---

## What’s already done (Linux / agents)

You do **not** need to rebuild these from scratch:

- Orchestrator (idle → L1 → L2 → L3), cooldowns, circuit breaker  
- Privacy helpers (app/title blocklist, incognito, DRM pause)  
- SQLite schema, prompts, settings UI shell  
- Rust-resident tick / idle / analyze loops  
- Simulated E2E pipeline (`inject_capture_event`)  
- Gemini client + local fallback + key file / Keychain CLI attempt  
- Dedicated L2/L3 `nudge.html` UI  

**Prove on any machine:**

```bash
cd adhd-companion
npm install && npm install --prefix engine
npm test
npm run test:e2e
```

> Note: E2E can fail during quiet hours (22:00–07:00 local) until clocks are injectable — if it fails overnight, re-run daytime or disable quiet hours in the test settings.

---

## What’s left (mostly Mac)

These **cannot** be finished on the Linux Cloud Agent. They need a Mac (Xcode, Screen Recording TCC, Spaces, codesign).

| # | Work | Why beta needs it | Doc / code |
|---|---|---|---|
| 1 | **Real capture** (ScreenCaptureKit + app_switch / window_focus / idle) | Without this, no timeline and no nudges | `src-tauri/src/capture.rs` `native` module is a stub |
| 2 | **NSPanel L2/L3** over fullscreen Spaces | Contract M0-(b); plain `always_on_top` is not enough | `nudge_windows.rs` |
| 3 | **L1 notification → click → L2** | Point-of-performance loop | `nudge_windows.rs` + notification click handler |
| 4 | **Dev-signed `.app` + TCC** | Sequoia Screen Recording often fails unsigned | [M0_RUNBOOK.md](../../goal-outputs/adhd-companion-prep/M0_RUNBOOK.md) |
| 5 | **Fill M0_RESULTS** | Know go/no-go before beta install | [M0_RESULTS.template.md](./M0_RESULTS.template.md) → `M0_RESULTS.md` |
| 6 | **Per-user Gemini key in Keychain** (or ship local-only clearly) | No shared developer key; opt-in cloud | Settings + `secrets.rs` |
| 7 | **Morning check-in schedule + soft-confirm** | Priorities must exist for nudges | Settings `checkin_hour` stored; scheduler not finished |
| 8 | **Autostart actually enabled** | Survives reboot | Plugin registered; wire Settings → enable/disable |
| 9 | **Private beta on a tester Mac** | Real trust / false-nudge week | After (1)–(5) green enough |
| 10 | **Notarized DMG** (can wait) | Polished distribution | After week-1 trust |

---

## Path A — Developer on Mac (recommended)

### Day 0 — Boot the product

```bash
git checkout cursor/adhd-companion-plan-0f84   # or main once merged
cd adhd-companion
npm install
npm run tauri dev
```

- Xcode CLT / full Xcode installed  
- Apple Development cert in Keychain  
- Bundle ID: `com.adhdcompanion.app` (see `src-tauri/tauri.conf.json`)

### Day 1 — Capture + signing (M0 a, e)

Follow **[M0_RUNBOOK.md](../../goal-outputs/adhd-companion-prep/M0_RUNBOOK.md)** sections for (e) then (a):

1. Codesign the `.app` (dev identity, stable bundle ID)  
2. Grant **Screen Recording** to that app; relaunch  
3. Confirm capture survives relaunch (`CGPreflightScreenCaptureAccess`)  
4. Prefer Candidate **C** (event-driven stills); try A if C pills; B only as control  

**Wire code if still stubbed:** implement `capture::native` on macOS (ScreenCaptureKit one-shot JPEG + NSWorkspace notifications → `EventBus`). Agents can draft PRs; a developer must run/verify on Mac.

### Day 1–2 — Panels + notifications (M0 b, c)

1. L3 over YouTube/Netflix fullscreen on **another Space**  
2. L2 on all Spaces  
3. Notification click → L2 (or document L1 click→L2 fallback)  

Copy template → `docs/adhd-companion/M0_RESULTS.md` and fill pass/fail.

**Private-beta bar:** prefer **(a) ∧ (b) ∧ (e)** green. (c) non-fatal.

### Day 2 — Product loop polish

On the same signed build:

- [ ] Onboarding → Screen Recording prompt copy is calm and accurate  
- [ ] Morning priorities save; soft-confirm yesterday works  
- [ ] Pause nudges (capture continues) vs Pause watching (both stop) — obvious  
- [ ] Overwhelm → next 4 AM  
- [ ] Gemini: paste the **beta user’s** key only when ready; or leave opt-in off for week-1 local  
- [ ] Launch at login works after reboot  

### Day 3 — Private beta on a tester Mac

1. Install the signed `.app` (not notarized yet is OK for private beta)  
2. Beta user grants Screen Recording once  
3. Beta user sets 2–4 priorities  
4. Watch **3–7 days**: false nudges, CPU, trust, Overwhelm usage  
5. Only then invest in notarized DMG  

---

## Path B — Agent continues in parallel (no Mac)

Safe for Cloud Agents without blocking Mac work:

- Injectable clock + fix quiet-hours E2E flake  
- Finish check-in scheduler + soft-confirm prompts  
- Wire Settings autostart enable/disable  
- Improve Gemini analyze to write `observations` + better cards  
- NSPanel/capture **code drafts** behind `cfg(target_os = "macos")` (compile-checked; verify on Mac)  
- Storage cap / JPEG cleanup  

Do **not** claim M0 passed from Linux.

---

## Definition of “ready for private beta”

The beta user can, without a developer on a call:

1. Open app → onboarding → grant Screen Recording  
2. Set priorities (or soft-confirm yesterday)  
3. Get careful L1→L3 nudges with Doing it / Snooze / Overwhelm  
4. See a usable timeline + accomplishment-first evening brief  
5. Turn nudges or capture off in one obvious place  
6. Use their own Gemini key **or** stay local-only with honest Settings copy  

---

## Doc map (what to open when)

| Question | Open |
|---|---|
| What should I do next for private beta? | **This file** |
| Binding product decisions | [IMPLEMENTATION_CONTRACT.md](./IMPLEMENTATION_CONTRACT.md) |
| How to run M0 on a Mac | [M0_RUNBOOK.md](../../goal-outputs/adhd-companion-prep/M0_RUNBOOK.md) |
| Where to record M0 results | [M0_RESULTS.template.md](./M0_RESULTS.template.md) |
| How to build/test the app | [../../adhd-companion/README.md](../../adhd-companion/README.md) |
| Nudge state machine | [../../adhd-companion/SPEC_STATE_MACHINE.md](../../adhd-companion/SPEC_STATE_MACHINE.md) |
| Agent SPEC snapshot | [../../goal-outputs/adhd-companion-prep/SPEC.md](../../goal-outputs/adhd-companion-prep/SPEC.md) |

---

## Deferred for after week-1 (do not block beta)

Audio, FTS5 “search your life,” MCP, encryption-at-rest, phase-2 vision on every medium-confidence tick, perfect monitor heuristics, App Store.
