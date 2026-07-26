=== GOAL BRIEF START ===
BRIEF VERSION: 1.1
GOAL: Produce a complete agent-ready ADHD companion prep package under goal-outputs/adhd-companion-prep/ containing exactly 8 files — SPEC.md, schema.sql, M0_RUNBOOK.md, PACKAGE_README.md, and prompts/{checkin,analyze,monitor,brief}.md — each encoding the v2.2 implementation contract’s binding decisions, with every MECHANICAL criterion below passing a saved validate.py.
BACKGROUND: The binding SPEC already exists as docs/adhd-companion/IMPLEMENTATION_CONTRACT.md (v2.2), refined via adversarial review and Screenpipe core-concept gap-fill. Native M0 (ScreenCaptureKit / NSPanel / TCC) cannot run on this Linux Cloud Agent and is explicitly out of scope for this goal. This package turns the contract into executable artifacts developers can use on Mac for M0 and agents can use for M1 scaffolding once (a)(b)(e) are green. create-tauri-app remains blocked until M0 passes.
DELIVERABLES: 8 files (per user + contract structure) under goal-outputs/adhd-companion-prep/: (1) SPEC.md — consolidated stop-condition SPEC for M0–M1; (2) schema.sql — SQLite DDL for screenshots/observations/timeline_cards/priorities/nudge_events/settings/llm_calls with capture_trigger and privacy columns; (3) M0_RUNBOOK.md — Mac checklist from contract §5 with Linux-blocked status noted; (4) PACKAGE_README.md — how to use the package; (5–8) prompts/checkin.md, prompts/analyze.md, prompts/monitor.md, prompts/brief.md — pipe-shaped prompt files with frontmatter (schedule, budget tag) and body.
WORKING FILES: none
AUDIENCE & STAKES: developers and future Cursor agents executing M0/M1. HIGH STAKES: no — internal engineering prep; does not leave the org, commit money, or drive an external decision meeting.
INPUTS: docs/adhd-companion/IMPLEMENTATION_CONTRACT.md (present (workspace listing)); docs/adhd-companion/SCREENPIPE_LEARNINGS.md (present (workspace listing)); docs/adhd-companion/ADVERSARIAL_REVIEW_R2.md (present (workspace listing)); docs/adhd-companion/M0_RESULTS.template.md (present (workspace listing)); docs/adhd-companion/README.md (present (workspace listing)). No connectors required. General knowledge of Dayflow/Screenpipe patterns already reflected in those docs.
REFERENCES: https://app.notion.com/p/3a63444800948027849ec9b757ed4177 ; https://deepwiki.com/screenpipe/screenpipe/1.3-core-concepts ; https://github.com/wcordelo/Dayflow/pull/2
ACCEPTANCE CRITERIA:
  MECHANICAL:
  - Exactly 8 files exist at the paths listed in DELIVERABLES (census = 8).
  - SPEC.md contains labeled sections GOAL, DELIVERABLES, HARD GATE, CAPTURE (C/A/B), DUAL PATH, ORCHESTRATOR, PRIVACY SUITE, M0 CRITERIA (a–f).
  - SPEC.md states verbatim that product create-tauri-app is blocked until M0 (a)∧(b)∧(e) pass.
  - schema.sql defines tables screenshots, observations, timeline_cards, priorities, nudge_events, settings, llm_calls (case-insensitive name match via SQL parser or grep).
  - schema.sql screenshots table includes columns capture_trigger, idle_seconds_at_capture, frontmost_bundle_id, window_title, redacted (or equivalent boolean), and file_path/snapshot path.
  - Each of the 4 prompt files contains YAML/frontmatter-like header fields for schedule (or trigger) and budget_tag, plus a non-empty body ≥200 characters.
  - prompts/monitor.md mentions confidence threshold or confidence levels (low/medium/high) and that low confidence means no nudge.
  - prompts/brief.md forbids the words failed/failure as priority outcome labels (accomplishment-first / still open framing present).
  - M0_RUNBOOK.md includes checklist items for criteria (a), (b), (c), (d), (e), (f) and states this environment cannot execute native M0.
  - PACKAGE_README.md lists all 8 deliverable paths and the hard gate sentence.
  - All deliverables are valid UTF-8 text; schema.sql has no null bytes; validate.py exits 0.
  JUDGMENT:
  - SPEC.md is faithful to contract v2.2 (event-driven C preferred, paired capture, incognito/DRM/title blocklist, pipe-shaped engines) without inventing new product scope.
  - Prompt bodies are usable as agent instructions (clear role, inputs, JSON/output shape) rather than vague essays.
  - Package is immediately actionable for a Mac M0 run without re-reading the full Notion history.
CONSTRAINTS: Never modify docs/adhd-companion/IMPLEMENTATION_CONTRACT.md in place as the “deliverable” — copy/derive into GOAL_DIR. Do not run create-tauri-app. Do not claim M0 (a)(b)(e) passed. No native macOS builds. No audio/MCP/FTS5 product scope expansion beyond what the contract already deferred. Shame-free copy only in prompt/brief text.
EXTERNAL ACTIONS: none
BUDGET CAP: 200 subagent calls (user-raised from default 30)
ASSUMPTIONS: Deliverable set is the 8-file prep package (assumed from “execute plan from SPEC” on a Linux agent that cannot run M0 — awaiting confirmation if a different artifact was intended). Format is markdown + SQL (assumed — knowledge-work default for this prep package). Save under /workspace/goal-outputs/adhd-companion-prep/ (workspace folder evidence).
SUGGESTED APPROACH: Derive SPEC.md and schema from the contract first; prompt files are parallel-safe once SPEC excerpts exist; M0_RUNBOOK and PACKAGE_README last. Advisory only.
=== GOAL BRIEF END ===
