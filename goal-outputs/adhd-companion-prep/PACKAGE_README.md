# ADHD Companion — Prep package

Contract **v2.3** artifacts for agents and Mac validation.

| # | Path | Role |
|---|---|---|
| 1 | `SPEC.md` | Agent-facing stop-conditions |
| 2 | `schema.sql` | SQLite DDL |
| 3 | `prompts/checkin.md` | Morning check-in engine |
| 4 | `prompts/analyze.md` | Slow-path timeline engine |
| 5 | `prompts/monitor.md` | Fast-path alignment engine |
| 6 | `prompts/brief.md` | Evening brief engine |
| 7 | `PACKAGE_README.md` | This index |
| 8 | `M0_RUNBOOK.md` | Mac parallel validation |

Also: `validate.py`, `PROGRESS.md`.

**Product code lives in** `/workspace/adhd-companion/` (Tauri v2). Prep package remains the portable SPEC/schema/prompts source.

**Build policy:** Hard gate removed in v2.3 — scaffold and M1–M6 proceed; M0 runs in parallel on Mac (prefer (a)∧(b)∧(e) before private beta install).

**Private beta path:** [`docs/adhd-companion/BETA_READINESS.md`](../../docs/adhd-companion/BETA_READINESS.md) — single playbook (no end-user names in docs).
