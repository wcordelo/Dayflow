# Reference study notes (Phase 0)

Patterns locked from PLATFORM-RETHINK.md §13. Study completed 2026-07-29.

## OpenTag (`~/Documents/opentag`)

- **Wrangler layout:** `edge/wrangler.toml` — `nodejs_compat`, multiple `[[durable_objects.bindings]]`, versioned `[[migrations]]` with `new_sqlite_classes`.
- **ConversationStateDO:** per-entity state + **DO alarms** for owed work recovery (nudge timers map here).
- **SessionEventDO:** append-only `events` log with cursor replay (`afterEventId`) — model for CompanionStateDO event fan-out.
- **Containers:** only for heavy work (Whisper); leave commented until needed.

**Companion mapping:** one `CompanionStateDO` per `user_id`; SQLite events + settings; alarms for morning/noon/chime/eat/evening.

## SignalSci identity (`signalsci-agents/.../identity/`)

- WorkOS AuthKit PKCE: `getAuthorizationUrlWithPKCE` → flow cookie → `/callback` `authenticateWithCode` with `sealSession`.
- Session cookie sealed; `loadSealedSession().authenticate()/refresh()`.
- **Simplify for consumer:** drop org/membership; allow auth without `organizationId`; cookie name `companion_session`.

## Buzz (`~/Documents/buzz`)

- Relay as SoT; append-only events; WebSocket fan-out; reconnect replay from cursor.
- **v1:** adopt event-log + fan-out shape inside CompanionStateDO — not full Nostr protocol.

## Reuse from Dayflow

- `adhd-companion/engine/` day-boundary + orchestrator concepts (simplified for time-based PWA).
- `prompts/checkin.md` + `brief.md` → rewritten with §16.1 doctrine + `model: checkin-fast` / `model: brief-fast` frontmatter.
