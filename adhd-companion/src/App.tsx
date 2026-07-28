import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  isPermissionGranted,
  onAction,
  registerActionTypes,
  requestPermission,
} from "@tauri-apps/plugin-notification";

const L1_ACTION_TYPE_ID = "adhd-l1";
const L1_NOTIFICATION_ID = 4101;

type Tab = "timeline" | "checkin" | "brief" | "settings" | "nudge";

type Status = {
  platform: string;
  capture_running: boolean;
  day: string;
  nudge_level: string;
  onboarding_complete: boolean;
  companion_enabled: boolean;
  contract: string;
};

type Screenshot = {
  id: number;
  captured_at: number;
  capture_trigger: string;
  frontmost_bundle_id: string | null;
  window_title: string | null;
  redacted: number;
};

type Card = {
  id: number;
  title: string;
  summary: string | null;
  start_time: number;
  end_time: number;
};

type Priority = { id: number; text: string; status: string };

type Settings = {
  companion_enabled: boolean;
  checkin_hour: number;
  daily_nudge_budget: number;
  nudges_fired_today: number;
  aggressiveness: number;
  gemini_analysis_opt_in: boolean;
  onboarding_complete: boolean;
  pause_nudges_until: number | null;
  pause_capture_until: number | null;
  overwhelm_until: number | null;
  quiet_hours_start: number | null;
  quiet_hours_end: number | null;
  app_blocklist: string[];
  title_blocklist: string[];
  ignore_incognito: boolean;
  pause_on_drm: boolean;
  autostart: boolean;
  l2_l3_break_focus: boolean;
  launch_at_login_requested: boolean;
};

type Brief = {
  day: string;
  accomplishments: string[];
  still_open: string[];
  narrative: string;
};

const TABS: { id: Tab; label: string }[] = [
  { id: "timeline", label: "Timeline" },
  { id: "checkin", label: "Check-in" },
  { id: "brief", label: "Evening brief" },
  { id: "nudge", label: "Nudge" },
  { id: "settings", label: "Settings" },
];

function fmtTime(unix: number): string {
  return new Date(unix * 1000).toLocaleTimeString([], {
    hour: "numeric",
    minute: "2-digit",
  });
}

