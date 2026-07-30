import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api, wsUrl, type ServerState } from "./api";
import { speak, speechSupported, startListening } from "./speech";

type Tab = "home" | "morning" | "midday" | "evening" | "settings";

type ChatTurn = { role: "me" | "them"; text: string };

export function App() {
  const [tab, setTab] = useState<Tab>("home");
  const [user, setUser] = useState<{ id: string; email?: string } | null>(null);
  const [state, setState] = useState<ServerState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [consentOpen, setConsentOpen] = useState(false);
  const [listening, setListening] = useState(false);
  const [draft, setDraft] = useState("");
  const [chat, setChat] = useState<ChatTurn[]>([]);
  const [brief, setBrief] = useState<{
    headline?: string;
    accomplishments?: string[];
    gentle_close?: string;
    gratitude_prompt?: string;
  } | null>(null);
  const [gratitude, setGratitude] = useState("");
  const [orkey, setOrkey] = useState("");
  const [webM0, setWebM0] = useState({
    speech: speechSupported(),
    tts: typeof window !== "undefined" && !!window.speechSynthesis,
    notification: typeof Notification !== "undefined" ? Notification.permission : "unsupported",
    standalone: window.matchMedia("(display-mode: standalone)").matches,
  });

  const tts = state?.settings.ttsEnabled ?? true;
  const hasConsent = state?.settings.healthDataConsent ?? false;
  const overwhelmed = !!(state?.settings.overwhelmUntil && state.settings.overwhelmUntil * 1000 > Date.now());
  const listenRef = useRef<{ stop: () => void } | null>(null);
  const stateRef = useRef<ServerState | null>(null);
  useEffect(() => {
    stateRef.current = state;
  }, [state]);

  useEffect(() => {
    if (!state) return;
    setBrief(state.lastBrief ? (state.lastBrief as typeof brief) : null);
  }, [state?.lastBrief, state?.dayKey]);

  const refresh = useCallback(async () => {
    try {
      const me = await api<{ user: { id: string; email?: string } | null }>("/api/auth/me");
      setUser(me.user);
      if (!me.user) return;
      const s = await api<ServerState>("/api/state");
      setState(s);
      if (!s.settings.healthDataConsent) setConsentOpen(true);
      const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
      if (!s.settings.ianaTimeZone && tz) {
        const updated = await api<{ state: ServerState }>("/api/settings", {
          method: "POST",
          body: JSON.stringify({ ianaTimeZone: tz }),
        });
        setState(updated.state);
      }
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load");
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Real-time nudge relay (CompanionStateDO WebSocket).
  useEffect(() => {
    if (!user) return;
    const socketUrl = wsUrl("/api/ws");
    let ws: WebSocket | null = null;
    let closed = false;
    let retry: number | undefined;

    const connect = () => {
      if (closed) return;
      ws = new WebSocket(socketUrl);
      ws.onmessage = (ev) => {
        try {
          const msg = JSON.parse(String(ev.data)) as {
            type: string;
            kind?: string;
            state?: ServerState;
          };
          if (msg.type === "hello" && msg.state) setState(msg.state);
          if (msg.type === "event" && msg.state) setState(msg.state);
          if (msg.type === "engagement_backoff" && msg.state) setState(msg.state);
          if (msg.type === "nudge_due" && "Notification" in window && Notification.permission === "granted") {
            void (async () => {
              if ("serviceWorker" in navigator) {
                try {
                  const reg = await navigator.serviceWorker.ready;
                  if (await reg.pushManager.getSubscription()) return;
                } catch {
                  /* fall through to in-app notification */
                }
              }
              const copy =
                msg.kind === "morning"
                  ? "Gentle morning check-in when you're ready."
                  : msg.kind === "evening"
                    ? "Evening reflection — what went okay today?"
                    : msg.kind === "eat"
                      ? "Have you eaten something today?"
                      : "Quick time check — how's it going?";
              new Notification("Companion", { body: copy, tag: `companion-${msg.kind ?? "chime"}` });
            })();
          }
        } catch {
          /* ignore */
        }
      };
      ws.onclose = () => {
        if (!closed) retry = window.setTimeout(connect, 4000);
      };
    };
    connect();
    return () => {
      closed = true;
      if (retry) clearTimeout(retry);
      ws?.close();
    };
  }, [user]);

  useEffect(() => {
    const id = window.setInterval(() => {
      setWebM0((w) => ({
        ...w,
        notification: typeof Notification !== "undefined" ? Notification.permission : "unsupported",
        standalone: window.matchMedia("(display-mode: standalone)").matches,
      }));
    }, 3000);
    return () => clearInterval(id);
  }, []);

  async function login() {
    window.location.href = "/api/auth/login";
  }

  async function acceptConsent() {
    await api("/api/consent", {
      method: "POST",
      body: JSON.stringify({ healthDataConsent: true }),
    });
    setConsentOpen(false);
    await refresh();
  }

  async function mutate(kind: string, payload: unknown) {
    const res = await api<{ state: ServerState }>("/api/mutate", {
      method: "POST",
      body: JSON.stringify({ kind, payload }),
    });
    setState(res.state);
  }

  async function runAi(engine: "checkin" | "brief" | "midday", message?: string) {
    const s = stateRef.current;
    const now = new Date();
    const context = {
      now_local: now.toISOString(),
      day_key: s?.dayKey ?? null,
      priorities: s?.priorities ?? [],
      yesterday_priorities: (s?.yesterdayPriorities ?? []).map((p) => ({
        id: p.id,
        text: p.text,
        status_hint: p.status,
      })),
      dayLog: s?.dayLog ?? [],
      timeline_cards: (s?.dayLog ?? []).map((note, i) => ({
        id: `log-${i}`,
        text: note,
        kind: "day_log",
      })),
      mode: engine === "checkin" ? "soft_confirm_on_open" : engine,
    };
    const res = await api<{ result: Record<string, unknown>; source: string }>("/api/ai/" + engine, {
      method: "POST",
      body: JSON.stringify({
        message,
        context,
      }),
    });
    return res;
  }

  async function sendMorning() {
    const text = draft.trim();
    if (!text) return;
    setChat((c) => [...c, { role: "me", text }]);
    setDraft("");
    const res = await runAi("checkin", text);
    const reply = String(res.result.reply ?? "I'm here with you.");
    setChat((c) => [...c, { role: "them", text: reply }]);
    speak(reply, tts);
    const rawPriorities = res.result.priorities as
      | Array<{ id?: string | null; text: string; action: string }>
      | undefined;
    const wantsClear =
      res.result.clear_priorities === true ||
      (Array.isArray(rawPriorities) &&
        rawPriorities.length === 0 &&
        /\b(start fresh|clear (my )?(list|priorities|intentions)|reset (my )?list)\b/i.test(text));
    if (wantsClear) {
      await mutate("priority_set", { priorities: [] });
    } else if (rawPriorities !== undefined && rawPriorities.length > 0) {
      const dropIds = new Set(
        rawPriorities.filter((p) => p.action === "drop" && p.id).map((p) => p.id!),
      );
      const dropTexts = new Set(
        rawPriorities
          .filter((p) => p.action === "drop" && p.text?.trim())
          .map((p) => p.text.trim().toLowerCase()),
      );
      let next = (stateRef.current?.priorities ?? []).filter(
        (p) => !dropIds.has(p.id) && !dropTexts.has(p.text.trim().toLowerCase()),
      );
      for (const p of rawPriorities.filter((p) => p.action !== "drop" && p.text?.trim())) {
        const trimmed = p.text.trim();
        if ((p.action === "edit" || p.action === "keep") && p.id) {
          const idx = next.findIndex((e) => e.id === p.id);
          if (idx >= 0) {
            next[idx] = { ...next[idx], text: trimmed, status: "active" };
            continue;
          }
        }
        const key = trimmed.toLowerCase();
        const idx = next.findIndex((e) => e.text.trim().toLowerCase() === key);
        if (idx >= 0) {
          next[idx] = { ...next[idx], text: trimmed, status: "active" };
        } else {
          next.push({
            id: p.action === "keep" && p.id ? p.id : crypto.randomUUID(),
            text: trimmed,
            status: "active" as const,
            source: "checkin",
          });
        }
      }
      const changed =
        dropIds.size > 0 ||
        dropTexts.size > 0 ||
        rawPriorities.some((p) => p.action !== "drop" && p.text?.trim());
      if (changed) await mutate("priority_set", { priorities: next });
    }
    if (res.result.needs_user_input !== true) {
      await mutate("checkin_completed", { reply, source: res.source });
    }
  }

  async function sendMidday() {
    const text = draft.trim();
    if (!text) return;
    setChat((c) => [...c, { role: "me", text }]);
    setDraft("");
    await mutate("chime_answered", { response: text });
    const res = await runAi("midday", text);
    const reply = String(res.result.reply ?? "Thanks for checking in.");
    setChat((c) => [...c, { role: "them", text: reply }]);
    speak(reply, tts);
  }

  async function startMorning() {
    setTab("morning");
    setChat([]);
    const res = await runAi("checkin", "");
    const reply = String(res.result.reply ?? "What's the easiest thing you can do today?");
    setChat([{ role: "them", text: reply }]);
    speak(reply, tts);
  }

  async function runMidday() {
    setTab("midday");
    const res = await runAi("midday", "");
    const reply = String(res.result.reply ?? "Quick check — how's it going?");
    setChat([{ role: "them", text: reply }]);
    speak(reply, tts);
  }

  async function answerChime(response: string) {
    await mutate("chime_answered", { response });
    const res = await runAi("midday", response);
    const reply = String(res.result.reply ?? "Thanks for checking in.");
    setChat((c) => [...c, { role: "me", text: response }, { role: "them", text: reply }]);
    speak(reply, tts);
  }

  async function runEvening() {
    setTab("evening");
    const s = stateRef.current;
    const payload = JSON.stringify({
      now_local: new Date().toISOString(),
      day_key: s?.dayKey ?? null,
      priorities: s?.priorities ?? [],
      day_log: s?.dayLog ?? [],
      timeline_cards: (s?.dayLog ?? []).map((note, i) => ({
        id: `log-${i}`,
        text: note,
        kind: "day_log",
      })),
    });
    const res = await runAi("brief", payload);
    const result = res.result as typeof brief;
    setBrief(result);
    await mutate("brief_generated", result);
    const speakText = [result?.headline, ...(result?.accomplishments ?? []).slice(0, 2)]
      .filter(Boolean)
      .join(". ");
    if (speakText) speak(speakText, tts);
  }

  async function friendReframe() {
    const res = await runAi(
      "checkin",
      "I'm being hard on myself. Use the would-you-say-this-to-a-friend reframe gently.",
    );
    const reply = String(res.result.reply ?? "Would you say that to a friend?");
    setChat((c) => [...c, { role: "them", text: reply }]);
    await mutate("friend_reframe", { reply });
    speak(reply, tts);
  }

  function toggleMic() {
    if (listening) {
      listenRef.current?.stop();
      listenRef.current = null;
      setListening(false);
      return;
    }
    setListening(true);
    const handle = startListening({
      onPartial: (t) => setDraft(t),
      onFinal: (t) => {
        setDraft(t);
        listenRef.current = null;
        setListening(false);
      },
      onError: (e) => {
        setError(e);
        listenRef.current = null;
        setListening(false);
      },
    });
    if (!handle) setListening(false);
    else listenRef.current = handle;
  }

  async function overwhelm() {
    await mutate("overwhelm_on", {});
    speak("Rest mode on. I'll check back tomorrow.", tts);
  }

  async function saveSettings(patch: Partial<ServerState["settings"]>) {
    const res = await api<{ state: ServerState }>("/api/settings", {
      method: "POST",
      body: JSON.stringify(patch),
    });
    setState(res.state);
  }

  async function saveKey() {
    await api("/api/keys/openrouter", { method: "POST", body: JSON.stringify({ apiKey: orkey }) });
    setOrkey("");
    await refresh();
  }

  async function deleteData() {
    if (!confirm("Delete all your companion data? This cannot be undone.")) return;
    await api("/api/me/data", { method: "DELETE" });
    await refresh();
  }

  async function enableNotifications() {
    if (!("Notification" in window)) return;
    const perm = await Notification.requestPermission();
    setWebM0((w) => ({ ...w, notification: perm }));
    if (perm === "granted" && "serviceWorker" in navigator) {
      try {
        const reg = await navigator.serviceWorker.ready;
        const keyRes = await api<{ publicKey: string | null }>("/api/vapid-public-key");
        if (keyRes.publicKey) {
          const sub = await reg.pushManager.subscribe({
            userVisibleOnly: true,
            applicationServerKey: urlBase64ToUint8Array(keyRes.publicKey),
          });
          await api("/api/push/subscribe", { method: "POST", body: JSON.stringify(sub) });
        } else {
          // Local smoke notification for Web-M0 without VAPID
          new Notification("Companion", { body: "Notifications work on this device." });
        }
      } catch (e) {
        setError(e instanceof Error ? e.message : "push failed");
      }
    }
  }

  const title = useMemo(() => {
    if (tab === "morning") return "Morning intentions";
    if (tab === "midday") return "Time check";
    if (tab === "evening") return "Evening reflection";
    if (tab === "settings") return "Settings";
    return "Companion";
  }, [tab]);

  if (!user) {
    return (
      <div className="app">
        <header className="top">
          <h1 className="brand">Companion</h1>
        </header>
        <section className="panel">
          <p>A caring daily companion for ADHD adults — start, navigate, and end the day with less internal noise.</p>
          <p className="muted">Works as an installable app on Chromebook, Windows Chrome, and phones.</p>
          <div className="row" style={{ marginTop: "1rem" }}>
            <button className="btn" type="button" onClick={() => void login()}>
              Sign in
            </button>
          </div>
          {error && <p className="muted">{error}</p>}
        </section>
      </div>
    );
  }

  return (
    <div className="app">
      <header className="top">
        <div>
          <h1 className="brand">{title}</h1>
          <div className="muted">
            Day {state?.dayKey ?? "…"} · {overwhelmed ? "Rest mode" : "Active"}
          </div>
        </div>
        <button className="btn danger" type="button" onClick={() => void overwhelm()}>
          Overwhelm
        </button>
      </header>

      {consentOpen && (
        <section className="panel">
          <h2>Health data consent</h2>
          <p className="muted">
            Check-ins and reflections may be considered consumer health data. We store them to deliver your
            companion loop. We do not claim to treat ADHD. Read the{" "}
            <a href="/api/privacy" target="_blank" rel="noreferrer">
              privacy notice
            </a>
            .
          </p>
          <div className="row">
            <button className="btn" type="button" onClick={() => void acceptConsent()}>
              I agree
            </button>
          </div>
        </section>
      )}

      {tab === "home" && (
        <>
          <section className="panel">
            <p className="muted">Today&apos;s intentions</p>
            <ul className="list">
              {(state?.priorities ?? []).map((p) => (
                <li key={p.id}>
                  <span>{p.text}</span>
                  <span className="pill">{p.status}</span>
                </li>
              ))}
              {!state?.priorities?.length && <li className="muted">No priorities yet — try morning check-in.</li>}
            </ul>
            <div className="row" style={{ marginTop: "0.75rem" }}>
              <button className="btn" type="button" onClick={() => void startMorning()} disabled={!hasConsent}>
                Morning
              </button>
              <button className="btn secondary" type="button" onClick={() => void runMidday()} disabled={!hasConsent}>
                Midday
              </button>
              <button className="btn secondary" type="button" onClick={() => void runEvening()} disabled={!hasConsent}>
                Evening
              </button>
              {state?.settings.eatReminderEnabled && (
                <button
                  className="btn ghost"
                  type="button"
                  disabled={!hasConsent}
                  onClick={() => {
                    speak("Gentle reminder — have you eaten something today?", tts);
                    void mutate("day_log_note", { note: "Eat nudge shown" });
                  }}
                >
                  Eat nudge
                </button>
              )}
            </div>
          </section>
          <section className="panel">
            <p className="muted">Day log (counter-evidence)</p>
            <ul className="list">
              {(state?.dayLog ?? []).map((n, i) => (
                <li key={i}>{n}</li>
              ))}
              {!state?.dayLog?.length && <li className="muted">Notes you add appear here.</li>}
            </ul>
            <div className="row">
              <input
                type="text"
                placeholder="I spent 20 minutes outlining…"
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
              />
              <button
                className="btn secondary"
                type="button"
                disabled={!hasConsent}
                onClick={() => {
                  const note = draft.trim();
                  if (!note) return;
                  void mutate("day_log_note", { note }).then(() => setDraft(""));
                }}
              >
                Add
              </button>
            </div>
          </section>
          <section className="panel">
            <p className="muted">Web-M0 device checks (for Chromebook / Windows validation)</p>
            <ul className="list">
              <li>
                SpeechRecognition <span className="pill">{webM0.speech ? "ok" : "missing"}</span>
              </li>
              <li>
                speechSynthesis <span className="pill">{webM0.tts ? "ok" : "missing"}</span>
              </li>
              <li>
                Notification permission <span className="pill">{String(webM0.notification)}</span>
              </li>
              <li>
                Installed PWA <span className="pill">{webM0.standalone ? "yes" : "browser tab"}</span>
              </li>
            </ul>
            <button className="btn secondary" type="button" onClick={() => void enableNotifications()}>
              Enable notifications
            </button>
          </section>
        </>
      )}

      {(tab === "morning" || tab === "midday") && (
        <section className="panel">
          {chat.map((t, i) => (
            <div key={i} className={`bubble ${t.role === "me" ? "me" : "them"}`}>
              {t.text}
            </div>
          ))}
          {tab === "midday" && (
            <div className="row" style={{ margin: "0.75rem 0" }}>
              <button
                className="btn secondary"
                type="button"
                disabled={!hasConsent}
                onClick={() => void answerChime("Yes, on it")}
              >
                On it
              </button>
              <button
                className="btn secondary"
                type="button"
                disabled={!hasConsent}
                onClick={() => void answerChime("Got sidetracked, back on it")}
              >
                Sidetracked
              </button>
              <button className="btn danger" type="button" onClick={() => void overwhelm()}>
                Overwhelm
              </button>
            </div>
          )}
          <textarea
            rows={3}
            placeholder={speechSupported() ? "Type or tap the mic…" : "Type here…"}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
          />
          <div className="row" style={{ marginTop: "0.75rem" }}>
            <button
              className={`mic ${listening ? "live" : ""}`}
              type="button"
              onClick={toggleMic}
              disabled={!hasConsent}
            >
              {listening ? "…" : "🎤"}
            </button>
            <button
              className="btn"
              type="button"
              onClick={() => void (tab === "midday" ? sendMidday() : sendMorning())}
              disabled={!hasConsent || !draft.trim()}
            >
              Send
            </button>
            <button className="btn ghost" type="button" onClick={() => void friendReframe()} disabled={!hasConsent}>
              I&apos;m being hard on myself
            </button>
          </div>
        </section>
      )}

      {tab === "evening" && (
        <section className="panel">
          {!brief && (
            <button className="btn" type="button" onClick={() => void runEvening()} disabled={!hasConsent}>
              Reflect on today
            </button>
          )}
          {brief && (
            <>
              <h2>{brief.headline}</h2>
              <ul>
                {(brief.accomplishments ?? []).map((a, i) => (
                  <li key={i}>{a}</li>
                ))}
              </ul>
              <p className="muted">{brief.gentle_close}</p>
              <p>{brief.gratitude_prompt ?? "One thing that went okay today?"}</p>
              <input value={gratitude} onChange={(e) => setGratitude(e.target.value)} placeholder="Optional" />
              <div className="row" style={{ marginTop: "0.75rem" }}>
                <button
                  className="btn secondary"
                  type="button"
                  disabled={!hasConsent}
                  onClick={() => {
                    if (!gratitude.trim()) return;
                    void mutate("gratitude", { text: gratitude.trim() }).then(() => setGratitude(""));
                  }}
                >
                  Save gratitude
                </button>
              </div>
            </>
          )}
        </section>
      )}

      {tab === "settings" && state && (
        <section className="panel">
          <label className="muted">Check-in hour</label>
          <input
            type="number"
            min={0}
            max={23}
            key={`checkin-${state.settings.checkinHour}`}
            defaultValue={state.settings.checkinHour}
            onBlur={(e) => void saveSettings({ checkinHour: Number(e.target.value) })}
          />
          <label className="muted">Reflection hour</label>
          <input
            type="number"
            min={0}
            max={23}
            key={`reflection-${state.settings.reflectionHour}`}
            defaultValue={state.settings.reflectionHour}
            onBlur={(e) => void saveSettings({ reflectionHour: Number(e.target.value) })}
          />
          <label className="muted">Chime every N minutes (blank = off)</label>
          <input
            type="number"
            min={15}
            placeholder="30"
            key={`chime-${state.settings.chimeFrequencyMin}`}
            defaultValue={state.settings.chimeFrequencyMin ?? ""}
            onBlur={(e) =>
              void saveSettings({
                chimeFrequencyMin: e.target.value ? Number(e.target.value) : null,
              })
            }
          />
          <div className="row" style={{ marginTop: "0.75rem" }}>
            <label>
              <input
                type="checkbox"
                checked={state.settings.eatReminderEnabled}
                onChange={(e) => void saveSettings({ eatReminderEnabled: e.target.checked })}
              />{" "}
              Eat reminder
            </label>
            <label>
              <input
                type="checkbox"
                checked={state.settings.ttsEnabled}
                onChange={(e) => void saveSettings({ ttsEnabled: e.target.checked })}
              />{" "}
              Speak replies (TTS)
            </label>
          </div>
          {state.settings.eatReminderEnabled && (
            <>
              <label className="muted">Eat reminder hour</label>
              <input
                type="number"
                min={0}
                max={23}
                key={`eat-${state.settings.eatReminderHour}`}
                defaultValue={state.settings.eatReminderHour}
                onBlur={(e) => void saveSettings({ eatReminderHour: Number(e.target.value) })}
              />
            </>
          )}
          <p className="muted" style={{ marginTop: "0.75rem" }}>
            This week ({state.settings.engagement?.weekKey ?? "…"}):{" "}
            {state.settings.engagement?.checkinsThisWeek ?? 0} days with a check-in (goal ≥4). Soft backoff if
            nudges go
            unanswered — never shame, just quieter for a day.
          </p>
          <label className="muted">OpenRouter API key (BYOK)</label>
          <input
            type="password"
            value={orkey}
            onChange={(e) => setOrkey(e.target.value)}
            placeholder={state.settings.openRouterKeySet ? "Key saved — paste to replace" : "sk-or-…"}
          />
          <div className="row" style={{ marginTop: "0.75rem" }}>
            <button className="btn secondary" type="button" onClick={() => void saveKey()} disabled={!orkey.trim()}>
              Save key
            </button>
            <button className="btn ghost" type="button" onClick={() => void deleteData()}>
              Delete my data
            </button>
          </div>
          <p className="muted" style={{ marginTop: "0.75rem" }}>
            Estimated AI cost ~$0.30/month at light use. Your key, your spend.
          </p>
        </section>
      )}

      {error && (
        <p className="muted" role="alert">
          {error}
        </p>
      )}

      <nav className="nav">
        {(
          [
            ["home", "Home"],
            ["morning", "Morning"],
            ["midday", "Midday"],
            ["evening", "Evening"],
            ["settings", "Settings"],
          ] as const
        ).map(([id, label]) => (
          <button
            key={id}
            type="button"
            className={tab === id ? "active" : ""}
            disabled={!hasConsent && id !== "home" && id !== "settings"}
            onClick={() => setTab(id)}
          >
            {label}
          </button>
        ))}
      </nav>
    </div>
  );
}

function urlBase64ToUint8Array(base64String: string) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}
