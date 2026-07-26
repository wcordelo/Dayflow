# Screenpipe core concepts → ADHD Companion

Primary source: [DeepWiki 1.3 Core Concepts](https://deepwiki.com/screenpipe/screenpipe/1.3-core-concepts)  
Also: [architecture](https://docs.screenpipe.com/architecture), [EVENT_DRIVEN_CAPTURE_SPEC](https://github.com/screenpipe/screenpipe/blob/main/docs/EVENT_DRIVEN_CAPTURE_SPEC.md), [repo](https://github.com/screenpipe/screenpipe).

**Rule:** architecture inspiration only — re-implement; do not vendor their engine or Node-bridge SDK.

## Dayflow gaps these concepts fill

Dayflow already gives us: timer stills (indicator-safe), WAL SQLite, Gemini timeline cards, 4AM day boundary, soft app privacy blocklist, local Application Support layout.

Dayflow does **not** give us (Screenpipe does):

1. **Event-driven capture** — meaningful OS events instead of only a clock  
2. **WindowFocus as distinct from AppSwitch** — tab/document changes inside Chrome etc.  
3. **VisualChange** — passive pixel updates without input  
4. **Paired capture** — screenshot + accessibility text, same timestamp  
5. **AX-first / thin-AX → OCR** — structured UI text without waiting for cloud vision  
6. **Incognito skip** — private browsing never hits disk  
7. **DRM / streaming pause** — Netflix et al. stop capture  
8. **Window-title blocklist** — finer than bundle ID  
9. **Pipe-shaped scheduled `.md` agents** with context injection  
10. **Honest local-first default** with optional cloud — we must match this *ethically* even though Gemini is our timeline brain  

## Mapping

| Screenpipe concept | Our contract |
|---|---|
| Event-driven capture | Candidate **C** preferred |
| Full trigger enum | §1.1.1 including `window_focus` + `visual_change` (C2) |
| Paired capture | §1.1.2 invariant |
| AX → OCR thin fallback | §1.1.2 + fast path |
| WAL + JPEG snapshots | M1 schema/layout |
| FTS5 life-search | Defer optional index — not the product |
| Encryption at rest | Optional M6+ |
| Pipes | Fixed engines with pipe *shape* (§2.4) — no marketplace |
| MCP | Defer M6+ for developer debug |
| Blocklist / incognito / DRM | §4.1 **M1 required** |
| PII ONNX | Deferred after selective-capture suite |
| Audio / `:3030` / Node bridge / heavy RSS | Refuse for v1 |

## ADHD-specific read

Event-driven capture is not just an efficiency trick — it **is** the point-of-performance sensor. The same `app_switch` / `window_focus` / `idle_return` stream that decides *when to photograph* also decides *when a nudge is allowed to fire*. Dayflow’s 10s timer cannot do that.

Incognito + DRM + title blocklists are shame-avoidance infrastructure: capturing private browsing or TV nights into a Gemini timeline is how a beta user deletes the app in week one.
