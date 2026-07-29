# ADHD Companion Web (PWA)

Cross-platform companion for Chromebook, Windows, and mobile browsers.

**Authority:** [`../PLATFORM-RETHINK.md`](../PLATFORM-RETHINK.md) §13.

## Stack

- **apps/web** — React + Vite PWA (Web Speech + TTS, installable)
- **workers/api** — Cloudflare Worker + `CompanionStateDO` (OpenTag-style DO + Buzz-shaped event fan-out)
- **packages/shared** — day boundary, types, prompt doctrine

Auth: WorkOS AuthKit (or `DEV_AUTH_BYPASS=true` for local).  
AI: OpenRouter BYOK via OpenAI-compatible `/chat/completions` (LiteLLM-compatible base URL).

## Local dev

```bash
cd companion-web
npm install
npm run build -w @companion/shared
cp workers/api/.dev.vars.example workers/api/.dev.vars
# Terminal A
npm run dev:api
# Terminal B
npm run dev
```

Open http://localhost:5173 — Sign in uses dev bypass when WorkOS is unset.

## Deploy

1. Create D1 + KV in Cloudflare; put real IDs in `workers/api/wrangler.toml`
2. Set secrets: `WORKOS_*`, `KEY_ENCRYPTION_SECRET`, `VAPID_*`
3. Set `DEV_AUTH_BYPASS=false`, `APP_HOMEPAGE_URL` / `AUTH_REDIRECT_URI` to production
4. `npm run deploy -w @companion/api` and host the web `dist/` (Pages or any static host)

## Web-M0

Fill [`../docs/adhd-companion/WEB_M0_RESULTS.md`](../docs/adhd-companion/WEB_M0_RESULTS.md) on a Chromebook or Windows Chrome device using the Home → device checks panel.
