# Dayflow ADHD Companion — Platform Rethink

**Date:** 2026-07-28  
**Context:** Critical user/advisor Danielle Cosio uses Chromebook and Windows — not Mac. The entire current architecture (ScreenCaptureKit, NSPanel, TCC, Keychain, NSWorkspace) is macOS-only and does not run for her or users like her. This document rethinks the platform strategy from first principles.

---

## 0. Executive Summary

Dayflow's ADHD companion pivots from a Mac-native screen-capture app to a **web-first installable PWA** (React + TypeScript + Vite + a small serverless backend), because the core value Danielle described — voice-first morning intentions, midday reprioritization, evening accomplishment-first reflection, and gentle time-passage chimes — requires zero screen capture and zero native APIs. Screen monitoring (the M0–M4 capture/monitor pipeline) is demoted to an optional native "satellite" for Windows and Mac, shipped later. The portable brain of the existing build — the TypeScript engine, the four prompt files, the state-machine spec, the schema, and the shame-sensitive design doctrine — carries over intact; ScreenCaptureKit, NSPanel, and TCC work is parked, not deleted. Mobile ships first as the same PWA, with a Capacitor wrap as the store-app path if native reliability is ever needed.

---

## 1. The Forcing Function

The existing contract (v2.3) scoped Mac v1 as the only target. That made sense when Mac was the assumed primary user. It doesn't hold when:

- The key advisor and likely representative user runs Chromebook + Windows
- The core value proposition — morning intentions, midday check-ins, evening reflection — does not actually require OS-level screen capture to deliver
- The most requested UX is **spoken input**, which works natively in Chrome browsers on all platforms via the Web Speech API

This is not a minor port. The macOS-specific components are deep: ScreenCaptureKit for capture, NSPanel for floating windows, NSWorkspace for app-switch events, TCC for permissions, and Keychain for secrets. None of these exist on Windows or ChromeOS. A genuine cross-platform strategy requires rethinking the delivery model, not just swapping APIs.

---

## 2. What We've Built (Inventory)

### 2.1 What's Mac-Specific (the problem)

| Component | macOS API | Status on Windows/ChromeOS |
|---|---|---|
| Screen capture | ScreenCaptureKit | Stubbed (`cfg(target_os = "macos")`); not implemented |
| App/window focus events | NSWorkspace notifications | Stubbed; not implemented |
| Floating panel (L2/L3) | NSPanel + CanJoinAllSpaces | Stubbed; Windows has different model |
| Screen recording permission | TCC (Transparency, Consent, Control) | Doesn't exist; Windows uses different UAC model |
| API key storage | macOS Keychain | Not implemented cross-platform |
| Autostart | macOS LaunchAgent | `tauri-plugin-autostart` handles this cross-platform already |

### 2.2 What's Already Portable (the asset)

| Component | Technology | Cross-Platform Status |
|---|---|---|
| Orchestrator state machine | Rust (idle → L1 → L2 → L3 with guards) | **Fully portable** |
| Engine prompts | Markdown (`checkin.md`, `monitor.md`, `brief.md`, `analyze.md`) | **Platform-agnostic** |
| Engine TypeScript mirror | Vitest-tested TS in `engine/` | **Fully portable** |
| SQLite schema + WAL | `rusqlite` (bundled) | **Fully portable** |
| Privacy rules logic | Rust (`privacy.rs`) | **Fully portable** |
| Gemini API client | `ureq` HTTP in Rust | **Fully portable** |
| React/TypeScript UI | Vite + React in WebView | **Already web tech; fully portable** |
| L1 notifications | `tauri-plugin-notification` | **Works on Windows already** |
| DB row, guard, cooldown logic | `db.rs`, `guards.rs`, `orchestrator.rs` | **Fully portable** |
| All engine output schemas (JSON) | JSON schema files | **Fully portable** |

**Key insight:** The non-capture, non-panel logic — which is the majority of the codebase and all of the "ADHD wisdom" encoded into the system — is already portable. The Mac-specific parts are the sensor layer (capture, app events) and the aggressive display layer (NSPanel). The brain is platform-independent.

---

## 3. Rethinking the Product Core

### 3.1 The Screen Capture Assumption Was Wrong for This Use Case

The original architecture assumed screen capture was the primary sensor that would drive nudges. But the Danielle conversation reveals something important: **the core need is not surveillance of what she's doing — it's a caring checkpoint at structured moments of the day**.

Danielle doesn't need the app to detect she's been on Twitter for 20 minutes and interrupt her. She needs:

1. **Morning**: A gentle conversational prompt that helps her decide what matters today, in her own words, spoken not typed
2. **Midday**: A time-aware nudge that simply marks the passage of time ("it's 1pm — how's it going?")
3. **Evening**: A reflection that leads with what she accomplished, never what she failed at

None of these require screen capture. The "drift detection" monitor was built to serve a use case — catching the user mid-distraction — that is actually lower value than the structured check-in loop, and much harder to implement without making the user feel surveilled.

This reframes the architecture: **the check-in loop is the product; screen monitoring is an optional enhancement**.

### 3.2 David's Insight: Time Marking, Not Surveillance

David's framing of ADHD as "motivational inertia" and the clock-that-chimes metaphor is critical. What he described isn't a drift-detection engine — it's a **periodic ambient time signal**: every 15–30 minutes, something says "time is passing." The reminder to eat is similar: not reactive to what the user is doing, but proactive based on the clock alone.

This is much simpler than the current monitor engine and doesn't require knowing what app is in the foreground. A time-based nudge every 15–30 minutes ("Hey — quick check: still working on what you planned?") is lower-friction, lower-surveillance, and more honest about what the app is.

### 3.3 Emotional Regulation is Infrastructure

The meeting surfaced that ADHD affects emotional regulation — zero-to-100 escalation, difficulty exiting bad states, "bad moment → bad day" spiral. The app needs to be a circuit breaker for this, not just a task tracker. This has design implications:

- Tone is not just copywriting polish — it's the core product mechanism
- "Overwhelm" button (already in the design) is critical — needs prominent placement, not buried in settings
- Evening reflection must be accomplishment-led every single time, not configurable
- The "would you say this to a friend?" reframe can be built into check-in responses
- Gratitude prompting is a concrete feature (one sentence at the end of the evening brief: "One thing that went okay today:")

---

## 4. Platform Strategy: Recommended Architecture

### 4.1 Decision: PWA-First, Native-Second

**Recommendation: Build the ADHD companion core as a Progressive Web App (PWA), with an optional native companion for screen monitoring.**

This is not a "settle for less" decision. A PWA is the right primary delivery vehicle for this specific product for these reasons:

