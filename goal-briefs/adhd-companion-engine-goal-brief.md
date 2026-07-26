=== GOAL BRIEF START ===
BRIEF VERSION: 1.1
GOAL: Under /workspace/adhd-companion/, ship a pure-TypeScript ADHD companion engine package (no create-tauri-app) with orchestrator state machine, monitor heuristics, privacy helpers, day-boundary utils, schema+prompts, SPEC_STATE_MACHINE.md, and vitest suite all green — encoding SPEC.md / contract v2.2 stop-conditions that do not require macOS native APIs.
BACKGROUND: Prep package already exists. SPEC HARD GATE forbids product create-tauri-app until M0 (a)∧(b)∧(e). Linux agents implement only pure TS / schema / prompts. This goal builds the agent-testable core (M4-shaped) so Mac M0 and later Tauri wiring have a real engine to call.
DELIVERABLES: 1 package (per user) — adhd-companion/ containing: package.json, tsconfig, vitest config, README (states hard gate), SPEC_STATE_MACHINE.md, schema/schema.sql, prompts/{checkin,analyze,monitor,brief}.md, src/** (orchestrator, monitor, privacy, dayBoundary), tests/** with vitest exit 0.
WORKING FILES: none
AUDIENCE & STAKES: developers + Cursor agents. HIGH STAKES: no.
INPUTS: goal-outputs/adhd-companion-prep/SPEC.md (present (workspace listing)); docs/adhd-companion/IMPLEMENTATION_CONTRACT.md (present (workspace listing)); goal-outputs/adhd-companion-prep/schema.sql and prompts/* (present (workspace listing)).
REFERENCES: goal-briefs/adhd-companion-prep-goal-brief.md ; docs/adhd-companion/
ACCEPTANCE CRITERIA:
  MECHANICAL:
  - Directory adhd-companion/ exists with package.json naming the package.
  - README.md states create-tauri-app is blocked until M0 (a)∧(b)∧(e) and that this package is not a Tauri scaffold.
  - SPEC_STATE_MACHINE.md documents idle→L1→L2→L3 and resolve/cooldown transitions with timers 8m/10m and cooldowns doing_it 45m / snooze 20m.
  - src/orchestrator exports a pure function/class that transitions on events and never uses Date.now() alone for escalation without injectable clock.
  - src/monitor exports evaluateAlignment returning verdict + confidence in {low,medium,high} and never recommends nudge when confidence is low.
  - Privacy modules cover app blocklist, title blocklist, incognito detection helpers, DRM bundle heuristics.
  - dayBoundary implements 4AM logical day.
  - schema/schema.sql and prompts/* present (copied/improved from prep).
  - npm test (vitest) exits 0 with ≥8 tests.
  - No src-tauri/ directory and no create-tauri-app artifacts in adhd-companion/.
  JUDGMENT:
  - State machine matches SPEC ORCHESTRATOR section faithfully.
  - Monitor heuristics are conservative (false silence preferred).
  - Package is clearly the engine core for future Tauri, not a fake claiming M0 done.
CONSTRAINTS: Do NOT run create-tauri-app. Do NOT claim M0 passed. Do NOT add audio/MCP/FTS5 product. Prefer injectable clocks for tests. Budget 200.
EXTERNAL ACTIONS: none
BUDGET CAP: 200 subagent calls
ASSUMPTIONS: none — user explicitly requested end-to-end implementation under SPEC; scoped to hard-gate-allowed work.
SUGGESTED APPROACH: Scaffold package + SPEC_STATE_MACHINE first; implement modules in parallel with tests; run vitest; advisory-only polish. Advisory only.
=== GOAL BRIEF END ===
