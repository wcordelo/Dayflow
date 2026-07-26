# SPEC_STATE_MACHINE.md

Canonical TypeScript/Rust mirror of contract **v2.2** orchestrator transitions.  
Source: `docs/adhd-companion/IMPLEMENTATION_CONTRACT.md` §3.2–3.3 and `goal-outputs/adhd-companion-prep/SPEC.md`.

## Diagram

```
idle ──(eligible drift + event anchor)──► L1 ──ignore≥8m──► L2 ──ignore≥10m──► L3
  └──(doing_it | snooze | priorities_changed | pause | resolve)──► cooldown / idle
```

## Levels

| Level | UX (native, post-M0) | Entered when |
|---|---|---|
| `idle` | No nudge UI | Start; after resolve/cooldown; guards cancel |
| `L1` | Notification (respects Focus by default) | Eligible drift + anchor (or pending cap) |
| `L2` | Floating NSPanel | L1 ignore ≥ **8 minutes**, or L1 click |
| `L3` | Fullscreen-auxiliary panel (active display) | L2 ignore ≥ **10 minutes** (blocked in gentle mode) |

## Timers (wall clock)

| Constant | Value | Notes |
|---|---|---|
| L1 → L2 ignore | **8 minutes** | Persist `escalate_after_unix` |
| L2 → L3 ignore | **10 minutes** | Same |
| Pending anchor cap | **~10 minutes** | Drift may wait for `app_switch` \| `window_focus` \| `idle_return`; then fire if still eligible |
| `doing_it` cooldown | **45 minutes** | Back to idle |
| `snooze` cooldown | **20 minutes** | Back to idle |
| L3 circuit breaker | **2 / logical day** | Then gentle mode (no further auto-L3) |

All escalations use **wall-clock** unix deadlines, not process-monotonic time. On `wake` / unlock: reload deadlines, **re-run guards**, cancel if context changed. Never leap `L1 → L3` solely because the lid was closed.

## Event anchors

Nudges fire from idle only when:

1. Monitor reports `drift` with confidence ≥ threshold (`medium` or `high`; **never** on `low`), and
2. An anchor arrives (`app_switch`, `window_focus`, `idle_return`), **or** the pending-anchor cap elapses while still eligible.

## Guards (all must pass)

1. Companion enabled  
2. ≥ 1 active priority  
3. Not quiet hours  
4. Not paused / overwhelm  
5. Not in meeting  
6. Daily nudge budget remaining  
7. Spacing since last nudge  
8. Confidence ≥ threshold  
9. Not in cooldown  

### Suppression precedence (highest wins)

1. Pause / Overwhelm  
2. Meeting  
3. Quiet hours  
4. Budget  
5. Cooldown / ignore-adapted spacing  
6. Low confidence  

## Resolve → cooldown / idle

| Reason | Effect |
|---|---|
| `doing_it` | idle + cooldown **45m** |
| `snooze` | idle + cooldown **20m** |
| `priorities_changed` | idle; clear escalation; reopen check-in (product) |
| `pause` / `overwhelm` | idle until pause ends (Overwhelm → next 4 AM) |
| `resolve` | idle (no special cooldown unless product sets one) |
| `guards_failed` on escalate/wake | idle; do not leap levels |

## Ignore-as-signal (provisional K=3)

After **3** consecutive ignore escalations, the next fire may start at **L2** instead of L1 (still subject to guards). Exact K may be tuned in M4; tests lock current behavior.

## TypeScript mirror

`src/orchestrator` implements this machine with an injectable `Clock`. Vitest owns pure transitions; Rust will own residency after product scaffold unlocks.
