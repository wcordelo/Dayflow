import { DurableObject } from "cloudflare:workers";
import type { CompanionEventKind, Priority, UserSettings } from "@companion/shared";
import {
  DEFAULT_ENGAGEMENT,
  DEFAULT_SETTINGS,
  isoWeekKey,
  logicalDayKey,
  nextDayBoundaryUnix,
} from "@companion/shared";

export type Env = {
  COMPANION_STATE: DurableObjectNamespace;
  DB: D1Database;
  KV: KVNamespace;
  WORKOS_API_KEY?: string;
  WORKOS_CLIENT_ID?: string;
  WORKOS_COOKIE_PASSWORD?: string;
  APP_HOMEPAGE_URL: string;
  AUTH_REDIRECT_URI: string;
  LITELLM_BASE_URL: string;
  OPENROUTER_FALLBACK_KEY?: string;
  KEY_ENCRYPTION_SECRET?: string;
  VAPID_PUBLIC_KEY?: string;
  VAPID_PRIVATE_KEY?: string;
  VAPID_SUBJECT?: string;
  DEV_AUTH_BYPASS?: string;
};

type StoredState = {
  priorities: Priority[];
  settings: UserSettings;
  dayKey: string;
  dayLog: string[];
  lastBrief: unknown | null;
};

const DDL = [
  `CREATE TABLE IF NOT EXISTS events (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     kind TEXT NOT NULL,
     day_key TEXT NOT NULL,
     payload TEXT NOT NULL,
     created_at INTEGER NOT NULL
   )`,
  `CREATE INDEX IF NOT EXISTS events_id ON events(id)`,
];

/**
 * Per-user mini-relay (Buzz-shaped): append-only events + WebSocket fan-out + DO alarms.
 * OpenTag pattern: SQLite DO + alarm for owed nudge work.
 */
export class CompanionStateDO extends DurableObject<Env> {
  private sessions = new Set<WebSocket>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.blockConcurrencyWhile(async () => {
      for (const stmt of DDL) this.ctx.storage.sql.exec(stmt);
      const existing = await this.ctx.storage.get<StoredState>("state");
      if (!existing) {
        await this.ctx.storage.put("state", {
          priorities: [],
          settings: { ...DEFAULT_SETTINGS },
          dayKey: logicalDayKey(),
          dayLog: [],
          lastBrief: null,
        } satisfies StoredState);
      }
      await this.scheduleNextAlarm();
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.headers.get("Upgrade") === "websocket") {
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.ctx.acceptWebSocket(server);
      this.sessions.add(server);
      server.send(JSON.stringify({ type: "hello", state: await this.getState() }));
      return new Response(null, { status: 101, webSocket: client });
    }

    if (url.pathname === "/state" && request.method === "GET") {
      return Response.json(await this.getState());
    }
    if (url.pathname === "/events" && request.method === "GET") {
      const after = Number(url.searchParams.get("after") ?? "0");
      return Response.json({ events: this.listEvents(after) });
    }
    if (url.pathname === "/mutate" && request.method === "POST") {
      const body = (await request.json()) as {
        kind: CompanionEventKind;
        payload: unknown;
      };
      const event = await this.append(body.kind, body.payload);
      return Response.json({ event, state: await this.getState() });
    }
    if (url.pathname === "/settings" && request.method === "POST") {
      const patch = (await request.json()) as Partial<UserSettings>;
      const state = await this.getState();
      state.settings = { ...state.settings, ...patch };
      await this.ctx.storage.put("state", state);
      const event = await this.append("settings_updated", patch);
      await this.scheduleNextAlarm();
      return Response.json({ event, state });
    }
    return new Response("Not found", { status: 404 });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    if (typeof message !== "string") return;
    try {
      const msg = JSON.parse(message) as { type: string; after?: number };
      if (msg.type === "replay") {
        ws.send(JSON.stringify({ type: "replay", events: this.listEvents(msg.after ?? 0) }));
      }
      if (msg.type === "ping") {
        ws.send(JSON.stringify({ type: "pong" }));
      }
    } catch {
      /* ignore */
    }
  }

  async webSocketClose(ws: WebSocket) {
    this.sessions.delete(ws);
  }

  async alarm() {
    const state = await this.getState();
    const now = Date.now();
    if (state.settings.overwhelmUntil && state.settings.overwhelmUntil * 1000 > now) {
      await this.scheduleNextAlarm();
      return;
    }
    // Soft engagement decay: after missed nudges, back off instead of piling shame.
    if (state.settings.engagement.backoffUntil && state.settings.engagement.backoffUntil * 1000 > now) {
      await this.scheduleNextAlarm();
      return;
    }
    const hour = new Date().getHours();
    state.settings.engagement.missedNudges += 1;
    if (state.settings.engagement.missedNudges >= 3) {
      state.settings.engagement.backoffUntil = Math.floor(now / 1000) + 24 * 3600;
      state.settings.engagement.missedNudges = 0;
      await this.ctx.storage.put("state", state);
      this.broadcast({ type: "engagement_backoff", until: state.settings.engagement.backoffUntil });
      await this.scheduleNextAlarm();
      return;
    }
    await this.ctx.storage.put("state", state);
    // Soft signal for clients / push pipeline — clients show in-app if connected.
    this.broadcast({
      type: "nudge_due",
      hour,
      checkinHour: state.settings.checkinHour,
      reflectionHour: state.settings.reflectionHour,
      chimeFrequencyMin: state.settings.chimeFrequencyMin,
      eatReminderEnabled: state.settings.eatReminderEnabled,
      eatReminderHour: state.settings.eatReminderHour,
    });
    await this.scheduleNextAlarm();
  }

