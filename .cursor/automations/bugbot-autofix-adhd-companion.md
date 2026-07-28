# Cursor Automation — Bugbot autofix (ADHD companion PR)

Paste this into [cursor.com/automations/new](https://cursor.com/automations/new).
Cloud agents cannot create Automations via API (UI-only); this file is the source of truth.

| Field | Value |
|---|---|
| **Name** | Bugbot autofix — ADHD companion PR |
| **Trigger** | Scheduled |
| **Cron** | `*/10 * * * *` |
| **Repository** | Single — `wcordelo/Dayflow` |
| **Branch** | `cursor/adhd-bugbot-ack-debounce-0f84` |
| **Tools** | Comment on pull request ✓ · Memories ✓ · PR creation available but forbidden by prompt |
| **Permissions** | Private (or Team Visible) |

## Prompt

```
You run on a schedule against this repository and branch.

Target PR: https://github.com/wcordelo/Dayflow/pull/3
Work only on that PR's head branch: cursor/adhd-bugbot-ack-debounce-0f84
Push commits to the existing branch.
Do not open a new PR. Do not approve the PR.
Do not mention end-user personal names in commits, comments, or docs.

## Goal
Find unresolved Bugbot (cursor[bot] / Cursor Bugbot) review comments on the target PR, assess each one, and address actionable findings.

## Process
1. Use `gh` and/or the Comment on Pull Request tool to list open (unresolved) review threads on PR #3.
2. Filter to comments from Bugbot / cursor[bot]. Ignore unrelated human discussion unless it clearly blocks a Bugbot fix.
3. Skip threads already fixed, outdated, or already replied to with a completed fix in a previous run (use Memories to track handled comment IDs).
4. For each actionable Bugbot finding (prefer High severity first; max 3 per run):
   - Read the cited file/lines and surrounding code.
   - Assess: real bug vs false positive / design choice.
   - If real: apply the smallest correct fix matching existing patterns; run relevant tests if feasible (engine vitest / cargo test on Linux stubs).
   - Commit with a clear message (no personal names) and push to cursor/adhd-bugbot-ack-debounce-0f84.
   - Reply on the review thread with what changed (or why you disagree if false positive). Resolve the thread if fully addressed.
5. If a comment is unclear or needs human judgment: reply explaining why — do not guess.
6. If there are no unresolved actionable Bugbot comments: do nothing (no commits, no comments).

## Rules
- Only change code required by the Bugbot comments.
- No drive-by refactors.
- Prefer addressing a small batch per run (up to 3) so runs stay reliable.
- Keep the working tree private-beta-safe: no end-user PII in the repo.
```

## Prefer event-driven (optional second trigger)

Add **PR review comment** in addition to the schedule so fixes start as soon as Bugbot comments, without waiting up to 10 minutes. Same prompt and branch.