export default function App() {
  const [tab, setTab] = useState<Tab>("timeline");
  const [status, setStatus] = useState<Status | null>(null);
  const [shots, setShots] = useState<Screenshot[]>([]);
  const [cards, setCards] = useState<Card[]>([]);
  const [priorities, setPriorities] = useState<Priority[]>([]);
  const [checkinText, setCheckinText] = useState("");
  const [settings, setSettings] = useState<Settings | null>(null);
  const [brief, setBrief] = useState<Brief | null>(null);
  const [geminiKey, setGeminiKey] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  async function refresh() {
    try {
      const s = await invoke<Status>("get_status");
      setStatus(s);
      setShots(await invoke("list_screenshots", { day: null }));
      setCards(await invoke("list_timeline", { day: null }));
      setPriorities(await invoke("list_priorities", { day: null }));
      setSettings(await invoke("get_settings"));
      setError("");
    } catch (e) {
      setError(String(e));
    }
  }

  useEffect(() => {
    void refresh();
    // UI refresh only — orchestrator ticks live in Rust runtime threads.
    const id = window.setInterval(() => {
      void refresh();
    }, 15_000);
    return () => window.clearInterval(id);
  }, []);

  // L1 OS notification tap → escalate to L2 and open the nudge surface.
  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | undefined;

    void (async () => {
      try {
        let granted = await isPermissionGranted();
        if (!granted) {
          granted = (await requestPermission()) === "granted";
        }
        if (!granted || cancelled) return;

        await registerActionTypes([
          {
            id: L1_ACTION_TYPE_ID,
            actions: [
              { id: "open", title: "Check in", foreground: true },
            ],
          },
        ]);

        const listener = await onAction(async (notification) => {
          const extra = notification.extra as Record<string, unknown> | undefined;
          const kind = extra?.kind;
          const isL1 =
            kind === "l1" ||
            notification.id === L1_NOTIFICATION_ID ||
            notification.actionTypeId === L1_ACTION_TYPE_ID;
          if (!isL1) return;
          try {
            await invoke("l1_notification_clicked");
            await refresh();
          } catch (e) {
            setError(String(e));
          }
        });
        if (cancelled) {
          await listener.unregister();
          return;
        }
        unlisten = () => {
          void listener.unregister();
        };
      } catch {
        // Non-Tauri / permission-denied environments: L1 click path unavailable.
      }
    })();

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  if (status && !status.onboarding_complete) {
    return (
      <div className="app-shell">
        <section className="onboarding panel">
          <h1 className="brand">ADHD Companion</h1>
          <p className="tagline">
            Screenshots stay on this Mac. Analysis to Google Gemini happens only
            when you add your own key and turn it on. Capture and gentle local
            nudges work without cloud.
          </p>
          <ul className="muted">
            <li>Local-first timeline from screen captures</li>
            <li>Morning priorities + soft evening brief</li>
            <li>Nudges escalate only when confidence is solid</li>
          </ul>
          <div className="row">
            <button
              className="primary"
              onClick={async () => {
                await invoke("complete_onboarding");
                await refresh();
                setMessage("Welcome — capture is on.");
              }}
            >
              Continue
            </button>
          </div>
        </section>
      </div>
    );
  }

  return (
    <div className="app-shell">
      <header>
        <h1 className="brand">ADHD Companion</h1>
        <p className="tagline">
          Day {status?.day ?? "…"} · nudge {status?.nudge_level ?? "idle"} ·
          capture {status?.capture_running ? "on" : "off"} ·{" "}
          <span className="status-pill">{status?.contract ?? "…"}</span>
        </p>
      </header>

      <nav className="nav">
        {TABS.map((t) => (
          <button
            key={t.id}
            className={tab === t.id ? "active" : ""}
            onClick={() => setTab(t.id)}
          >
            {t.label}
          </button>
        ))}
      </nav>

      {message && <p className="muted">{message}</p>}
      {error && <p className="muted" style={{ color: "var(--warn)" }}>{error}</p>}

      {tab === "timeline" && (
        <div className="grid-2">
          <section className="panel">
            <h2>Timeline cards</h2>
            <div className="row">
              <button
                className="primary"
                onClick={async () => {
                  const r = await invoke<{ summary: string }>("run_analyze_cmd", {
                    day: null,
                  });
                  setMessage(r.summary);
                  await refresh();
                }}
              >
                Run analyze
              </button>
              <button className="secondary" onClick={() => void refresh()}>
                Refresh
              </button>
            </div>
            <ul className="list">
              {cards.length === 0 && (
                <li className="muted">No cards yet — capture a bit, then analyze.</li>
              )}
              {cards.map((c) => (
                <li key={c.id}>
                  <strong>{c.title}</strong>
                  <div className="muted">
                    {fmtTime(c.start_time)}–{fmtTime(c.end_time)}
                  </div>
                  {c.summary && <div>{c.summary}</div>}
                </li>
              ))}
            </ul>
          </section>
          <section className="panel">
            <h2>Raw captures</h2>
            <div className="row">
              <button
                className="secondary"
                onClick={async () => {
                  await invoke("inject_capture_event", {
                    event: {
                      trigger: "app_switch",
                      bundle_id: "com.apple.Safari",
                      window_title: "Example — Docs",
                      browser_url: null,
                      idle_seconds: 2,
                      jpeg_base64: null,
                      accessibility_text: "thin ax sample",
                      frame_hash: "stub",
                    },
                  });
                  setMessage("Injected sample capture (dev / Linux stub).");
                  await refresh();
                }}
              >
                Inject sample capture
              </button>
            </div>
            <ul className="list">
              {shots.slice(0, 20).map((s) => (
                <li key={s.id}>
                  <div>
                    {s.window_title ?? s.frontmost_bundle_id ?? "capture"}{" "}
                    {s.redacted ? "(redacted)" : ""}
                  </div>
                  <div className="muted">
                    {fmtTime(s.captured_at)} · {s.capture_trigger}
                  </div>
                </li>
              ))}
            </ul>
          </section>
        </div>
      )}

      {tab === "checkin" && (
        <section className="panel">
          <h2>Morning priorities</h2>
          <p className="muted">
            One intention per line. If you skipped earlier, you can soft-confirm
            yesterday’s list — no shame copy.
          </p>
          <textarea
            rows={6}
            placeholder={"Finish grant draft\nEmail advisor\nWalk outside"}
            value={checkinText}
            onChange={(e) => setCheckinText(e.target.value)}
          />
          <div className="row">
            <button
              className="primary"
              onClick={async () => {
                const lines = checkinText
                  .split("\n")
                  .map((l) => l.trim())
                  .filter(Boolean);
                const r = await invoke<{ priorities_saved: number }>("save_checkin", {
                  priorities: lines,
                });
                setMessage(`Saved ${r.priorities_saved} priorities.`);
                await refresh();
              }}
            >
              Save priorities
            </button>
            <button
              className="secondary"
              onClick={async () => {
                const n = await invoke<number>("soft_confirm_priorities");
                setMessage(
                  n > 0
                    ? `Carried ${n} from yesterday — still good?`
                    : "Nothing to carry (today already has a list).",
                );
                await refresh();
              }}
            >
              Soft-confirm yesterday
            </button>
          </div>
          <ul className="list">
            {priorities.map((p) => (
              <li key={p.id}>
                {p.text} <span className="muted">({p.status})</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {tab === "brief" && (
        <section className="panel">
          <h2>Evening brief</h2>
          <p className="muted">Accomplishments first. Still-open items without shame.</p>
          <button
            className="primary"
            onClick={async () => {
              const b = await invoke<Brief>("run_brief_cmd", { day: null });
              setBrief(b);
            }}
          >
            Generate brief
          </button>
          {brief && (
            <div style={{ marginTop: "1rem" }}>
              <h3>You did</h3>
              <ul>
                {brief.accomplishments.map((a) => (
                  <li key={a}>{a}</li>
                ))}
              </ul>
              <h3>Still open</h3>
              <ul>
                {brief.still_open.length === 0 && <li className="muted">Nothing urgent</li>}
                {brief.still_open.map((a) => (
                  <li key={a}>{a}</li>
                ))}
              </ul>
              <p>{brief.narrative}</p>
            </div>
          )}
        </section>
      )}

      {tab === "nudge" && (
        <section className="panel">
          <h2>Nudge controls</h2>
          <p className="muted">
            Level: <strong>{status?.nudge_level}</strong>. Pause is care-framed —
            not a failure.
          </p>
          <div className="row">
            <button
              className="secondary"
              onClick={async () => {
                await invoke("acknowledge_nudge", { reason: "doing_it" });
                setMessage("Nice — 45m cooldown.");
                await refresh();
              }}
            >
              Doing it
            </button>
            <button
              className="secondary"
              onClick={async () => {
                await invoke("acknowledge_nudge", { reason: "snooze" });
                setMessage("Snoozed 20m.");
                await refresh();
              }}
            >
              Snooze 20m
            </button>
            <button
              className="secondary"
              onClick={async () => {
                await invoke("pause_nudges", { minutes: 30 });
                setMessage("Nudges paused 30m (capture continues).");
                await refresh();
              }}
            >
              Pause nudges 30m
            </button>
            <button
              className="danger"
              onClick={async () => {
                await invoke("pause_watching");
                setMessage("Paused watching — capture + nudges stopped.");
                await refresh();
              }}
            >
              Pause watching
            </button>
            <button
              className="danger"
              onClick={async () => {
                await invoke("overwhelm_until_boundary");
                setMessage("Backing off until next 4 AM. You’re okay.");
                await refresh();
              }}
            >
              Overwhelm (until 4 AM)
            </button>
          </div>
          <div className="row">
            <button
              className="secondary"
              onClick={async () => {
                await invoke("inject_capture_event", {
                  event: {
                    trigger: "app_switch",
                    bundle_id: "com.spotify.client",
                    window_title: "YouTube Music — hits",
                    browser_url: null,
                    idle_seconds: 1,
                    jpeg_base64: null,
                    accessibility_text: null,
                    frame_hash: null,
                  },
                });
                setMessage("Simulated drift capture (Rust runtime will escalate).");
                await refresh();
              }}
            >
              Simulate drift (dev)
            </button>
          </div>
        </section>
      )}

      {tab === "settings" && settings && (
        <section className="panel">
          <h2>Settings</h2>
          <label className="row">
            <input
              type="checkbox"
              checked={settings.companion_enabled}
              onChange={(e) =>
                setSettings({ ...settings, companion_enabled: e.target.checked })
              }
            />
            Companion enabled
          </label>
          <label className="row">
            <input
              type="checkbox"
              checked={settings.gemini_analysis_opt_in}
              onChange={(e) =>
                setSettings({
                  ...settings,
                  gemini_analysis_opt_in: e.target.checked,
                })
              }
            />
            Opt in to Gemini cloud analysis (your key only)
          </label>
          <label className="row">
            <input
              type="checkbox"
              checked={settings.ignore_incognito}
              onChange={(e) =>
                setSettings({ ...settings, ignore_incognito: e.target.checked })
              }
            />
            Skip incognito / private windows
          </label>
          <label className="row">
            <input
              type="checkbox"
              checked={settings.pause_on_drm}
              onChange={(e) =>
                setSettings({ ...settings, pause_on_drm: e.target.checked })
              }
            />
            Pause capture on DRM / streaming focus
          </label>
          <label className="row">
            <input
              type="checkbox"
              checked={settings.autostart}
              onChange={(e) =>
                setSettings({
                  ...settings,
                  autostart: e.target.checked,
                  launch_at_login_requested: e.target.checked,
                })
              }
            />
            Launch at login
          </label>
          <label className="row">
            <input
              type="checkbox"
              checked={settings.l2_l3_break_focus}
              onChange={(e) =>
                setSettings({
                  ...settings,
                  l2_l3_break_focus: e.target.checked,
                })
              }
            />
            L2/L3 nudges break focus (always on top)
          </label>
          <label>
            Quiet hours start (0–23, blank = off)
            <input
              type="number"
              min={0}
              max={23}
              value={settings.quiet_hours_start ?? ""}
              onChange={(e) =>
                setSettings({
                  ...settings,
                  quiet_hours_start:
                    e.target.value === "" ? null : Number(e.target.value),
                })
              }
            />
          </label>
          <label>
            Quiet hours end (0–23, blank = off)
            <input
              type="number"
              min={0}
              max={23}
              value={settings.quiet_hours_end ?? ""}
              onChange={(e) =>
                setSettings({
                  ...settings,
                  quiet_hours_end:
                    e.target.value === "" ? null : Number(e.target.value),
                })
              }
            />
          </label>
          <label>
            App blocklist (one bundle ID per line)
            <textarea
              rows={3}
              value={settings.app_blocklist.join("\n")}
              onChange={(e) =>
                setSettings({
                  ...settings,
                  app_blocklist: e.target.value
                    .split("\n")
                    .map((s) => s.trim())
                    .filter(Boolean),
                })
              }
            />
          </label>
          <label>
            Title blocklist (substring per line)
            <textarea
              rows={3}
              value={settings.title_blocklist.join("\n")}
              onChange={(e) =>
                setSettings({
                  ...settings,
                  title_blocklist: e.target.value
                    .split("\n")
                    .map((s) => s.trim())
                    .filter(Boolean),
                })
              }
            />
          </label>
          <label>
            Check-in hour
            <input
              type="number"
              min={0}
              max={23}
              value={settings.checkin_hour}
              onChange={(e) =>
                setSettings({
                  ...settings,
                  checkin_hour: Number(e.target.value),
                })
              }
            />
          </label>
          <label>
            Daily nudge budget (used {settings.nudges_fired_today})
            <input
              type="number"
              min={1}
              max={50}
              value={settings.daily_nudge_budget}
              onChange={(e) =>
                setSettings({
                  ...settings,
                  daily_nudge_budget: Number(e.target.value),
                })
              }
            />
          </label>
          <label>
            Aggressiveness (0 gentle → 2 assertive)
            <input
              type="number"
              min={0}
              max={2}
              value={settings.aggressiveness}
              onChange={(e) =>
                setSettings({
                  ...settings,
                  aggressiveness: Number(e.target.value) as 0 | 1 | 2,
                })
              }
            />
          </label>
          <div className="row">
            <button
              className="primary"
              onClick={async () => {
                // Backend preserves nudges_fired_today / pause clocks from a stale snapshot.
                const saved = await invoke<Settings>("update_settings", {
                  patch: settings,
                });
                setSettings(saved);
                setMessage("Settings saved.");
              }}
            >
              Save settings
            </button>
            <button
              className="secondary"
              onClick={async () => {
                await invoke("start_capture");
                await refresh();
              }}
            >
              Start capture
            </button>
            <button
              className="secondary"
              onClick={async () => {
                await invoke("stop_capture");
                await refresh();
              }}
            >
              Stop capture
            </button>
          </div>
          <h3>Gemini key (Keychain on Mac / locked file elsewhere)</h3>
          <input
            type="password"
            placeholder="Paste key — never stored in SQLite"
            value={geminiKey}
            onChange={(e) => setGeminiKey(e.target.value)}
          />
          <div className="row">
            <button
              className="secondary"
              onClick={async () => {
                const r = await invoke<string>("store_gemini_key", {
                  key: geminiKey,
                });
                setMessage(`Key: ${r}`);
                setGeminiKey("");
                await refresh();
              }}
            >
              Store key
            </button>
            <button
              className="secondary"
              onClick={async () => {
                await invoke("clear_gemini_key");
                setMessage("Key cleared.");
                await refresh();
              }}
            >
              Clear key
            </button>
          </div>
          <p className="muted">
            Platform: {status?.platform}. Runtime: rust_resident. Privacy suite
            enforces blocklists / incognito / DRM in the capture path.
          </p>
        </section>
      )}
    </div>
  );
}