**ChromeOS (Danielle's primary device):**
- PWAs install as first-class apps on ChromeOS — they appear in the app launcher, have their own window, and work like native apps
- ChromeOS never fully closes the browser, so Web Push notifications reliably reach the user even when the PWA window is closed — this is a unique ChromeOS advantage no other platform has
- Web Speech API (`SpeechRecognition`) is fully supported in Chrome on ChromeOS, including the new on-device mode (Chrome 139+) for offline speech recognition
- Zero installation friction: no installer, no admin rights, no app store approval

**Windows (Danielle's secondary device):**
- PWA installs from Chrome or Edge with one click
- Web Push notifications work when the browser is running (Chrome/Edge maintain a background process on Windows)
- Voice input works in Chrome and Edge
- For users who want background nudges even when the browser is closed, the native Tauri companion (Phase 2) handles that

**iOS and Android (mobile):**
- PWAs work on iOS Safari (Web Push since iOS 16.4) and Android Chrome
- Voice input works on both
- This gives mobile coverage without any additional development

**Mac (existing users, nice-to-have):**
- The PWA works in Chrome or Safari on Mac
- The existing Tauri macOS app continues to work for users who want native screen capture

### 4.2 What PWA Buys You

| Capability | PWA on ChromeOS | PWA on Windows | PWA on iOS | PWA on Android |
|---|---|---|---|---|
| Install as app | ✅ First-class | ✅ Chrome/Edge | ✅ Safari | ✅ Chrome |
| Push notifications | ✅ Always (browser never exits) | ✅ When browser running | ✅ iOS 16.4+ | ✅ |
| Voice input | ✅ Web Speech API | ✅ Chrome/Edge | ✅ webkit prefix | ✅ Chrome |
| Background sync | ✅ | ✅ | ⚠️ limited | ✅ |
| Offline capable | ✅ Service Worker | ✅ | ✅ | ✅ |
| System tray | ❌ | ❌ | ❌ | ❌ |
| Screen capture | ❌ | ❌ | ❌ | ❌ |
| True background | ❌ | ❌ (needs browser) | ❌ | ❌ |

The system tray and true background operation are the gaps. These matter for the "always-on nudge" use case but not for the structured check-in loop.

### 4.3 What Native Tauri Buys You (Phase 2)

For users who want proactive midday nudges even when the browser isn't open:

| Capability | Tauri v2 Windows | Tauri v2 Mac (existing) |
|---|---|---|
| System tray | ✅ | ✅ |
| Background service | ✅ | ✅ |
| App focus events | ✅ `wineventhook` crate | ✅ NSWorkspace |
| Screen capture | ✅ `windows-capture` crate (WinRT) | ✅ ScreenCaptureKit |
| Floating panel (L2/L3) | ✅ Windows always-on-top (no Spaces problem) | ✅ NSPanel |
| Native notifications | ✅ Toast | ✅ UN |
| ChromeOS | ❌ (not native ChromeOS) | ❌ |

**ChromeOS and Tauri:** Tauri v2 targets Linux, which can run inside ChromeOS's Linux container (Crostini). But this requires the user to enable Linux development environment — a significant barrier for non-developers like Danielle. Tauri is not a viable ChromeOS solution for typical users.

---

## 5. Revised Feature Set for v1 (Cross-Platform MVP)

The v1 is the PWA. Screen monitoring is explicitly out of scope. The nudge mechanism shifts from "drift detection" to "time-based + intention-based."

### 5.1 Core Loop (All Platforms)

**Morning check-in (6–11am, configurable):**
- Voice-first conversational prompt: "What are you hoping to get done today?"
- Set 1–5 priorities in their own words (spoken or typed)
- Soft carryover if yesterday's priorities exist: "Still working from yesterday's list?"
- Self-compassion opener: brief gratitude or positive anchor ("One thing going okay lately:")
- Max 3 minutes — not a planning session, a reset

**Midday time nudge (12–2pm, configurable):**
- Simple ambient message: "Hey — it's around noon. Quick check: still working on what you planned?"
- Not a surveillance report — just a clock chime
- Three responses: "Yes, on it" / "Got sidetracked, back on it" / "I'm overwhelmed"
- Voice reply supported
- No shaming regardless of response; "got sidetracked" gets same positive reinforcement as "on it"
- Time nudge frequency configurable: every 15min / 30min / 60min / "just once at noon"

**Evening reflection (5–9pm, configurable):**
- Accomplishment-first: "Here's what you got done today:" (even if it's small things)
- Priorities reviewed with only: done / progressed / still open — never "failed" or "missed"
- Gentle close: one optional soft forward ("Tomorrow is a fresh start.")
- Gratitude prompt: "One thing that went okay today?" (optional, off by default)
- "Would you say this to a friend?" reframe available if user is being self-critical (explicit button: "I'm being hard on myself")

**Overwhelm button (always visible):**
- Immediate pause, no explanation required
- Care-framed: "Rest mode on. I'll check back tomorrow."
- Clears until next day boundary (4am)
- Prominent in UI at all times, not buried in settings

### 5.2 Features Not in v1 (deliberately deferred)

| Feature | Reason deferred |
|---|---|
| Screen capture | ChromeOS can't do it; not needed for core value |
| Drift detection (monitor engine) | Requires screen/app data; deferred to native companion v2 |
| L2/L3 floating panels | Desktop-native only; PWA uses notifications |
| Timeline/work journal | Dayflow already does this for Mac users |
| Weekly analytics | Low priority vs. daily loop |
| App blocklist/incognito rules | No screen capture in v1 |
| Audio capture | Refused; voice INPUT (speech-to-text) is in scope, audio recording is not |

### 5.3 What's New vs. Existing Spec

These features are added based on Danielle and David's sessions:

1. **15-minute time chime** — simple periodic nudge, no AI inference needed, David's insight
2. **Reminder to eat** — standalone nudge type ("Have you had lunch?"), time-triggered
3. **"Would you say this to a friend?" reframe** — a response mode in the check-in engine when negative self-talk is detected
4. **Gratitude anchor** — optional evening prompt
5. **Voice-first UX** — voice input as the primary, keyboard as secondary; use Web Speech API with fallback to typed input
6. **Accomplishment inventory in morning** — before setting new priorities, acknowledge one thing that went okay recently (reduces shame spiral from seeing incomplete items)

---

## 6. Technical Architecture

### 6.1 PWA Stack

```
┌─────────────────────────────────────────────────────────┐
│  Client (Browser / Installed PWA)                       │
│                                                         │
│  React + TypeScript (reuse from Tauri frontend)         │
│  Web Speech API (voice input)                           │
│  IndexedDB (local priorities, history, settings)        │
│  Service Worker (push notifications, offline cache)      │
│  Web Push API (receive nudges)                          │
└────────────────────┬────────────────────────────────────┘
                     │ HTTPS
┌────────────────────▼────────────────────────────────────┐
│  Backend (Serverless / Edge)                            │
│                                                         │
│  Check-in engine (port from prompts/checkin.md)         │
│  Brief engine (port from prompts/brief.md)              │
│  Nudge scheduler (time-based: noon, 15-min chime)       │
│  Web Push delivery (FCM / VAPID)                        │
│  LiteLLM → OpenRouter proxy (user's own key, §13.3–4)   │
│  User auth (WorkOS AuthKit, §13.2)                      │
│  User data store (Postgres / Supabase / Cloudflare D1)  │
└─────────────────────────────────────────────────────────┘
```

**Backend options (in order of preference for a lean MVP):**

1. **Cloudflare Workers + D1 + Queues**: Edge-native, zero cold starts, D1 is SQLite-compatible (can reuse schema), Queues handles scheduled nudge delivery. Best choice for a serverless MVP.
2. **Supabase + Edge Functions**: Postgres + built-in auth + real-time subscriptions. Faster to bootstrap, slightly more infrastructure.
3. **Self-hosted (Fly.io / Railway)**: Full control, Rust or Node.js API. Good if privacy is a primary concern.

**Recommended for MVP: Cloudflare Workers + D1 + KV.** Reasons: no servers to manage, global edge deployment means low latency everywhere, D1 is SQLite so the schema from `db.rs` ports almost directly, Durable Objects can manage per-user nudge timer state without a dedicated scheduler service.

### 6.2 Voice Input Implementation

```typescript
// Web Speech API — works in Chrome, Edge, Chromebook, Android Chrome
const recognition = new (window.SpeechRecognition || 
                         window.webkitSpeechRecognition)();

recognition.continuous = false;
recognition.interimResults = true;  // Show partial transcription
recognition.lang = 'en-US';

// Chrome 139+ on-device mode (no audio to Google)
if ('available' in recognition) {
  const available = await recognition.available({ 
    processLocally: true, 
    langs: ['en-US'] 
  });
  if (available === 'available') {
    recognition.processLocally = true;
  }
}
```

**Offline / maximum-privacy fallback: Whisper in the browser.** If Chrome's on-device mode is unavailable on Danielle's Chromebook (some users report `language-not-supported` errors on ChromeOS), or a user wants a hard "my voice never leaves this device" guarantee, run Whisper locally via **transformers.js** (ONNX Runtime, WASM with optional WebGPU) or a whisper.cpp WASM wrapper. This is production-viable in 2026 — libraries like `browser-whisper` and `whisper.wasm` handle model loading and WebCodecs decoding — at the cost of a one-time ~40–150 MB model download and slower-than-realtime transcription on low-end Chromebooks without WebGPU. Recommended posture: Web Speech API (cloud) by default with a visible "processed by Google" indicator → on-device Web Speech where available → Whisper-in-browser as the explicit privacy toggle. Skip the `react-speech-recognition` wrapper library — it's a thin, sporadically maintained shim; a ~100-line custom hook gives better control over interim results and the on-device availability check.

UX pattern:
- Large microphone button, prominent in check-in and reflection screens
- Interim results shown as user speaks (streaming transcription)
- "Tap to speak, tap again to done" — not push-to-talk (harder for some ADHD users)
- Graceful fallback to keyboard if speech unavailable (Firefox, older Safari)
- Never force voice; always offer text alternative

### 6.3 Notification Strategy by Platform

**The hard constraint that shapes this whole section:** the web platform has **no client-side scheduled notifications**. The Notification Triggers API was proposed and abandoned; scheduled notifications never entered the Notifications API standard. Periodic Background Sync exists but is Chromium-only with a ~12-hour minimum interval tied to site-engagement score — useless for a 15-minute chime. One-off Background Sync is Chromium-only as well (Firefox disabled, Safari absent). Therefore **every nudge that must arrive while the app is closed comes from our server via Web Push (VAPID)**, and in-app timers handle nudges while the PWA is open. This is the single requirement that forces a backend into the architecture — accept it rather than fighting it. (The Phase-2/3 native wrappers escape this: Capacitor `LocalNotifications` on mobile and the Tauri tray app on Windows can schedule client-side, removing the server dependency for chimes on those platforms.)

**ChromeOS (best case):**
- Web Push via VAPID (server sends push notification)
- Service worker handles notification display even when PWA is closed
- Chrome never exits on ChromeOS → push always received
- Clicking notification opens PWA to check-in or shows inline nudge

**Windows (Chrome/Edge):**
- Web Push works when browser is running
- Chrome and Edge maintain a background process on Windows, so push works even when tab is closed (but not if browser is fully exited)
- For users who fully close Chrome: the 15-minute chime becomes a "next-session catch-up" rather than real-time nudge — this is acceptable
- Encourage pinning the PWA to taskbar and not closing the browser

**iOS:**
- Web Push works since iOS 16.4 (must be installed to home screen as PWA)
- Limited to system notification center; no rich actions

**Android:**
- Web Push works via Chrome → FCM pipeline
- Richer action buttons possible

**Fallback for when push doesn't arrive:**
- Morning check-in is scheduled; if the user opens the app at any point before noon, they get the check-in prompt
- Soft confirm at any first open ("You haven't checked in yet today — want to do that now?")
- This mirrors the existing `soft_confirm_on_open` mode in the checkin engine

### 6.4 Data Model (cloud, adapting from SQLite schema)

```sql
-- Users
users (id, email, created_at, timezone)

-- Daily state
priorities (id, user_id, day_key, text, status, created_at)
-- status: 'active' | 'done' | 'progressed' | 'open' | 'dropped'

-- Check-in sessions
checkin_sessions (id, user_id, day_key, mode, completed_at, voice_transcript, ai_reply)

-- Evening briefs
briefs (id, user_id, day_key, headline, accomplishments_json, outcomes_json, created_at)

-- Nudge events (for orchestrator state, analytics)  
nudge_events (id, user_id, timestamp, type, level, response, day_key)
-- type: 'morning' | 'noon_chime' | '15min_chime' | 'eat_reminder' | 'overwhelm'
-- response: 'doing_it' | 'sidetracked_back' | 'overwhelm' | 'snooze' | null

-- Settings (per-user)
user_settings (user_id, checkin_hour, reflection_hour, chime_frequency_min, 
               eat_reminder_enabled, eat_reminder_hour, overwhelm_until,
               openrouter_key_encrypted, quiet_hours_start, quiet_hours_end,
               nudge_budget_daily, aggressiveness)

-- Push subscriptions (for Web Push)
push_subscriptions (id, user_id, platform, endpoint, p256dh, auth, created_at)
```

### 6.5 Orchestrator State Machine (simplified for PWA)

The existing Rust orchestrator is sophisticated but designed for always-on background operation. For the PWA, the orchestrator simplifies:

```
States: idle → morning_pending → checked_in → noon_chime_pending → 
        afternoon → reflection_pending → reflected → idle

Nudge schedule (server-side cron):
  - morning_pending fires at user.checkin_hour (e.g. 8am in their timezone)
  - noon_chime fires at noon, then every chime_frequency_min until user responds
  - eat_reminder fires at user.eat_reminder_hour if eat_reminder_enabled
  - reflection_pending fires at user.reflection_hour (e.g. 6pm)
  - 4am boundary: reset daily state
```

The L1→L2→L3 escalation ladder simplifies because we don't have drift detection:
- L1: Push notification arrives
- L2 (soft escalation): If no response in 30min, send a follow-up ("Just checking in — still there?")
- L3 equivalent: If no morning check-in by noon, soft confirm on next app open

The TypeScript engine (`adhd-companion/engine/`) can be ported directly to the Cloudflare Worker backend — it's pure TypeScript with no platform dependencies.

### 6.6 Gemini Integration (adapted for cloud)

The current architecture has each user provide their own Gemini API key stored in macOS Keychain. For the PWA:

- User provides their own Gemini API key during onboarding
- Key stored encrypted server-side (Cloudflare KV with AES-256-GCM, key derived from user's session secret)
- All Gemini calls proxied through the backend — key never exposed to the browser
- Alternatively: support Anthropic Claude via same proxy (Claude Haiku for low latency and cost)
- "Local-only" mode: skip AI analysis, use template-based responses for check-in and brief

```
User key flow:
  User pastes key in Settings → HTTPS POST to /api/key → 
  Encrypted + stored in KV → Used for all Gemini/Claude calls 
  on behalf of that user
```

---

## 7. What to Keep vs. Rebuild

### 7.1 Keep As-Is (direct reuse)

| Asset | Where it lives | How to reuse |
|---|---|---|
| Engine prompts | `adhd-companion/prompts/*.md` | Port to backend; inject context the same way |
| TypeScript state machine | `adhd-companion/engine/` | Run in Cloudflare Worker (Deno-compatible) |
| React UI components | `adhd-companion/src/App.tsx` | Move to standalone Vite PWA; remove Tauri imports |
| Check-in, brief schemas | `adhd-companion/schema/` | Same JSON schemas, validated on backend |
| Shame-free copy | All prompt `.md` files | Word-for-word reuse |
| Settings data model | `src/state.rs` types | Port to TypeScript for cloud |
| Guard logic | `src/guards.rs` | Port to TypeScript (server-side guard checks) |
| Nudge event types | DB schema | Map to cloud DB schema |

### 7.2 Adapt for New Context

| Asset | Current state | What to adapt |
|---|---|---|
| SQLite schema | `db.rs` with WAL | Port to cloud DB; D1 is SQLite-compatible, direct port possible |
| Gemini client | `src/gemini.rs` (ureq) | Replace with `fetch()` in Cloudflare Worker |
| Privacy rules | `src/privacy.rs` | Simplify — no screen capture in v1, so app/title blocklist and DRM pause irrelevant |
| Capture events | `src/capture.rs` | Replace with time-based triggers (no screen capture in PWA) |
| Orchestrator timers | Wall-clock Rust | Replace with Cloudflare Cron Triggers (equivalent concept) |
| L1 notify | `tauri-plugin-notification` | Replace with Web Push + VAPID |

### 7.3 Rebuild from Scratch (new for PWA)

| Component | Why new | What to build |
|---|---|---|
| User authentication | Wasn't needed (local app) | WorkOS AuthKit (port from signalsci-agents, §13.2) |
| Web Push infrastructure | Wasn't needed | VAPID key pair, push subscription management, FCM for Android |
| Voice input UI | Wasn't designed | Web Speech API integration, large mic button, interim transcript display |
| Backend API | Wasn't needed (local Tauri IPC) | REST or tRPC endpoints for all operations |
| Service worker | Wasn't needed | Offline caching, background sync, push handler |
| Cloud data persistence | Local SQLite only | Cloudflare D1 or Supabase |
| Encrypted key storage | macOS Keychain | Server-side AES-256-GCM in KV |

### 7.4 Deprecate (macOS-only, not carried forward to PWA)

| Component | Why deprioritized |
|---|---|
| `src-tauri/src/capture.rs` (macOS stubs) | No screen capture in PWA v1 |
| NSPanel L2/L3 windows | macOS-only; no PWA equivalent |
| TCC permission flow | macOS-only |
| ScreenCaptureKit integration | macOS-only |
| `tauri-plugin-autostart` | Replaced by service worker + push |

These are not deleted — the Tauri macOS/Windows native app will eventually need them for Phase 2 screen monitoring. But they are not on the critical path for Danielle or the cross-platform MVP.

---

## 8. Mobile Strategy

### 8.1 Primary Mobile Experience: PWA

The PWA approach gives mobile coverage without separate codebases:

- **Android**: Install from Chrome browser ("Add to Home Screen"), full Web Push support, voice works
- **iOS**: Install from Safari ("Add to Home Screen"), Web Push works (iOS 16.4+, must be installed), voice via webkit prefix

The mobile UI should be designed mobile-first: large buttons, voice input as primary, minimal typing, thumb-reachable overwhelm button.

### 8.2 Why Not React Native or Flutter?

**React Native / Expo:** Strong ecosystem and JS AI libraries, and Expo's web support is genuinely production-grade as of SDK 54+ (Metro bundling, Expo Router static rendering). But Metro still has no first-class PWA/service-worker/Workbox story — Expo's own docs describe PWA support as manual configuration — and RN Web is the wrong abstraction when the primary platform *is* the browser. Expo optimizes for the platforms Danielle doesn't use. A React PWA reuses the existing React codebase directly; React Native would be a parallel project.

**Flutter:** Best rendering performance, true cross-platform. But "Flutter on ChromeOS" in practice means either the Android runtime or Flutter web — i.e., you end up shipping a web/Android app anyway, having paid a full Dart rewrite tax and abandoned the existing TypeScript engine, tests, and React UI. The JS AI library ecosystem is also ahead of Dart's. Poor match for an AI-heavy app in 2026.

**Tauri on ChromeOS (for completeness):** Tauri v2 covers Windows/macOS/Linux/iOS/Android, but a Chromebook would need a Crostini Linux build — off by default, often policy-blocked on managed devices, and many Chromebooks are ARM. Not viable for non-developer users; Tauri stays in the plan only as the Windows/Mac native companion (Phase 2/3).

**Capacitor (the actual store-app path):** if/when App Store or Play Store presence is needed, wrap the *unchanged* web app with Capacitor rather than rewriting in RN. Capacitor gives exactly the plugins the web is weak on — `LocalNotifications` for client-side scheduled chimes (no server dependency), native `SFSpeechRecognizer` on iOS where Safari's speech recognition is weakest — with zero codebase divergence.

**PWA is better than both** for this specific product because:
1. It shares the codebase with the desktop experience (one codebase, all platforms)
2. Web Speech API is available in the browser
3. For the ADHD companion use case, native widget APIs (e.g. native widgets, deep OS integration) aren't needed
4. Time to market is dramatically shorter

### 8.3 Native Mobile Consideration (Future)

If a native mobile app becomes necessary (e.g. iOS home screen widget, Apple Watch haptic reminders, background processing that PWA can't do), React Native is the path because:
- The team already knows React and TypeScript
- The AI/LLM integration is easier than Flutter
- The same backend API would be consumed by both the PWA and the RN app

This is Phase 3 territory — after PWA v1 proves the concept.

---

## 9. Native Windows App (Phase 2): Implementation Plan

For users who want background nudges even when Chrome is closed, the Tauri v2 Windows app delivers this. The existing codebase is already structured correctly — it just needs Windows capture implemented.

### 9.1 Windows Capture (replacing ScreenCaptureKit)

```rust
// Replace capture.rs macOS stub with:
#[cfg(target_os = "windows")]
mod native {
    use windows_capture::{
        capture::GraphicsCaptureSession,
        frame::Frame,
        graphics_capture_api::InternalCaptureControl,
        monitor::Monitor,
        settings::{ColorFormat, CursorCaptureSettings, DrawBorderSettings, Settings},
    };
    
    // Event-driven capture via windows-capture 2.x crate
    // Triggers: SetWinEventHook for SYSTEM_FOREGROUND (app switch)
    // + periodic idle fallback
}

#[cfg(target_os = "windows")]  
mod events {
    use wineventhook::{EventFilter, WindowEventHook};
    
    // Hook SYSTEM_FOREGROUND (app switch) + SYSTEM_MINIMIZEEND (restore)
    // Fan out to existing EventBus
}
```

**Key Windows APIs:**
- `windows-capture` crate (WinRT `Windows.Graphics.Capture`) for screen stills — shows a brief capture indicator, similar to macOS
- `wineventhook` crate (SetWinEventHook) for foreground window events — direct equivalent to NSWorkspace notifications
- Windows.UI.Notifications for Toast notifications (already handled by `tauri-plugin-notification`)

### 9.2 Windows L2/L3 Windows (replacing NSPanel)

Windows doesn't have the macOS Spaces problem, so this is simpler:

- Always-on-top windows with `HWND_TOPMOST` flag — they stay above all other windows
- On Windows there are no separate "Spaces" so fullscreen apps are not an issue
- The NSPanel circuit breaker and gentle mode logic remain the same
- `tauri-plugin-notification` handles L1

### 9.3 Remaining Difference: Keychain → Windows Credential Store

`windows-credential-manager` crate (or `tauri-plugin-stronghold`) replaces macOS Keychain for API key storage. The `secrets.rs` module adds a Windows branch.

### 9.4 What This Means for the Existing M1–M6 Plan

The M1–M6 milestones in the IMPLEMENTATION_CONTRACT.md remain valid for the **native desktop app track** (Mac + Windows). The key change:

- M1 (capture + tray) becomes the shared milestone for Mac AND Windows simultaneously, since they now share the same codebase with OS-specific capture implementations
- The PWA track runs in parallel and ships first (fewer dependencies)
- M0 Mac validation (ScreenCaptureKit + NSPanel) remains valuable for Mac but is no longer a prerequisite for reaching Danielle

---

## 10. Implementation Phases

### Phase 0: Architecture Setup + Device Validation (1 week)

**Web-M0 validation (replaces the Mac M0 runbook for this track)** — a skeleton installable PWA deployed to a real domain, tested on **Danielle's actual Chromebook and Windows machine** before serious build-out:
- (a) Installs to ChromeOS shelf / Windows taskbar; standalone window; badging works
- (b) Web Push arrives with the PWA window closed — including after a reboot (Windows: confirm Chrome/Edge background mode is on; ChromeOS: should be unconditional)
- (c) `SpeechRecognition` round-trip quality with her voice — cloud mode and on-device mode (expect on-device may be unavailable on ChromeOS; note the fallback used)
- (d) `speechSynthesis` voice quality acceptable for spoken prompts
- (e) If her Chromebook is managed (school/enterprise), confirm PWA install + notification permissions aren't policy-blocked

Failures swap tactics, not the roadmap: (c) fails → promote Whisper-in-browser; (b) fails on Windows → fast-track the Tauri tray wrapper. Record results in `docs/adhd-companion/WEB_M0_RESULTS.md`.

**Infrastructure:**
- Set up Cloudflare Workers + D1 + KV project
- Configure user auth (WorkOS AuthKit — port `auth-routes.ts`/`workos-session.ts` from signalsci-agents, §13.2)
- Port D1 schema from `db.rs` (SQLite → D1 is nearly direct)
- Deploy base TypeScript engine to Worker (the `engine/` directory ports cleanly)
- Set up VAPID keys for Web Push
- Wire LiteLLM → OpenRouter proxy endpoint (§13.3)

**Deliverable:** Backend that can accept a priority, call Gemini, and send a push notification

### Phase 1: PWA Core Loop (2–3 weeks)
- Convert `adhd-companion/src/` React UI to standalone Vite PWA (remove Tauri imports, add service worker)
- Add Web Manifest for installability
- Implement voice input UI (Web Speech API) with keyboard fallback
- Morning check-in flow (voice or typed → priorities set)
- Noon chime notification + simple response buttons
- Evening brief (accomplishment-first, shame-free copy)
- Overwhelm button (always visible, clears to next 4am)
- Settings: check-in hour, reflection hour, chime frequency, eat reminder

**Deliverable:** Danielle can install on Chromebook, set morning priorities by speaking, get noon nudge, see evening brief. No screen capture required.

### Phase 2: Polish + Mobile (2 weeks)
- Mobile-first responsive layout
- Voice input polish (interim transcription display, better error handling)
- Self-compassion features: gratitude prompt, "would you say this to a friend?" response mode
- 15-minute chime with eat reminder
- Test on Chromebook, Windows Chrome, Android, iPhone
- Onboarding flow (< 3 screens: "what are you hoping for?", set check-in time, allow notifications)

**Deliverable:** Production-quality PWA. Share with Danielle for feedback.

### Phase 3: Windows Native Companion (4–6 weeks, parallel with Phase 2)
- Wire `wineventhook` + `windows-capture` into existing Tauri v2 `src-tauri/`
- Implement Windows L2/L3 (always-on-top window, no NSPanel needed)
- Port `secrets.rs` to Windows Credential Manager
- PWA data sync with native app (shared cloud backend, same user account)
- Ship as Windows installer (.msi via `tauri-bundler`)

**Deliverable:** Windows users get background nudges and optional drift detection even when Chrome is closed.

### Phase 4: Mac Native (existing track, deprioritized)
- Continue existing M1–M6 (ScreenCaptureKit + NSPanel) for Mac users
- Mac now benefits from the cloud backend built in Phase 0
- Timeline/work journal feature (Dayflow overlap) as premium feature
- Notarized DMG

**Deliverable:** Mac users get the full screen-monitoring experience. Existing Dayflow users are upgrade targets.

### Phase 5: Drift Detection (Long-term)
- Available on native Windows/Mac only (not PWA, not ChromeOS)
- The monitor engine is already written — it becomes a configurable feature for native installs
- Clearly positioned as "deeper insights, requires full app install"
- Screen data stays local; cloud is optional

---

## 11. Privacy Model (Updated)

The shift to cloud changes the privacy posture and must be handled honestly:

### What Changes
- **Check-in transcripts and priorities go to the server** (vs. staying local in Tauri)
- **Gemini/Claude calls proxied through backend** (not directly from user's device)
- **Push subscription (endpoint URL) stored server-side**

### What Stays the Same
- Screen capture data (Phase 3+) stays local to the device — never uploaded
- User provides their own AI API key — we don't share a developer key
- Explicit opt-in for Gemini analysis

### Required Disclosures (Onboarding)
- "Your check-in messages and priorities are stored on our servers to deliver your nudges"
- "Your screen capture data (optional, native app only) stays on your computer"
- "We use your AI API key to generate your responses — we don't store it in plaintext"
- "You can delete all your data at any time from Settings"

### Data Minimization
- Store only what's needed for the loop (priorities, brief summaries, nudge events)
- No raw voice audio stored — transcription only
- Auto-delete after 90 days (configurable)
- GDPR/CCPA delete endpoint from day one

---

## 12. Positioning and Framing

The product repositioning suggested by the research:

**Was:** "Automatic work journal for Mac that catches you when you drift"  
**Is:** "A caring daily companion for ADHD adults — helps you start, navigate, and end your day with less internal noise"

The shift matters for Danielle because:
- "Work journal" implies surveillance and productivity measurement — anxiety-inducing framing for someone with inattentive ADHD and masking history
- "Companion" implies a relationship — something that knows you, cares, and meets you where you are
- "Less internal noise" targets the real problem: executive dysfunction is exhausting because it forces the user to carry all the mental load themselves. Externalizing some of that (the decision of what to focus on, the structure of the day) reduces cognitive overhead without adding shame

This framing also better fits the voice-first interface: you don't journal to a companion, you talk to them.

---

## 13. Decisions (resolved 2026-07-28)

All seven open questions are now decided. Reference implementations live in sibling repos under `~/Documents/` — study them before building.

1. **Backend hosting: Cloudflare Workers + Durable Objects + Containers** (pattern: `~/Documents/opentag`). OpenTag's production topology is the template: one edge Worker per surface, Durable Objects for per-entity state (its `ConversationStateDO`/`SessionEventDO` map directly to a per-user `CompanionStateDO` holding priorities, nudge timers via DO alarms, and escalation state), Cloudflare Containers for anything too heavy for a Worker (its `containers/harness` pattern applies if we ever need a long-running runtime, e.g. Whisper transcription). Wrangler config layout follows `opentag/edge/wrangler.*.toml`. D1 remains the persistence layer.

2. **Auth: WorkOS AuthKit** (pattern: `~/Documents/signalsci-agents/apps/signalsci-api/src/workspace/identity/`). Reuse the SignalSci implementation directly: `@workos-inc/node`, PKCE authorization flow (`getAuthorizationUrlWithPKCE`), sealed-session cookie (theirs: `signalsci_session`; ours: `companion_session`), Hono `/login` + `/callback` routes, session refresh via `loadSealedSession().authenticate()/refresh()`, httpOnly + SameSite=Lax cookies. AuthKit gives Google OAuth for Chromebook users plus email/password out of the box. Files to port: `auth-routes.ts`, `workos-session.ts`, `provisioning.ts` (simplified — no organizations needed for a consumer app; strip the org/membership machinery).

3. **AI layer: LiteLLM proxy + OpenRouter, OpenAI-compatible API.** The backend talks to a single OpenAI-compatible endpoint; LiteLLM routes to OpenRouter, which gives model switching (Claude Haiku, Gemini Flash, GPT-class, open models) with one integration and no per-provider client code. Engines specify a logical model name in prompt frontmatter (`model: checkin-fast`); LiteLLM config maps logical names → concrete OpenRouter models, so swapping models is a config change, not a code change. The existing `gemini.rs`/Gemini-specific client is retired in favor of one `fetch()` to the LiteLLM endpoint.

4. **Pricing/keys: user provides their own API key** (OpenRouter key — one key covers all models). Stored encrypted server-side as previously specified (§6.6); passed through LiteLLM per-request. No bundled AI cost for us, and the §16.3 cost estimate (~$0.30/mo) is the user's spend, worth showing in Settings. Free product during beta.

5. **Cross-device sync: real-time, relay-pattern** (pattern: `~/Documents/buzz`). Buzz's architecture — a single relay as source of truth, append-only signed events by kind, WebSocket fan-out to subscribed clients — is the model, scaled down to one user. Implementation: the per-user `CompanionStateDO` acts as a mini-relay; each device (Chromebook PWA, Windows PWA/native) holds a WebSocket to it; every mutation (priority added, check-in completed, chime answered, overwhelm toggled) is an append-only event fanned out to all connected devices, with D1 as the durable log. Devices reconnecting replay events since their last cursor (buzz's REQ/replay semantics). Full Nostr (signed events, NIP-29) is not needed for v1 — adopt the event-log + fan-out shape, not the protocol; revisit actual Nostr if multi-user/agent features ever appear.

6. **ChromeOS speech: rely on latest Chrome with on-device mode, default to standard cloud speech.** Ship with Chrome's default (server-based) speech recognition as the working path; detect and prefer on-device (`processLocally`) when the latest Chrome reports it available on the device. Phase 0 validates both on Danielle's Chromebook. Whisper-in-browser remains the deep fallback.

7. **Sync cadence: real-time** (subsumed by decision 5 — the WebSocket fan-out makes real-time the natural behavior; no day-boundary batching).

---

## 14. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Web Push unreliable on Windows (browser closed) | Medium | Medium | Educate users to leave browser running; native app is fallback |
| Voice input (Web Speech API) fails on some Chromebooks | Low-Medium | Medium | Always provide keyboard fallback; test on Danielle's device |
| Danielle doesn't like cloud storage of check-ins | Unknown | High | Implement local-only IndexedDB mode early; transparent onboarding |
| Push notification permission not granted | Medium | High | Design app to work without push (user manually opens it); soft re-prompt strategy |
| Gemini API cost surprises user | Low | Medium | Show estimated cost; cap configurable; Claude Haiku alternative is cheaper |
| On-device speech not available (privacy preference) | Low-Medium | Low | Cloud speech fallback (Chrome default); keyboard always available |
| iOS Web Push limitations (must be installed to home screen) | Medium | Low | Clear install instructions; feature works once installed |
| Health-data privacy regulation (WA MHMDA, FTC HBNR) applies | High (it does apply) | High | Treat as covered from day one — see §16.4 |
| Novelty decay: engagement drops by week 3–4 | High | High | Design for decay, not against it — see §16.5 |

---

## 15. Summary

The platform rethink in one sentence: **Build the ADHD companion as a PWA first, using voice input and push notifications, then add optional native screen monitoring for Windows and Mac as a second layer.**

This gets Danielle using the app on her Chromebook immediately, delivers the core value (morning, noon, evening structure) without requiring screen capture, and preserves the existing Rust/TypeScript codebase as the foundation for the native layer that adds deeper monitoring capability for users on supported platforms.

The most important shift is philosophical, not technical: screen capture is an enhancement, not a prerequisite. The companion's primary value is being there at the right moments with the right tone — something a well-designed PWA with push notifications delivers everywhere, without requiring system-level permissions.

---

## 16. Gap Analysis Addendum (2026-07-28, second research pass)

A follow-up deep-research pass identified five significant gaps in the plan above. Each is addressed here.

### 17.1 Evidence Base — the design is clinically grounded, and we should say so

The plan asserted the check-in loop's value from Danielle's testimony alone. The research literature independently supports each pillar:

- **Implementation intentions** (specific, context-bound "when X, I will Y" plans) are one of the best-supported behavioral techniques for adult ADHD. Clinic-referred adults with ADHD report chronic difficulty *executing* intended plans, not forming them — and CBT protocols for adult ADHD explicitly target implementation. The morning check-in is an implementation-intention ritual: it converts vague intent into named, spoken commitments. This is not a soft feature; it is the mechanism.
- **Self-guided digital interventions work for adult ADHD.** The attexis RCT (n=337 adults with confirmed ADHD, Psychological Medicine) showed significantly lower ADHD symptom severity from a fully self-guided CBT/mindfulness digital program. A caring PWA with no human in the loop is a viable intervention class, not a toy.
- **Self-compassion interventions reduce perceived stress** in RCTs, including brief digital writing formats (14-day programs). The gratitude anchor and "would you say this to a friend?" reframe have direct analogues in tested protocols.

**Design rules extracted from the meeting transcript (binding, add to prompt doctrine):**

1. **The accomplishment log is counter-evidence, not a report.** Danielle's manual time log mattered because when she thought "I wrote three sentences all day, I'm a piece of shit," the list proved otherwise. The evening brief's job is to be the evidence the user's self-criticism can't argue with. Concrete > general: "you spent an hour on the proposal outline" beats "you worked hard today."
2. **"Under the guise of productivity."** Danielle's positioning insight verbatim: self-compassion + presence, packaged as a productivity tool. Marketing leads with getting things done; the product delivers being kinder to yourself. Do not market it as a mental-health app (also keeps regulatory claims cleaner — §16.4).
3. **Never ask the user to list things they like about themselves.** Danielle flagged this explicitly as backfiring ("it feels like shit"). Forbidden prompt pattern.
4. **Neutral, not positive.** The target tone is "oblivious to shame" — eliminating instinctive judgment, not forced affirmation. "I'll get this in another size" energy. Add to prompt constraints alongside the existing no-shame rules.
5. **Morning prompts that reduce activation energy:** "What's the easiest thing you can do?" / "What can you finish fastest?" as first-class check-in openers — these directly attack motivational inertia (David's framing: hard to start AND hard to stop).

### 17.2 Voice Output (TTS) — missing from the plan

The plan covered voice *input* only. A conversational companion should be able to speak back — especially for a user who prefers talking over typing, and during hands-busy mornings.

- `window.speechSynthesis` (Web Speech API synthesis half) is supported in every modern browser, including Chrome on ChromeOS since Chrome 33. No permission prompt required.
- Voice quality varies by OS speech engine; ChromeOS system voices are serviceable, and additional voices can come from extensions. Autoplay rules differ per browser — TTS must be triggered by user gesture on first use.
- **v1 decision:** TTS on by default for check-in replies (toggle in settings), using system voices. If voice quality proves alienating on Danielle's Chromebook (Phase 0 validation item), defer to text-only replies or a cloud TTS voice (e.g., Gemini/ElevenLabs) as a paid-tier option.

Add to the Phase 0 device checklist: TTS voice quality check on the actual Chromebook and Windows machine.

### 17.3 Cost Model — unquantified in the plan

Rough per-user AI cost for the core loop (assuming Claude Haiku-class or Gemini Flash-class model, ~1–2K tokens in / ~300 tokens out per interaction):

| Interaction | Frequency | Est. cost/day |
|---|---|---|
| Morning check-in (2–4 turns) | 1×/day | ~$0.005 |
| Midday chime response | 1–3×/day | ~$0.002 |
| Evening brief generation | 1×/day | ~$0.004 |
| **Total** | | **~$0.01/day ≈ $0.30/month/user** |

At this cost, "we include the AI" is viable at even a modest subscription ($5–8/mo) or a generous free tier — the bring-your-own-key model (Open Question 5) is a privacy option, not an economic necessity. The 15-minute chime costs nothing (it's a template push, no AI call).

### 17.4 Regulatory Posture — this is health data, plan accordingly

This gap is real and non-optional:

- **Washington My Health My Data Act (MHMDA)** applies to *any* business serving Washington consumers, regardless of size, and covers "consumer health data" far beyond HIPAA — mental-health-adjacent data like ADHD check-ins and emotional-state reflections almost certainly qualifies. It requires separate consent for collection and for sharing, a consumer health data privacy policy, deletion rights, and carries a **private right of action** (first class action filed Feb 2025). Similar laws exist in Nevada and Connecticut.
- **FTC Health Breach Notification Rule (2024 amendments)** expressly covers health apps not under HIPAA. A breach of check-in data would trigger notification duties.
- **FTC Section 5** governs claims: do not claim the app "treats ADHD" or improves symptoms without competent evidence. Position as a wellness/productivity companion ("helps you plan your day and reflect"), which conveniently matches Danielle's "guise of productivity" framing.

**Day-one requirements (add to Phase 0/1):** separate, unbundled consent screen for collecting check-in data; consumer-health-data privacy policy page; working delete-everything endpoint; no third-party ad/analytics SDKs touching health data (no PostHog until reviewed); data processing agreement with Cloudflare/AI provider; avoid geofencing features entirely. The plan's existing 90-day auto-delete and data-minimization stance already align well.

### 17.5 Engagement Decay — design for week 4, not week 1

The original contract cited the Barkley framing: novelty decays by week 4, and that's the real evaluation window. The PWA plan inherited the week-1 features but no decay strategy. Additions:

- **Variable, not fixed, nudge copy.** The same noon message every day trains the user to ignore it. The AI generates varied phrasings; templates rotate for the no-AI mode.
- **Chime response is optional by design.** The 15-minute chime is ambient (like a clock) — it must never accumulate "unanswered" state or badge counts. A chime you ignore costs nothing socially.
- **Weekly gentle retro (week 2+ feature):** one Sunday-evening message surfacing the week's accomplishment evidence — reinforces the counter-evidence loop at a slower cadence as daily novelty fades.
- **Adaptive backoff:** if the user hasn't opened the app in 3 days, drop to one morning push per day; after 7 days, one soft weekly re-invite. Never guilt-based re-engagement ("we miss you" is fine; "you've lost your streak" is forbidden — no streaks anywhere in the product).
- **Success metric for the Danielle beta:** still voluntarily checking in ≥4 days/week at week 4 — not week-1 enthusiasm.

---

## 17. Sources

Research current as of July 2026:

- **PWA on ChromeOS:** [chromeos.dev — Desktop Progressive Web Apps](https://chromeos.dev/en/web/desktop-progressive-web-apps); [chromeos.dev — Features to take full advantage of PWA installation](https://chromeos.dev/en/posts/features-to-take-full-advantage-of-pwa-installation) (launcher/shelf integration, badging)
- **Web Speech API on-device:** [Chromium Intent to Ship: On-device Web Speech API](https://groups.google.com/a/chromium.org/g/blink-dev/c/VNOok2dbmHM); [on-device speech recognition explainer](https://github.com/WebAudio/web-speech-api/blob/main/explainers/on-device-speech-recognition.md); [MDN — SpeechRecognition](https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition) (default is server-based; on-device via `processLocally` + language packs; ChromeOS language-support gaps reported)
- **Whisper in the browser:** [AssemblyAI — Offline speech recognition with Whisper (browser + Node)](https://www.assemblyai.com/blog/offline-speech-recognition-whisper-browser-node-js); [browser-whisper (WebGPU/WASM)](https://github.com/tanpreetjolly/browser-whisper); [whisper.wasm (whisper.cpp wrapper)](https://github.com/timur00kh/whisper.wasm)
- **Push / scheduling constraints:** [Advanced PWA features: offline, push, background sync](https://rishikc.com/articles/advanced-pwa-features-offline-push-background-sync/) (Periodic Background Sync ~12h minimum, Chromium-only; Background Sync absent in Safari/Firefox); [MagicBell — Push notifications in PWAs](https://www.magicbell.com/blog/using-push-notifications-in-pwas); [Microsoft Edge — PWA notifications and badges](https://learn.microsoft.com/en-IE/microsoft-edge/progressive-web-apps-chromium/how-to/notifications-badges)
- **iOS PWA state:** [MagicBell — PWA iOS limitations & Safari support 2026](https://www.magicbell.com/blog/pwa-ios-limitations-safari-support-complete-guide) (iOS 26 web-app mode default, Declarative Web Push in Safari 18.4+)
- **Frameworks:** [Tauri 2.0 stable announcement](https://v2.tauri.app/blog/tauri-20/) (desktop + iOS/Android; 2.11.x line as of July 2026); [Expo — web development docs](https://docs.expo.dev/workflow/web/) and [Expo — PWA docs](https://docs.expo.dev/guides/progressive-web-apps/) (no first-class Metro PWA support); [React Native Web + Expo guide 2026](https://reactnativerelay.com/article/react-native-web-expo-cross-platform-2026); [Flutter — targeting ChromeOS with Android](https://docs.flutter.dev/platform-integration/android/chromeos); [Google — end of support for Chrome Apps](https://support.google.com/chrome/a/answer/15950395?hl=en)
- **Windows capture (Phase 2/3 satellite):** [Microsoft — Windows.Graphics.Capture screen capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture) (system-drawn capture border — the "orange pill" concern ported); [windows-capture crate](https://docs.rs/windows-capture)

Gap-analysis pass (§16):

- **Evidence base:** [attexis digital CBT RCT for adult ADHD — Psychological Medicine](https://www.cambridge.org/core/journals/psychological-medicine/article/effectiveness-of-attexis-a-digital-intervention-based-on-cognitive-behavioral-therapy-for-adults-with-adhd-a-randomized-controlled-trial/BBB55FF99ADF58005B1BD9B00AD0AF96); [APSARD — Managing ADHD: What is Your Implementation Plan?](https://apsard.org/managing-adhd-what-is-your-implementation-plan/); [Self-compassion intervention RCT for perceived stress](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12926457/); [Frontiers — Digital health technologies for adults with ADHD: scoping review](https://www.frontiersin.org/journals/digital-health/articles/10.3389/fdgth.2026.1746732/full)
- **Regulatory:** [Usercentrics — Washington My Health My Data Act guide](https://usercentrics.com/knowledge-hub/washington-my-health-my-data-act-guide/); [Manatt — MHMDA: What to Know](https://www.manatt.com/washingtons-my-health-my-data-act-what-to-know); [FTC — Updated Health Breach Notification Rule](https://www.ftc.gov/business-guidance/blog/2024/04/updated-ftc-health-breach-notification-rule-puts-new-provisions-place-protect-users-health-apps); [FTC — Mobile Health App Interactive Tool](https://www.ftc.gov/business-guidance/resources/mobile-health-apps-interactive-tool)
- **TTS:** [Chromium — Text to Speech in Chrome and ChromeOS](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/accessibility/browser/tts.md); [SpeechSynthesis browser/OS support matrix](https://readium.org/speech/docs/WebSpeech.html)
