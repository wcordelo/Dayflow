# Second-pass adversarial review — Implementation Contract v2.1

**Date:** 2026-07-23  
**Subject:** [`IMPLEMENTATION_CONTRACT.md`](./IMPLEMENTATION_CONTRACT.md) (+ Screenpipe architecture pass)  
**Method:** Attack the tightened contract as if shipping to private beta next month; prefer kill-shots over nits.

## Verdict

**Contract is good enough to run M0 on a developer Mac. It is not yet good enough to scaffold the product.** Remaining kill-shots are empirical (a/b/e), not documentary. Do not `create-tauri-app` until those are green.  
*(Historical note: hard-gate language here is superseded by contract v2.3 — scaffold proceeds; M0 stays parallel.)*

Screenpipe strengthens the **capture + event-bus** story (event-driven stills, a11y-first text) and does **not** remove L3/fullscreen or Sequoia TCC risk.

## Attacks that no longer land

| Attack on prior plan | Why dead |
|---|---|
| Continuous scap@1FPS as default | Default **event-driven stills (C)**; scap last |
| Nudges wait on 15-min cards | Dual path; local AX/heuristic fast path |
| Orchestrator dies with UI webview | Rust-resident SM + wall-clock deadlines |
| `setLevel(.screenSaver)` alone | NSPanel + collection behaviors; M0 (b) |
| Agent-friendly without signing | M0 (e) runbook; Cap Sequoia lesson |
| Shared developer Gemini key | Forbidden |
| No overwhelm escape | Pause / Overwhelm first-class |
| Blind silent carryover | Soft confirm required |
| M0 == product scaffold | Throwaway spike; hard gate |
| “Use Screenpipe as the engine” | Explicit non-adopt: no Node bridge, audio, search product |

## Attacks that still land (watch / absorb)

### P0 — must stay conscious during M0/M1

1. **(b) is still the hardest native proof.** Accessory policy vs Dock icon, panel vs webview input focus, and Stage Manager are footguns. Budget half of M0 here. If (b) fails twice, consider Electron’s documented path as a forced stack revisit.

2. **(e) blocks local capture iteration until signing is boring.** M1 needs a checked-in signed-dev recipe.

3. **Heuristic/AX fast path will still be wrong often.** Instrument `alignment_decisions` from M4 day one — developer reviews logs, not the beta user’s shame metric.

4. **Copying Screenpipe’s weight class.** Their CPU/RAM/audio stack would make a tray companion feel like malware. Stay on the lean event-driven JPEG slice.

### P1 — verify in implementation

5. Wall-clock escalation across sleep.  
6. Focus/DND default respect.  
7. Pause nudges ≠ pause capture disclosure.  
8. Third-party PII consent in onboarding.  
9. New repo for Tauri code.  
10. Optional Accessibility onboarding without blocking core loop.  
11. Shared bus: capture worker must not starve orchestrator under click storms (debounce is load-bearing).

### P2 — non-blockers for M0

12. Full click/typing-pause taps.  
13. Exact K-ignore table.  
14. localhost API.  
15. Local PII model (Screenpipe-style).

## Contradiction scan

| Claim A | Claim B | Resolution |
|---|---|---|
| “Inescapable” nudges | Respect Focus; Overwhelm exit | Relative inescapability; don’t overclaim |
| Zero-input capture | Soft morning confirm | Rare/lightweight OK |
| Dayflow CPU story | Screenpipe 5–10% CPU | We are **not** Screenpipe; measure lean C/A |
| Agent-friendly | M0 Mac-only, signed | Agents write logic; humans own native go/no-go |
| Event-driven needs AX | AX is optional | MV events = app-switch + idle fallback without AX |

## Recommendation

1. Developer runs §5; prefers proving **C** then **A**, treats **B** as negative control for the orange pill.  
2. If (a)(b)(e) pass → new companion repo + `create-tauri-app` (M1).  
3. If (b) fails → isolated nspanel half-day; then Electron L3 spike before stack lock.  
4. If stills (C and A) show a persistent indicator on that OS → stop; capture premise invalid.

## Cloud Agent note

This environment cannot execute M0. Any PR claiming M0 green without Mac-authored `M0_RESULTS.md` is false.