  private async getState(): Promise<StoredState> {
    const state = (await this.ctx.storage.get<StoredState>("state"))!;
    if (!state.settings.engagement) {
      state.settings.engagement = { ...DEFAULT_ENGAGEMENT };
    }
    const week = isoWeekKey();
    if (state.settings.engagement.weekKey !== week) {
      state.settings.engagement = {
        weekKey: week,
        checkinsThisWeek: 0,
        missedNudges: state.settings.engagement.missedNudges,
        backoffUntil: state.settings.engagement.backoffUntil,
      };
    }
    const today = logicalDayKey();
    if (state.dayKey !== today) {
      state.dayKey = today;
      state.dayLog = [];
      // Soft rollover: keep priorities text but mark as carried candidates
      await this.ctx.storage.put("state", state);
    }
    return state;
  }

  private listEvents(afterId: number) {
    const rows = this.ctx.storage.sql
      .exec(
        `SELECT id, kind, day_key, payload, created_at FROM events WHERE id > ? ORDER BY id ASC LIMIT 500`,
        afterId,
      )
      .toArray();
    return rows.map((row) => ({
      id: row.id as number,
      kind: row.kind as CompanionEventKind,
      dayKey: row.day_key as string,
      payload: JSON.parse(String(row.payload)),
      createdAt: row.created_at as number,
    }));
  }

  private async append(kind: CompanionEventKind, payload: unknown) {
    const state = await this.getState();
    const createdAt = Math.floor(Date.now() / 1000);
    this.ctx.storage.sql.exec(
      `INSERT INTO events (kind, day_key, payload, created_at) VALUES (?, ?, ?, ?)`,
      kind,
      state.dayKey,
      JSON.stringify(payload ?? {}),
      createdAt,
    );
    const idRow = this.ctx.storage.sql.exec(`SELECT last_insert_rowid() AS id`).one();
    const id = Number(idRow.id);

    if (kind === "priority_set") {
      const priorities = (payload as { priorities: Priority[] }).priorities;
      state.priorities = priorities;
    }
    if (kind === "overwhelm_on") {
      state.settings.overwhelmUntil = nextDayBoundaryUnix();
    }
    if (kind === "overwhelm_off") {
      state.settings.overwhelmUntil = null;
    }
    if (kind === "day_log_note") {
      const note = (payload as { note: string }).note;
      state.dayLog.push(note);
    }
    if (kind === "brief_generated") {
      state.lastBrief = payload;
    }
    if (kind === "priority_update") {
      const { id: pid, status } = payload as { id: string; status: Priority["status"] };
      state.priorities = state.priorities.map((p) => (p.id === pid ? { ...p, status } : p));
    }
    if (
      kind === "checkin_completed" ||
      kind === "chime_answered" ||
      kind === "brief_generated" ||
      kind === "gratitude"
    ) {
      state.settings.engagement.missedNudges = 0;
      state.settings.engagement.backoffUntil = null;
      if (kind === "checkin_completed" || kind === "chime_answered" || kind === "brief_generated") {
        state.settings.engagement.checkinsThisWeek += 1;
      }
    }
    await this.ctx.storage.put("state", state);

    const event = { id, kind, dayKey: state.dayKey, payload, createdAt };
    this.broadcast({ type: "event", event, state });
    return event;
  }

  private broadcast(msg: unknown) {
    const data = JSON.stringify(msg);
    for (const ws of this.sessions) {
      try {
        ws.send(data);
      } catch {
        this.sessions.delete(ws);
      }
    }
  }

  private async scheduleNextAlarm() {
    const state = await this.getState();
    const now = Date.now();
    const candidates: number[] = [];
    const addHour = (h: number) => {
      const d = new Date();
      d.setHours(h, 0, 0, 0);
      if (d.getTime() <= now) d.setDate(d.getDate() + 1);
      candidates.push(d.getTime());
    };
    addHour(state.settings.checkinHour);
    addHour(state.settings.reflectionHour);
    if (state.settings.eatReminderEnabled) addHour(state.settings.eatReminderHour);
    if (state.settings.chimeFrequencyMin && state.settings.chimeFrequencyMin > 0) {
      candidates.push(now + state.settings.chimeFrequencyMin * 60_000);
    } else {
      // Default poll every 30m so noon-ish nudges still fire for clients
      candidates.push(now + 30 * 60_000);
    }
    const next = Math.min(...candidates);
    await this.ctx.storage.setAlarm(next);
  }
}
