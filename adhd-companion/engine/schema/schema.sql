-- ADHD Companion — SQLite schema (contract v2.2 / M1+)
-- Storage root: ~/Library/Application Support/ADHDCompanion/db.sqlite
-- Runtime: prefer WAL (PRAGMA journal_mode=WAL;) — set by the app, not DDL.
-- Day keys use a 4 AM local boundary (Dayflow convention).
-- Schema versioned via app migrations from M1 day one.

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- screenshots: paired capture (JPEG + AX/OCR metadata, same captured_at)
-- Privacy suite may write redacted=1 placeholders or skip row entirely.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS screenshots (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    captured_at             INTEGER NOT NULL,          -- unix seconds (wall clock)
    day                     TEXT NOT NULL,              -- YYYY-MM-DD @ 4AM boundary
    file_path               TEXT,                       -- relative under screenshots/YYYY-MM-DD/; NULL if skipped
    capture_trigger         TEXT NOT NULL,              -- app_switch|window_focus|idle_fallback|idle_return|click|typing_pause|scroll_stop|visual_change
    idle_seconds_at_capture REAL,                       -- HID idle sample at capture
    frontmost_bundle_id     TEXT,
    window_title            TEXT,
    browser_url             TEXT,                       -- optional; Accessibility / enhanced path
    accessibility_text      TEXT,                       -- AX walk (hard timeout ~200ms)
    text_source             TEXT,                       -- ax|ocr|none|thin_ax
    frame_hash              TEXT,                       -- cheap hash/histogram for idle dedupe
    redacted                INTEGER NOT NULL DEFAULT 0, -- 1 = blocklist / incognito / privacy placeholder
    redact_reason           TEXT,                       -- app_blocklist|title_blocklist|incognito|drm|user_skip|…
    display_id              TEXT,                       -- focused display only
    width                   INTEGER,
    height                  INTEGER,
    created_at              INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE INDEX IF NOT EXISTS idx_screenshots_captured_at ON screenshots(captured_at);
CREATE INDEX IF NOT EXISTS idx_screenshots_day ON screenshots(day);
CREATE INDEX IF NOT EXISTS idx_screenshots_trigger ON screenshots(capture_trigger);
CREATE INDEX IF NOT EXISTS idx_screenshots_bundle ON screenshots(frontmost_bundle_id);
CREATE INDEX IF NOT EXISTS idx_screenshots_frame_hash ON screenshots(frame_hash);
CREATE INDEX IF NOT EXISTS idx_screenshots_redacted ON screenshots(redacted);

-- ---------------------------------------------------------------------------
-- observations: slow-path Gemini (or local) descriptions of screenshot batches
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS observations (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    day                     TEXT NOT NULL,
    batch_id                TEXT,                       -- groups ~15 min analyze windows
    screenshot_id           INTEGER REFERENCES screenshots(id) ON DELETE SET NULL,
    observed_at             INTEGER NOT NULL,           -- wall time of observation write
    start_time              INTEGER,                    -- coverage start (unix)
    end_time                INTEGER,                    -- coverage end (unix)
    text                    TEXT NOT NULL,
    app_bundle_id           TEXT,
    confidence              REAL,
    llm_call_id             INTEGER,                    -- optional link to llm_calls
    created_at              INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE INDEX IF NOT EXISTS idx_observations_day ON observations(day);
CREATE INDEX IF NOT EXISTS idx_observations_batch ON observations(batch_id);
CREATE INDEX IF NOT EXISTS idx_observations_observed_at ON observations(observed_at);
CREATE INDEX IF NOT EXISTS idx_observations_screenshot ON observations(screenshot_id);

-- ---------------------------------------------------------------------------
-- timeline_cards: activity cards from slow path (sliding-window replace)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS timeline_cards (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    day                     TEXT NOT NULL,
    start_time              INTEGER NOT NULL,
    end_time                INTEGER NOT NULL,
    title                   TEXT NOT NULL,
    summary                 TEXT,
    category                TEXT,
    status                  TEXT NOT NULL DEFAULT 'active', -- active|replaced|deleted
    priority_id             INTEGER,                    -- optional link to priorities
    observation_ids_json    TEXT,                       -- JSON array of observation ids
    screenshot_ids_json     TEXT,                       -- JSON array of screenshot ids
    llm_call_id             INTEGER,
    replaced_by_id          INTEGER,                    -- sliding-window successor
    created_at              INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    updated_at              INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE INDEX IF NOT EXISTS idx_timeline_cards_day ON timeline_cards(day);
CREATE INDEX IF NOT EXISTS idx_timeline_cards_status ON timeline_cards(status);
CREATE INDEX IF NOT EXISTS idx_timeline_cards_start ON timeline_cards(start_time);
CREATE INDEX IF NOT EXISTS idx_timeline_cards_day_status ON timeline_cards(day, status);

-- ---------------------------------------------------------------------------
-- priorities: morning check-in / soft carryover list
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS priorities (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    day                     TEXT NOT NULL,              -- 4AM day key this list belongs to
    rank                    INTEGER NOT NULL DEFAULT 0,
    text                    TEXT NOT NULL,
    status                  TEXT NOT NULL DEFAULT 'active', -- active|done|dropped|carried|deferred
    outcome_note            TEXT,                       -- evening brief; prefer accomplishment / still-open language
    source                  TEXT,                       -- checkin|carryover|manual|soft_confirm
    carried_from_id         INTEGER REFERENCES priorities(id) ON DELETE SET NULL,
    created_at              INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    updated_at              INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE INDEX IF NOT EXISTS idx_priorities_day ON priorities(day);
CREATE INDEX IF NOT EXISTS idx_priorities_status ON priorities(status);
CREATE INDEX IF NOT EXISTS idx_priorities_day_status ON priorities(day, status);

-- ---------------------------------------------------------------------------
-- nudge_events: orchestrator escalation chain (every transition logged)
-- Levels: idle|L1|L2|L3|cooldown. Persist escalate_after_unix for wake-safe timers.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nudge_events (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    day                     TEXT NOT NULL,
    level                   TEXT NOT NULL,              -- idle|L1|L2|L3|cooldown
    previous_level          TEXT,
    action                  TEXT NOT NULL,              -- present|escalate|ignore|doing_it|snooze|priorities_changed|pause|resolve|suppress|circuit_break
    reason                  TEXT,                       -- guard/suppression why (meeting|quiet_hours|budget|cooldown|low_confidence|…)
    verdict                 TEXT,                       -- aligned|drift|unknown (fast path)
    confidence              TEXT,                       -- low|medium|high
    evidence                TEXT,
    priority_id             INTEGER REFERENCES priorities(id) ON DELETE SET NULL,
    screenshot_id           INTEGER REFERENCES screenshots(id) ON DELETE SET NULL,
    event_anchor            TEXT,                       -- app_switch|window_focus|idle_return|deferred_fire
    presented_at            INTEGER,                    -- when UI/notification shown
    acknowledged_at         INTEGER,                    -- user action time
    escalate_after_unix     INTEGER,                    -- wall-clock deadline (not process-monotonic)
    latency_ms              INTEGER,                    -- decision → present
    metadata_json           TEXT,                       -- truncated extras; never secrets
    created_at              INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE INDEX IF NOT EXISTS idx_nudge_events_day ON nudge_events(day);
CREATE INDEX IF NOT EXISTS idx_nudge_events_level ON nudge_events(level);
CREATE INDEX IF NOT EXISTS idx_nudge_events_action ON nudge_events(action);
CREATE INDEX IF NOT EXISTS idx_nudge_events_created_at ON nudge_events(created_at);
CREATE INDEX IF NOT EXISTS idx_nudge_events_escalate_after ON nudge_events(escalate_after_unix);

-- ---------------------------------------------------------------------------
-- settings: on-disk key/value (rolling companion prefs; secrets stay in Keychain)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS settings (
    key                     TEXT PRIMARY KEY,
    value                   TEXT NOT NULL,
    updated_at              INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

-- Seed keys (app may upsert): companion_enabled, quiet_hours_*, aggressiveness,
-- pause_nudges_until, pause_capture_until, overwhelm_until_day, daily_nudge_budget,
-- checkin_hour, gemini_analysis_opt_in, l2_l3_break_focus, app_blocklist_json,
-- title_blocklist_json, ignore_incognito, pause_on_drm, day_boundary_hour (=4).

-- ---------------------------------------------------------------------------
-- llm_calls: cost / budget logging (timeline vs alignment); never store API keys
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS llm_calls (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    day                     TEXT NOT NULL,
    budget_tag              TEXT NOT NULL,              -- timeline|alignment|checkin|brief|other
    provider                TEXT,                       -- gemini|ollama|lmstudio|…
    model                   TEXT,
    purpose                 TEXT,                       -- analyze_batch|alignment_vision|checkin|brief|…
    status                  TEXT NOT NULL DEFAULT 'ok', -- ok|error|skipped|truncated
    prompt_tokens           INTEGER,
    completion_tokens       INTEGER,
    total_tokens            INTEGER,
    cost_usd                REAL,                       -- estimated; for Settings soft-cap
    latency_ms              INTEGER,
    error_message           TEXT,                       -- truncated; no key material
    request_summary         TEXT,                       -- truncated metadata only
    created_at              INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE INDEX IF NOT EXISTS idx_llm_calls_day ON llm_calls(day);
CREATE INDEX IF NOT EXISTS idx_llm_calls_budget_tag ON llm_calls(budget_tag);
CREATE INDEX IF NOT EXISTS idx_llm_calls_status ON llm_calls(status);
CREATE INDEX IF NOT EXISTS idx_llm_calls_created_at ON llm_calls(created_at);
CREATE INDEX IF NOT EXISTS idx_llm_calls_day_budget ON llm_calls(day, budget_tag);

-- Optional schema_migrations table is owned by app db.rs — not required for M1 stub.
