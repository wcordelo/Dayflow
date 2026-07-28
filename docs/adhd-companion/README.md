# ADHD Companion docs

| Doc | Role |
|---|---|
| **[BETA_READINESS.md](./BETA_READINESS.md)** | **Start here** — end-to-end playbook for private beta (what’s done, what’s Mac-only, checklist) |
| [IMPLEMENTATION_CONTRACT.md](./IMPLEMENTATION_CONTRACT.md) | Binding decisions (**v2.3**): capture C/A/B, dual path, orchestrator, privacy, M0 parallel validation |
| [M0_RESULTS.template.md](./M0_RESULTS.template.md) | Fill on a developer Mac → save as `M0_RESULTS.md` (no end-user PII) |
| [SCREENPIPE_LEARNINGS.md](./SCREENPIPE_LEARNINGS.md) | Research notes |
| [ADVERSARIAL_REVIEW_R2.md](./ADVERSARIAL_REVIEW_R2.md) | Historical review (hard-gate language superseded by v2.3) |

**Related (outside this folder):**

| Doc | Role |
|---|---|
| [`adhd-companion/README.md`](../../adhd-companion/README.md) | Build / test / run the Tauri app |
| [`goal-outputs/adhd-companion-prep/M0_RUNBOOK.md`](../../goal-outputs/adhd-companion-prep/M0_RUNBOOK.md) | Step-by-step native validation on Mac |
| [`adhd-companion/SPEC_STATE_MACHINE.md`](../../adhd-companion/SPEC_STATE_MACHINE.md) | L1–L3 transition table |

**Product code:** `adhd-companion/`. Scaffolding is unblocked (v2.3); private beta still wants M0 **(a)∧(b)∧(e)** green on a signed Mac build. Do not commit end-user names or API keys.
