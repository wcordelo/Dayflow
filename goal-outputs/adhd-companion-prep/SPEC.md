# ADHD Companion — Agent SPEC (contract v2.3)

**Source of truth:** `docs/adhd-companion/IMPLEMENTATION_CONTRACT.md` (v2.3).  
**Scope:** Mac v1 only. iPhone out of scope.  
**Status:** Binding stop-conditions for agents. Do not re-litigate Notion/history.

---

## GOAL

Ship a lean, shame-sensitive **ADHD nudge companion** for macOS private beta: always-on local capture + dual analysis (timeline + point-of-performance alignment) + Rust-resident L1–L3 orchestrator. Architecture borrows Screenpipe/Dayflow *patterns*; re-implement — do not vendor Screenpipe, Node-bridge, or Dayflow Swift targets.

---

## DELIVERABLES

| Milestone | Must deliver |
|---|---|
| **M0** | Native validation on Mac (**parallel**); `M0_RESULTS.md`. Does not block product code. |
| **M1** | Product tray app: capture+WAL SQLite, raw timeline UI, privacy suite (blocklist / title / incognito / DRM), autostart. |
| **M2** | Slow path `analyze` (~15 min batches → cards); cost log `timeline`. |
| **M3** | Morning check-in + soft carryover confirm; Pause/Overwhelm; settings. |
| **M4** | Fast path `monitor` + Rust orchestrator L1–L3; tests vs `SPEC_STATE_MACHINE.md`. |
| **M5** | Evening `brief` (accomplishments first). |
| **M6** | Notarized DMG; per-user Keychain Gemini key; onboarding. |

Fixed pipe-shaped engines (not a marketplace): `checkin`, `analyze`, `monitor`, `brief` as `prompts/<engine>.md` + runner.

**Product path:** `adhd-companion/` (Tauri v2).

---

## BUILD POLICY (v2.3)

**Hard gate removed.** Product scaffold and M1–M6 proceed continuously. M0 validates ScreenCaptureKit / NSPanel / TCC on a developer Mac in parallel; failures swap backends, they do not freeze the roadmap.

Linux agents implement with `cfg(macos)` stubs so CI keeps moving.

---

## CAPTURE

**Decision rule:** M0 measures indicator, CPU, disk, TCC. Product follows the winner. **Default:** Candidate **C**.

| Candidate | Shape | Role |
|---|---|---|
| **C — Event-driven stills (preferred)** | Event → one-shot JPEG; idle fallback; debounce ≥200ms | Screenpipe-style; expected none/transient indicator |
| **A — Timer stills** | ~10s periodic | Dayflow baseline |
| **B — Stream (`scap`)** | `SCStream` ≤1 FPS | Orange-pill control; last resort + explicit UX |

**Triggers**

- **MV for C:** `app_switch`, `window_focus` (**distinct** — same-app tab/window), `idle_fallback` (~5–10s + hash dedupe), `idle_return`.  
- **Enhanced:** `click` / `typing_pause` / `scroll_stop` (+ full AX / URL).  
- **`visual_change` = C2:** cheap hash/histogram on **idle path only** — no second continuous poller.

**Paired capture (invariant):** On trigger (privacy gates pass): JPEG + AX walk (hard timeout ~200ms) → **one** DB row sharing `captured_at` with `capture_trigger`, text fields, bundle, title, idle, optional `frame_hash`. Never desync AX from pixels. Thin AX → optional OCR later; else slow-path pixels.

**Behaviors:** Pause on sleep/lock/screensaver; resume after unlock; HID idle sampled; exclude own windows; focused display ~1080p JPEG 0.7–0.85; crash-safe writes.

**Non-goals (v1):** Audio; all-monitor mosaic; continuous video/H.265; Screenpipe engine embed; continuous visual-diff poller. **Do not invent audio / MCP / FTS5 product scope** (MCP & FTS5 deferred; audio refused).

---

## DUAL PATH

Shared screenshot storage; **separate** latency and Gemini budgets.

