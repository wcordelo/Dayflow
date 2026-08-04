# Archived ADHD Companion prototype docs

> Historical reference only. This is not the current Dayflow product plan and
> must not be used to launch or extend a separate companion app. The active
> architecture is documented in [`docs/multi-device/`](../multi-device/).

| Doc | Role |
|---|---|
| **[BETA_READINESS.md](./BETA_READINESS.md)** | Historical private-beta playbook; retained for migration review only |
| [IMPLEMENTATION_CONTRACT.md](./IMPLEMENTATION_CONTRACT.md) | Historical decisions (**v2.3**): capture C/A/B, dual path, orchestrator, privacy, M0 parallel validation |
| [M0_RESULTS.template.md](./M0_RESULTS.template.md) | Fill on a developer Mac → save as `M0_RESULTS.md` (no end-user PII) |
| [SCREENPIPE_LEARNINGS.md](./SCREENPIPE_LEARNINGS.md) | Research notes |
| [ADVERSARIAL_REVIEW_R2.md](./ADVERSARIAL_REVIEW_R2.md) | Historical review (hard-gate language superseded by v2.3) |

**Related (outside this folder):**

| Doc | Role |
|---|---|
| [`adhd-companion/README.md`](../../adhd-companion/README.md) | Build / test / run the Tauri app |
| [`goal-outputs/adhd-companion-prep/M0_RUNBOOK.md`](../../goal-outputs/adhd-companion-prep/M0_RUNBOOK.md) | Step-by-step native validation on Mac |
| [`adhd-companion/SPEC_STATE_MACHINE.md`](../../adhd-companion/SPEC_STATE_MACHINE.md) | L1–L3 transition table |

**Status:** `adhd-companion/` is retained as a source reference while native
Dayflow clients reach parity. Do not add product work here or treat its M0/M1–M6
checklists as current release gates. Do not commit end-user names or API keys.
