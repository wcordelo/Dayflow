# ADHD Companion — Implementation Contract (v2.3)

**Status:** binding for M0–M6 product build. Supersedes informal plan text where they conflict.  
**Canonical research narrative:** [Notion — Research & Build Plan](https://app.notion.com/p/3a63444800948027849ec9b757ed4177)  
**Date:** 2026-07-24 (v2.3 — hard gate removed; continuous end-to-end implementation)  
**Scope:** Mac v1 only. iPhone out of scope until a sync story exists.  
**Build policy:** Product scaffold and M1–M6 proceed **without waiting** on M0. M0 remains a Mac-only native validation track that runs **in parallel**; results may change capture/panel backends but must not block agent implementation.

> Linux Cloud Agents **cannot** execute ScreenCaptureKit / NSPanel / TCC checks. Implement product code with `#[cfg(target_os = "macos")]` (or equivalent) and stubs on other OS so CI and agents keep shipping. A developer validates native surfaces via §5 when a Mac is available.

**References (patterns, not code forks):**
- Dayflow (MIT) — batching, prompts, schema thinking, stills path, 4AM day boundary  
- [Screenpipe core concepts](https://deepwiki.com/screenpipe/screenpipe/1.3-core-concepts) · [repo](https://github.com/screenpipe/screenpipe) · [architecture](https://docs.screenpipe.com/architecture) — event-driven capture, paired a11y+pixels, local-first privacy suite, pipe-shaped agents  
- Cap/`scap` — stream capture candidate only  

Do **not** vendor Screenpipe as a Node-bridge sidecar. Borrow architecture; keep our binary small and nudge-product-scoped. License hygiene: re-implement; do not copy their source.

---

## 0. Screenpipe core concepts vs Dayflow (gap fill)

Dayflow is an excellent **retrospective timeline**. Screenpipe’s core concepts cover always-on *memory infrastructure* Dayflow never built. The companion needs **both** — plus a nudge product neither has.

| Screenpipe core concept | In Dayflow? | Prior companion draft? | Contract decision |
|---|---|---|---|
| **Event-driven capture** (not fixed FPS) | ❌ timer stills (~10s) | ✅ Candidate C | **Adopt** as preferred capture |
| Trigger: AppSwitch | ❌ | ✅ | MV for C |
| Trigger: **WindowFocus** (same app, new window/tab) | ❌ | ⚠️ folded into app switch | **Adopt as distinct** — Chrome tab changes |
| Trigger: Click / TypingPause / ScrollStop | ❌ | ✅ enhanced | Enhanced (AX/CGEventTap) |
| Trigger: **VisualChange** (pixels change w/o input) | ❌ | ❌ | **Adopt as C2** — cheap hash/histogram on idle path only; no second continuous poller |
| Trigger: IdleFallback | partial (timer is only path) | ✅ | Max-gap safety net + hash dedupe |
| **Paired capture** (screenshot + AX, same timestamp) | ❌ pixels now; text later via Gemini | partial | **Named invariant** — no desynced text/thumbnails |
| AX first; OCR if empty/**thin** | ❌ | empty-only | **Thin-AX rule** (canvas/Electron/Meet) |
| Structured AX (buttons/fields/URLs) | ❌ | partial | Fast-path evidence; optional TCC |
| Local-first + **WAL** SQLite | ✅ | ✅ | Keep |
| **FTS5** searchable memory | ❌ | refused as SKU | **Defer** optional index on `accessibility_text` for chat — not “search your life” |
| **Encryption at rest** | ❌ | ❌ | **Named optional M6+** |
| Rolling logs + on-disk settings store | partial | ❌ | **Adopt** from M1 |
| **Pipes** (scheduled `.md` + context injection) | ❌ poller | prompts-as-md only | **Adopt pipe *shape*** for product engines — not a marketplace |
| **MCP** to Cursor/Claude | ❌ | refused | **Defer M6+** for developer debugging — not private-beta v1 |
| App **blocklist** | ✅ | ✅ | Keep + expand |
| **Window-title blocklist** | ❌ | ❌ | **Adopt M1** |
| **Incognito / private window skip** | ❌ | ❌ | **Adopt M1** — major Dayflow trust gap |
| **Pause on DRM / streaming focus** | ❌ | ❌ | **Adopt M1** — legal/noise/L3 ethics |
| On-device **PII** text/image redaction | ❌ | later optional | Keep deferred; ship selective-capture suite first |
| Local-only default (no cloud) | ⚠️ store local, LLM optional | Gemini assumed | **Clarify:** capture always local; cloud analysis explicit opt-in |

### 0.1 Still refuse (Screenpipe product surface)

Audio/Whisper, mandatory `:3030`, Node-bridge SDK, pipe marketplace, Ctrl+F-your-life SKU, 5–10% CPU / multi-GB weight class.

### 0.2 Also keep from Screenpipe engineering practice

JPEG+SQLite metadata · shared event bus · specta/bindings:check · crash-safe short transactions · Keychain secrets.

## 1. Capture strategy

### 1.1 Decision rule (M0 chooses the winner)

Three candidates. M0 measures **recording-indicator**, **CPU**, **disk**, and **TCC**. Product capture follows the winner.

| Candidate | API shape | Expected indicator | Precedent |
|---|---|---|---|
| **C — Event-driven stills (preferred)** | Event → one-shot still; idle fallback; debounce ≥200ms | None / transient | Screenpipe event-driven core concept |
| **A — Timer stills** | Periodic stills ~10s | None / transient | Dayflow production |
| **B — Stream (`scap`)** | `SCStream` ≤1 FPS | Likely persistent orange pill | Cap recorder UX |

**Default until M0 results:** **Candidate C**.

### 1.1.1 Capture triggers (full Screenpipe enum)

| Trigger | MV (no AX) | Enhanced | Notes |
|---|---|---|---|
| `app_switch` | ✅ | | Highest-value context change |
| `window_focus` | ✅ best-effort | ✅ | **Same-app** tab/window — Dayflow-blind; distinct from `app_switch` |
| `idle_fallback` | ✅ | | Max gap ~5–10s; **hash-dedupe** identical frames |
| `idle_return` | ✅ | | Orchestrator / PoP anchor (HID) |
| `click` | | ✅ | Debounce ~200ms |
| `typing_pause` | | ✅ | ~500ms after last key |
| `scroll_stop` | | ✅ | ~400ms after last scroll |
| `visual_change` | | ✅ C2 | No-input pixel change (notifications, video). Cheap hash/histogram on idle path only |

### 1.1.2 Paired capture (invariant)

When a trigger fires and privacy gates pass:

1. Capture still JPEG of focused display.  
2. Walk accessibility tree for focused window (**hard timeout ~200ms** — Electron AX trees explode).  
3. If AX empty **or thin** (below char/node threshold, or known canvas bundles) → optional local OCR later; else leave pixels for slow-path Gemini.  
4. Write JPEG + **one** DB row sharing `captured_at` with `capture_trigger`, `accessibility_text`, `text_source`, `frontmost_bundle_id`, `window_title`, `idle_seconds_at_capture`, optional `frame_hash`.

Never attach AX text from time T to a screenshot from T+ε (the desync Screenpipe’s paired model exists to kill).

### 1.1.3 Event sets

**MV for C:** `app_switch`, `window_focus`, `idle_fallback` + hash dedupe, `idle_return`.  
**Enhanced:** click / typing_pause / scroll_stop + full AX + browser URL (Accessibility / CGEventTap — optional onboarding upgrade).

Scale ~1080p height, JPEG ~0.7–0.85, **focused display only**. Fixed 1 FPS is not a product target.

### 1.2 Required capture behaviors (M1+)

- **Pause** on sleep, screen lock, screensaver; **resume** after unlock/wake with delay (Dayflow: ~0.5–5s).
- Sample **HID idle seconds** at each capture.
- Run **selective capture privacy suite** (§4.1) *before* pixels hit disk.
- Exclude companion’s own windows when the API allows.
- Storage layout:
  ```
  ~/Library/Application Support/ADHDCompanion/
    db.sqlite              # WAL
    logs/                  # sized rolling logs
    screenshots/YYYY-MM-DD/
  ```
- Soft storage cap + oldest-JPEG cleanup (M2).
- Crash-safe writes (file then row, or orphan GC).

### 1.3 Explicit non-goals for capture v1

- Audio capture  
- All-monitors mosaic  
- Continuous video / H.265 / FFmpeg hot path  
- Embedding Screenpipe engine  
- Continuous visual-diff poller (C2 = cheap check on idle path only)

### 1.4 M0 capture protocol

1. Dev-signed `.app` + stable bundle ID (§5.2).  
2. **Candidate C:** `app_switch` + `window_focus` + idle fallback × ≥30 min — indicator, CPU, disk, frames/hour.  
3. **Candidate A:** 10s timer — baseline.  
4. **Candidate B:** scap @ 1 FPS and 0.2 FPS — orange-pill control.  
5. Optional: AX walk on focus (TCC UX note — not go/no-go).  
6. **Pass (a):** no persistent recording indicator. Prefer C if clean; else A; B only with explicit UX acceptance.

## 2. Dual analysis path

Point-of-performance nudges **cannot** wait on Dayflow-style 15-minute card batches. Two pipelines share screenshot storage; they do **not** share latency budgets or Gemini budgets.

```
screenshots (disk + DB)
        │
        ├──────────── Slow path (timeline / brief) ────────────┐
        │   ~15 min batches, gap-split, idle shortcut           │
        │   → observations → timeline_cards → evening brief     │
        │   lag: tens of minutes — OK                           │
        │                                                       │
        └──────────── Fast path (alignment) ────────────────────┤
            event-anchored or ≤2 min tick                         │
            → verdict {aligned|drift|unknown, confidence, evidence}
            → orchestrator (only if confidence ≥ threshold)       │
            lag: ~1–2 minutes — REQUIRED                          │
```

### 2.1 Slow path (`analyze` — M2+)

- Port Dayflow batching knobs in spirit: ~15 min target window, gap split (~2 min), skip very short batches, optional idle-without-LLM shortcut when HID idle dominates.
- Gemini vision (or Files/video composite if we keep Dayflow’s compressed-timeline trick) → observations → activity cards.
- Sliding-window replace semantics for cards (avoid duplicate/gap bugs).
- 4 AM day boundary for `day` keys and briefs.
- Prompts: adapted from Dayflow with **MIT attribution** retained in repo.
- Cost logged to `llm_calls` under budget tag `timeline`.

### 2.2 Fast path (`monitor` — M4; design frozen now)

Screenpipe’s insight: **structured text at capture time** beats deferred pixel OCR for most desktop apps. We use that for alignment before spending Gemini.

**Phase 1 (ship first):** local signals only — no Gemini vision.

Inputs (best available):
- `frontmost_bundle_id`, `window_title`, `capture_trigger`
- `accessibility_text` / browser URL **if** Accessibility granted (optional TCC — enhances confidence, not required to run)
- HID idle + current priorities + quiet/pause/meeting flags
- Recent non-redacted frame paths only as last resort metadata (not uploaded in phase 1)

Output: `verdict` + `confidence` ∈ {low, medium, high} + short `evidence` string.

Examples of **high** confidence drift: frontmost is Twitter/Reddit/YouTube while priority is “finish grant draft”; AX/title shows distraction URL; idle-return after ≥N minutes on a known distraction bundle.  
Examples of **unknown** (stay silent): Slack, Chrome with ambiguous title and no URL, coding tool that might be on- or off-priority.

**Phase 2:** medium-confidence cases may request a **cheap** vision call on the last 1–3 non-redacted frames (downscaled). Budget tag `alignment`. Hard daily cap separate from timeline.

**Rule:** If confidence < threshold for current aggressiveness setting → **no nudge**. False silence ≫ false interruption for week-1 trust.

**Accessibility TCC policy:** Screen Recording is required. Accessibility is **optional upgrade** in onboarding (“better at reading what app you’re in — recommended”). App must function on bundle/title/idle alone if the user declines.

### 2.3 Cost & failure

| Budget | Purpose | Cap (initial guess; measure M2/M4) |
|---|---|---|
| `timeline` | Slow path | Measure on a real workday before private beta |
| `alignment` | Fast path vision (phase 2) | Start **0** (heuristics only); raise only after false-silence review |

Gemini outage / missing key: slow path degrades gracefully (capture continues); fast path stays heuristic or silent; **never** crash the tray app. No shared developer API key in the client (§4.3).

---


### 2.4 Pipe-shaped product engines (Screenpipe concept, fixed set)

Screenpipe **Pipes** = scheduled `.md` agents with context injection. We do **not** ship a pipe marketplace. We **do** shape each product engine like a pipe:

| Engine | Schedule / trigger | Injected context |
|---|---|---|
| `checkin` | configured morning hour; soft-confirm on open/first drift | yesterday priorities, day boundary |
| `analyze` | ~15 min batch close (Dayflow) | screenshot set, prior cards lookback |
| `monitor` | event-anchored / ≤2 min | priorities, last triggers, AX/title, idle |
| `brief` | evening / after 4AM catch-up | day’s cards + priority outcomes |

Each lives as `prompts/<engine>.md` (frontmatter: schedule hints, model, budget tag) + Rust/TS runner that prepends time range, paths, and structured JSON schema. This is the Dayflow “AnalysisManager poller” upgraded with Screenpipe’s prompt-as-artifact discipline.

## 3. Orchestrator process model

### 3.1 Residency (source of truth)

| Component | Process / lifetime | Notes |
|---|---|---|
| Capture, DB writer, OS event observers | **Rust, always on** while app running | Survive UI hide |
| Shared event bus (`os_events`) | **Rust** | Fans out to capture worker **and** orchestrator (Screenpipe pattern) |
| Escalation state machine + timers | **Rust, always on** | JS timers die across sleep / destroyed webviews |
| L1 notify / L2–L3 window commands | **Rust** | `notify.rs`, `windows.rs` |
| Main UI (Timeline, Chat, Settings, Brief) | Webview; **may destroy on hide** | Optional memory win |
| Slow/fast prompt runners | Prefer **Rust tasks** loading versioned `prompts/*.md`; *or* hidden always-alive `engine` webview | Screenpipe “pipes as markdown”; we keep fixed product prompts, not a pipe marketplace |
| In-process Tauri commands | Default IPC | Prefer over Screenpipe-style localhost `:3030` until a second consumer needs HTTP |

**Decision for M1:** Orchestrator state machine is **Rust**. Prompts as versioned markdown under `prompts/` (checkin / monitor / brief / analyze). Generate TS bindings via specta (or equivalent) and check them in CI — Screenpipe’s `bindings:check` discipline. Vitest may mirror pure transitions; Rust tests own residency-critical paths; one `SPEC_STATE_MACHINE.md` prevents drift.

### 3.2 State machine (product contract)

```
idle ──(eligible drift + event anchor)──► L1 (notification; click→L2 default)
  │                                         │ ignore ≥8m
  │                                         ▼
  │                                        L2 (floating panel)
  │                                         │ ignore ≥10m
  │                                         ▼
  │                                        L3 (panel takeover)
  │                                         │
  └──(doing_it | snooze | priorities_changed | pause | resolve)──► cooldown / idle
```

- **Event anchors:** `app_switch`, `window_focus`, or `idle_return` (HID). Pending drift may defer until next anchor, capped (~10 min) then fire anyway if still eligible.
- **Guards (all must pass):** companion enabled; ≥1 active priority; not quiet hours; not paused/overwhelm; not in meeting; daily nudge budget remaining; ≥N min new activity since last nudge; confidence ≥ threshold; not in cooldown.
- **Cooldowns:** doing_it ~45m; snooze ~20m; priorities_changed → reopen check-in, clear escalation; pause → until pause ends.
- **Ignore-as-signal:** K consecutive ignores → reduce frequency **and** next escalation may start at L2. Exact K and frequency table fixed in M4 with unit tests.
- **L3 circuit breaker:** after 2 L3 presentations in a day → force gentle mode / require explicit re-enable (shame-free copy: “I’ll back off unless you want me”).
- **Every transition** → `nudge_events` row with timestamps (latency measurable).
- **Wall clock, not process-monotonic, for escalations.** Persist `escalate_after_unix` in DB. On wake/unlock: reload deadlines from wall time, **re-run all guards**, and cancel/defer if context changed (meeting, pause, priorities edited, long sleep). Never leap L1→L3 solely because the lid was closed for two hours.
- **Focus / DND:** L1 notifications **respect** system Focus by default. L2/L3 break-through is an explicit Settings toggle (off by default). “Inescapable” must not silently fight Focus until the user opts in.
- **TCC revoked mid-day:** stop capture cleanly; one calm Settings cue; no error spam; resume when permission returns.

### 3.3 Suppression precedence (highest wins)

1. User **Pause / Overwhelm** (explicit)  
2. **Meeting** heuristic (bundle + title/URL; manual “in a meeting” override)  
3. **Quiet hours**  
4. Daily **budget** exhausted  
5. **Cooldown** / ignore-adapted spacing  
6. Low **confidence**

### 3.4 L2 / L3 window model

- Implement as **NSPanel**-class windows (`tauri-nspanel` or equivalent objc2), not vanilla `alwaysOnTop` NSWindow.
- Collection behavior: `CanJoinAllSpaces | FullScreenAuxiliary | Stationary` (+ level high enough for fullscreen Spaces).
- Activation policy: tray **Accessory** (or documented policy toggle that keeps Dock behavior acceptable). M0 must prove the combination.
- L3 v1: **active display only** (not per-monitor mosaic). Esc: prefer disabled in-panel; always offer the three acknowledge buttons **plus** Overwhelm/Pause as a fourth escape that is care-framed, not failure-framed.
- L3 is interruptive by design; it is not a hard security boundary (Mission Control / Force Quit still exist).

---

## 4. Privacy / Pause / Key

### 4.1 Privacy (Screenpipe selective-capture suite + honest cloud boundary)

**Local-first capture; cloud analysis is opt-in** (Dayflow/Screenpipe both store locally; we must not silently become a Gemini uplink):

- Onboarding plain language: **Screenshots stay on this Mac. Analysis to Google Gemini happens only when you add a key and enable it. You can use capture + gentle local nudges without cloud.**
- **App blocklist** (bundles): password managers, authenticators, plus user additions → placeholder JPEG + `redacted=1`; never upload.
- **Window-title blocklist** (Dayflow gap / Screenpipe concept): substring rules (e.g. banking, “Incognito”, clinical portals).
- **Incognito / private window skip** (Dayflow gap / Screenpipe `ignore_incognito_windows`): detect private browsing windows and skip or redact — **M1 required**, not polish.
- **Pause on DRM / streaming focus** (Screenpipe `pause_on_drm_content`): when Netflix/etc. focused, pause capture (and do not escalate L3 over DRM playback). Reduces legal/noise risk.
- Redacted / skipped frames never leave the device.
- On-device PII ML redaction: **deferred** (after blocklist+incognito+DRM prove insufficient).
- Encryption at rest: **optional M6+** (Keychain-wrapped DB key); document as roadmap.
- No PostHog/Sentry until opt-in.
- `llm_calls` truncated; never log key material.

### 4.2 Pause / Overwhelm

First-class, reachable from Settings **and** from L2/L3:

| Action | Effect |
|---|---|
| Pause 15m / 30m / 1h | Capture may continue (for timeline) **or** pause both — **default: pause nudges only, keep capture** unless user chooses “pause watching” |
| Pause watching | Capture + nudges stopped |
| Overwhelm / rest of day | Nudges off until next 4 AM boundary; shame-free confirmation |

Distinguish **pause nudges** vs **pause capture** in UI copy. The beta user must be able to stop the system without uninstalling.

### 4.3 Keys & billing

- Gemini key: **per-user**, stored in **Keychain** (or Tauri stronghold), accessibility `WhenUnlocked`.
- **Forbidden:** embedding a developer’s key in the app, env-shipping a shared key in the DMG, or storing the key in plaintext JSON/localStorage.
- Settings: paste key + optional spend soft-cap display from `llm_calls` sums.
- Missing/invalid key: capture + local UI work; cloud analysis disabled with a calm Settings cue — never a blocking shame modal on every tick.

### 4.4 Morning priorities

- Conversational check-in at configured hour.
- If skipped: **soft confirm** when the user next opens the app or at first eligible drift (“Still working from yesterday’s list?”) — not a “you skipped” message; not blind aggressive escalation on stale priorities.
- Silent carryover alone is **insufficient** for M3 acceptance.

---

## 5. M0 — Native surface spike (developer Mac only)

### 5.1 What M0 is

A **throwaway or in-app** Mac validation of native surfaces (capture indicator, NSPanel L3, TCC). Prefer validating against the product binary when it exists; a scratch spike is optional.

**No longer a scaffold blocker.** Product `create-tauri-app` / M1+ are **allowed and expected** while M0 runs in parallel.

Timebox: 1–2 days when a developer is on Mac. Document results in `docs/adhd-companion/M0_RESULTS.md` (template below). Failures → swap capture/panel backend, not freeze the roadmap.

### 5.2 Signing / TCC prerequisite (feeds criterion e)

On Sequoia+, ad-hoc / unsigned debug binaries often **fail** Screen Recording TCC (Cap issue #1722 class failures). Before measuring (a):

1. Apple ID → free **Apple Development** cert in Xcode or Keychain.  
2. Stable bundle ID, e.g. `com.adhdcompanion.app.m0`.  
3. `Info.plist` with `NSScreenCaptureUsageDescription` (+ notification usage if testing UN).  
4. Codesign the `.app` with that development identity (Team ID present).  
5. Grant Screen Recording to **that** app; relaunch; confirm `CGPreflightScreenCaptureAccess()` true.  
6. If bundle ID changes, `tccutil reset ScreenCapture` and re-grant.

**(e) Pass:** After relaunch, capture still works with System Settings toggle on — without debug bypass hacks.

### 5.3 Go / no-go matrix

| ID | Criterion | Pass looks like | Fail → |
|---|---|---|---|
| **a** | Indicator-free capture ≥30 min interactive | No persistent orange pill on chosen API | Rethink capture (usually: abandon stream, use stills) |
| **b** | L3 over Space-isolated fullscreen | YouTube/Netflix fullscreen on **another Space**; L3 panel visible and clickable above it | Adopt/fix NSPanel path; plain `setLevel` insufficient |
| **c** | Notification click → event (signed app) | Click opens L2 or emits bus event | Non-fatal; L1 = click→L2 |
| **d** | App-switch + idle-return on bus | Logs/events fire within ~1s of action | Fix observers |
| **e** | TCC under real dev signing | §5.2 holds across relaunch | Fix signing workflow; agent-friendly claim is false until fixed |
| **f** | Lock/sleep pause + unlock resume | No black-frame spam; capture resumes | Block M1 |

**Native go/no-go (parallel):** Prefer **(a) ∧ (b) ∧ (e)** before private beta install; **not** a gate on agent scaffolding.  
**(c)** failure allowed. **(d)/(f)** should pass before private beta install; may finish inside early product builds.

### 5.4 M0 test script (checklist)

```
[ ] Dev-signed .app; bundle ID stable
[ ] (e) Screen Recording grant survives relaunch
[ ] (a) Candidate C: event-driven stills (app-switch + idle fallback) × 30min — indicator? CPU? disk? frames/hour?
[ ] (a) Candidate A: timer stills @10s × 30min — baseline
[ ] (a) Candidate B: scap @1fps and @0.2fps × 30min — indicator?
[ ] Optional: AX walk on focus (Accessibility TCC UX note)
[ ] Choose capture winner; write rationale (prefer C if clean)
[ ] (b) Accessory/NSPanel L3 over fullscreen Space video
[ ] (b) L2 floating panel on all Spaces
[ ] (c) Signed-app notification click → event (actions optional)
[ ] (d) App switch events reach shared bus (capture + log)
[ ] (d) Idle ≥60s then input → idle-return event
[ ] (f) Lock display 30s → no captures; unlock → resume
[ ] Write M0_RESULTS.md; go/no-go for M1
```

### 5.5 M0 results template

Create `docs/adhd-companion/M0_RESULTS.md` when running:

```markdown
# M0 Results — YYYY-MM-DD — macOS VERSION — machine

## Signing (e)
- Identity:
- Bundle ID:
- Preflight after relaunch: pass/fail

## Capture (a)
| Candidate | Mode | Indicator | CPU avg | Disk/30m | Frames/30m | Notes |
|---|---|---|---|---|---|---|
| C Event-driven stills | app-switch + idle fallback | | | | | |
| A Timer stills | 10s | | | | | |
| B scap | 1 fps | | | | | |
| B scap | 0.2 fps | | | | | |

Winner: …
Rationale: …

## Windows (b)
- NSPanel/level/collectionBehavior used:
- Fullscreen Space test: pass/fail + screenshot/recording note

## Notifications (c)
- pass/fail; actions? click→panel?

## OS events (d)
- app-switch: pass/fail
- idle-return: pass/fail

## Sleep/lock (f)
- pass/fail

## Go/No-Go
- (a): 
- (b): 
- (e): 
- Product create-tauri-app: **ALLOWED** (v2.3 — not gated on M0)
```

---

## 6. Milestone map (continuous build)

| Milestone | Intent | Acceptance |
|---|---|---|
| **M0** | Native validation (parallel, Mac) | Prefer (a)(b)(e) before private beta install |
| **M1** | Product scaffold, tray, autostart, capture+DB, raw timeline UI, **incognito+DRM+title blocklist** | CPU lean; privacy suite live; (f) when Mac available |
| **M2** | Slow analysis + blocklist + cost log | Sane timeline; cost known |
| **M3** | Check-in, soft carryover confirm, settings, pause | Priorities rows; no shame copy |
| **M4** | Fast path + Rust orchestrator + L1–L3 | Scripted day; tests green |
| **M5** | Evening brief + copy pass | Accomplishments first |
| **M6** | Notarized DMG, onboarding, per-user key | Fresh machine, zero terminal |

---

## 7. Second-pass adversarial review (2026-07-23)

Review of **this contract**, not the prior draft. Findings and how the contract absorbs them:

### 7.1 Resolved by this document

| Attack | Resolution |
|---|---|
| scap@1FPS + orange pill | M0 A/B/C; default **event-driven stills (C)**; stream last |
| 15-min batch drives nudges | Dual path; fast path latency contract |
| Orchestrator in destroyable webview | Rust-resident state machine |
| `setLevel` ≠ fullscreen Space | NSPanel + collection behaviors; M0 (b) |
| Sequoia TCC + tauri dev | M0 (e) + signing runbook |
| Shared API key | Forbidden; Keychain per-user |
| No pause | First-class Pause / Overwhelm |
| Blind silent carryover | Soft confirm required |
| create-tauri-app before proof | **Superseded in v2.3** — scaffold proceeds; M0 validates native surfaces in parallel |
| Meeting = bundle ID only | Title/URL + manual override; suppression ladder |
| Fixed-FPS waste / desynced text | Screenpipe: event→JPEG+text same timestamp; `capture_trigger` |
| “Just depend on Screenpipe” | Patterns only; no Node-bridge / audio / search-product embed |

### 7.2 Remaining risks (accepted or deferred — watch list)

1. **Heuristic fast path will miss “productive Twitter” and false-positive “Chrome”.**  
   Mitigation: confidence gate; phase-2 vision only for medium; week-1 logging of silent vs fired decisions for developer review — not the beta user’s shame metric.

2. **Browser URL / rich context needs Accessibility.**  
   Optional upgrade in onboarding (§2.2). Core path works on bundle/title/idle; AX improves confidence and reduces Gemini spend. CGEventTap for click/typing-pause may also require trust — keep those in the “enhanced” event set.

3. **Rust orchestrator + TS/vitest mirror can drift.**  
   Mitigation: single `SPEC_STATE_MACHINE.md` transition table; CI fails if either side’s tests disagree with the table (process discipline, not magic).

4. **Hidden engine webview still costs RAM** if chosen over Rust prompt runner.  
   Measure in M1; prefer Rust+prompt assets if RSS matters on a beta user’s machine.

5. **Capture-continue during “pause nudges”** still sends screenshots to Gemini on slow path.  
   Onboarding must say so; “pause watching” is the true off switch. Default pause = nudges only is correct for timeline continuity but must be obvious in UI.

6. **L3 ethics / App Store-like scrutiny** — not shipping App Store initially (Developer ID DMG), but coercive UX can still burn trust. Circuit breaker + Overwhelm are mandatory before private beta install.

7. **Product repo location** — contract lives under Dayflow `docs/` until a dedicated companion repo exists. Avoid mixing Swift Dayflow targets with Tauri code in the same Xcode project. When M1 starts, prefer a **new repo** linked from here.

8. **Cloud agents cannot replace a developer Mac for M0.**  
   Any Cursor Cloud work before M0 green is limited to prompts/schemas/docs/TS pure logic — not native go/no-go.

9. **Notarization still required for M6** (Gatekeeper + reliable UN). Dev-signed M0 ≠ release pipeline. Don’t confuse (e) pass with ship-ready.

10. **Idle definitions** — capture HID idle ≠ UI inactivity ≠ LLM-said idle. Spec columns and event names distinctly in schema (`idle_seconds_at_capture`, `os_idle_return_at`, …).

11. **Lid-closed timer leap** — wall-clock deadlines + wake-time guard re-check (§3.2). Without this, ignore→L3 feels random and punitive after sleep.

12. **Focus / DND clash with “inescapable”** — default respect Focus for L1; L2/L3 break-through opt-in (§3.2). Revisit after week-1 beta feedback, not before.

13. **Third-party PII in screenshots** (Slack threads, email) leaves the machine via Gemini. Onboarding disclosure required; blocklist cannot catch everything; accept residual risk with clear consent.

14. **Social-commitment insight** — for many ADHD users the working mechanism is *pledged time to a person*. This companion is environmental scaffolding, not a Focusmate replacement. Positioning: optional adjunct; weekly human check-in remains valuable.

15. **Schema migrations** — versioned `db.rs` migrations from M1 day one (avoid Dayflow-style legacy-table pain).

16. **Permission revoked / display disconnected** — treat as pause-capture, not crash; re-resolve active display like Dayflow’s display refresh path.

17. **Screenpipe resource profile is a trap if copied wholesale.**  
    Their published 5–10% CPU / up to 3GB RAM / audio+OCR stack is fine for a “search your life” app, wrong for a shame-sensitive tray companion. Event-driven stills + no audio is the lean slice we want.

18. **Event-driven capture without AX still helps orchestrator** (shared app-switch bus) even if text extraction is thin — don’t block C on Accessibility grant.

### 7.3 Verdict (second pass)

Contract is **sufficient to build the product end-to-end**. M0 validates native surfaces in parallel; highest-probability Mac risks remain **(b)** panel/fullscreen Spaces and **(e)** signing/TCC — budget those when a developer is on Mac; run capture **C then A** (B as orange-pill control). Do not stall M1–M6 on those results.

**Still open (do not block product code):** full click/typing-pause taps (may need Accessibility); exact K-ignore table (tune in M4 tests); Rust prompt runner vs hidden engine webview; whether optional localhost API is ever worth it.

---

## 8. Immediate next actions

1. **Agents:** Continue M1–M6 in `adhd-companion/` (Tauri product + engine). Use stubs for macOS-only APIs on Linux CI.  
2. **Developer (Mac):** Run §5 against the product binary (or optional scratch spike); write `M0_RESULTS.md`; swap capture/panel backends if needed.  
3. **Interim for private beta (if needed before companion is installable):** stock Dayflow + one Focusmate-style session (pledged-time hypothesis) — novelty decays by week 4; that’s the real evaluation window per Barkley framing.