```
screenshots ─┬─ Slow (`analyze`, M2+): ~15 min batches → observations → cards → brief
             │   lag tens of minutes OK; budget `timeline`
             └─ Fast (`monitor`, M4): event-anchored or ≤2 min tick
                 → verdict {aligned|drift|unknown} + confidence + evidence
                 → orchestrator only if confidence ≥ threshold
                 lag ~1–2 min REQUIRED
```

- **Phase 1 fast:** local signals only (bundle/title/trigger/AX-if-granted/idle/priorities/flags) — **no** Gemini.  
- **Phase 2:** medium-confidence may cheap-vision 1–3 frames; budget `alignment` starts at **0**.  
- Confidence < threshold → **no nudge** (false silence ≫ false interruption).  
- Screen Recording required; Accessibility **optional** upgrade.  
- Gemini outage: capture continues; never crash tray. No shared developer API key.

---

## ORCHESTRATOR

**Rust-resident** while app runs (capture, DB, OS observers, shared `os_events` bus, escalation SM + timers, L1 notify / L2–L3 windows). Webview UI **may destroy on hide**. Prefer Rust tasks loading `prompts/*.md` over destroyable JS timers / optional hidden engine webview. Prefer in-process Tauri IPC over localhost `:3030`.

```
idle ──(eligible drift + event anchor)──► L1 ──ignore≥8m──► L2 ──ignore≥10m──► L3
  └──(doing_it | snooze | priorities_changed | pause | resolve)──► cooldown / idle
```

- Anchors: `app_switch` | `window_focus` | `idle_return`; pending drift may wait for anchor (cap ~10 min).  
- Guards: enabled; ≥1 priority; not quiet/paused/meeting; budget; spacing; confidence; cooldown.  
- Wall-clock `escalate_after_unix` (not process-monotonic); on wake re-run guards.  
- L1 respects Focus by default; L2/L3 breakthrough opt-in.  
- L2/L3 = **NSPanel**-class (`CanJoinAllSpaces | FullScreenAuxiliary | Stationary`); tray Accessory. L3 = active display only.  
- L3 circuit breaker: 2/day → gentle mode. Every transition → `nudge_events`.

**Suppression (highest wins):** Pause/Overwhelm → Meeting → Quiet hours → Budget → Cooldown/ignore spacing → Low confidence.

---

## PRIVACY SUITE

Local-first; cloud analysis **explicit opt-in**. Onboarding: screenshots stay on Mac; Gemini only with the user’s own key enabled.

**M1 required (before private beta):**

1. **App blocklist** → placeholder JPEG + `redacted=1`; never upload.  
2. **Window-title blocklist** (substring rules).  
3. **Incognito / private window skip** (or redact).  
4. **Pause on DRM / streaming focus** (no L3 over DRM playback).

Also: Pause nudges vs pause watching (default: nudges only, capture continues — must be obvious); Overwhelm to next 4 AM; Gemini key per-user Keychain only; no PostHog/Sentry until opt-in. On-device PII ML / encryption-at-rest = deferred (M6+ optional for encryption).

---

## M0 CRITERIA (parallel Mac validation)

Throwaway spike **or** product binary on a **developer Mac**; document in `M0_RESULTS.md`.

| ID | Criterion | Pass |
|---|---|---|
| **(a)** | Indicator-free capture ≥30 min interactive | No persistent orange pill on chosen API. Prefer **C** if clean; else A; B only with explicit UX acceptance. |
| **(b)** | L3 over Space-isolated fullscreen | NSPanel visible/clickable above YouTube/Netflix fullscreen on **another Space**; L2 on all Spaces. |
| **(c)** | Notification click → event (signed app) | Non-fatal if fail; L1 = click→L2. |
| **(d)** | App-switch + idle-return on bus | Events within ~1s. |
| **(e)** | TCC under real dev signing | Screen Recording survives relaunch; `CGPreflightScreenCaptureAccess()` true. |
| **(f)** | Lock/sleep pause + unlock resume | No black-frame spam; capture resumes. |

Prefer **(a) ∧ (b) ∧ (e)** before private beta install — **not** a gate on agent scaffolding.

---

*Contract v2.3 binding. Build continuously through M6.*
