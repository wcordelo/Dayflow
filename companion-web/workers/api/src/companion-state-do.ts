import { DurableObject } from "cloudflare:workers";
import type { CompanionEventKind, Priority, UserSettings } from "@companion/shared";
import {
  DEFAULT_ENGAGEMENT,
  DEFAULT_SETTINGS,
  isoWeekKey,
  logicalDayKey,
  nextDayBoundaryUnix,
  nextUnixForLocalHour,
  zonedParts,
} from "@companion/shared";
import { sendWebPush, type NudgeKind } from "./push";

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

function isQuietHours(hour: number, start: number | null, end: number | null): boolean {
  if (start == null || end == null) return false;
  if (start === end) return false;
  if (start < end) return hour >= start && hour < end;
  return hour >= start || hour < end;
}

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
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.blockConcurrencyWhile(async () => {
      for (const stmt of DDL) this.ctx.storage.sql.exec(stmt);
      const existing = await this.ctx.storage.get<StoredState>("state");
      if (!existing) {
        await this.ctx.storage.put("state", {
          priorities: [],
          settings: { ...DEFAULT_SETTINGS },
          dayKey: "pending",
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
      if (patch.ianaTimeZone) {
        state.dayKey = logicalDayKey(new Date(), state.settings.ianaTimeZone);
      }
      await this.ctx.storage.put("state", state);
      const event = await this.append("settings_updated", patch);
      await this.scheduleNextAlarm();
      return Response.json({ event, state });
    }
    if (url.pathname === "/wipe" && request.method === "POST") {
      this.ctx.storage.sql.exec(`DELETE FROM events`);
      const tz = (await this.getState()).settings.ianaTimeZone;
      await this.ctx.storage.put("state", {
        priorities: [],
        settings: {
          ...DEFAULT_SETTINGS,
          healthDataConsent: false,
          openRouterKeySet: false,
          overwhelmUntil: null,
          ianaTimeZone: tz,
        },
        dayKey: logicalDayKey(new Date(), tz),
        dayLog: [],
        lastBrief: null,
      } satisfies StoredState);
      await this.scheduleNextAlarm();
      return Response.json({ ok: true });
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

  async webSocketClose(_ws: WebSocket) {}

  async alarm() {
    const state = await this.getState();
    const now = Date.now();
    const planned =
      (await this.ctx.storage.get<{ kinds: NudgeKind[] | null; at: number }>("nextAlarm")) ?? null;
    await this.ctx.storage.delete("nextAlarm");

    if (planned && planned.kinds === null) {
      await this.scheduleNextAlarm();
      return;
    }

    if (state.settings.overwhelmUntil && state.settings.overwhelmUntil * 1000 > now) {
      await this.scheduleNextAlarm();
      return;
    }
    if (state.settings.engagement.backoffUntil && state.settings.engagement.backoffUntil * 1000 > now) {
      await this.scheduleNextAlarm();
      return;
    }

    const tz = state.settings.ianaTimeZone ?? "UTC";
    const hour = zonedParts(new Date(now), tz).hour;
    if (isQuietHours(hour, state.settings.quietHoursStart, state.settings.quietHoursEnd)) {
      await this.scheduleNextAlarm();
      return;
    }

    const kinds =
      planned?.kinds?.length ? planned.kinds : (() => {
        const k = this.nudgeKindForHour(state, hour);
        return k ? [k] : [];
      })();
    if (!kinds.length) {
      await this.scheduleNextAlarm();
      return;
    }

    // Previous delivered nudge still unanswered → soft miss (not every timer tick).
    if (state.settings.engagement.lastNudgeAt) {
      state.settings.engagement.missedNudges += 1;
      if (state.settings.engagement.missedNudges >= 3) {
        state.settings.engagement.backoffUntil = Math.floor(now / 1000) + 24 * 3600;
        state.settings.engagement.missedNudges = 0;
        state.settings.engagement.lastNudgeAt = null;
        await this.ctx.storage.put("state", state);
        this.broadcast({ type: "engagement_backoff", until: state.settings.engagement.backoffUntil });
        await this.scheduleNextAlarm();
        return;
      }
    }

    let anyDelivered = false;
    for (const kind of kinds) {
      if (await this.deliverNudge(kind, hour)) anyDelivered = true;
    }
    if (anyDelivered) {
      state.settings.engagement.lastNudgeAt = Math.floor(now / 1000);
      await this.ctx.storage.put("state", state);
    }
    await this.scheduleNextAlarm();
  }

  private nudgeKindForHour(state: StoredState, hour: number): NudgeKind | null {
    if (hour === state.settings.checkinHour) return "morning";
    if (hour === state.settings.reflectionHour) return "evening";
    if (state.settings.eatReminderEnabled && hour === state.settings.eatReminderHour) return "eat";
    if (state.settings.chimeFrequencyMin && state.settings.chimeFrequencyMin > 0) return "chime";
    return null;
  }

  private async deliverNudge(kind: NudgeKind, hour: number): Promise<boolean> {
    const msg = {
      type: "nudge_due" as const,
      kind,
      hour,
    };
    const hadWs = this.ctx.getWebSockets().length > 0;
    this.broadcast(msg);

    let pushed = false;
    const userId = this.ctx.id.name;
    if (
      !hadWs &&
      userId &&
      this.env.VAPID_PUBLIC_KEY &&
      this.env.VAPID_PRIVATE_KEY &&
      this.env.VAPID_SUBJECT
    ) {
      const sub = await this.env.KV.get(`push:${userId}`);
      if (sub) {
        pushed = await sendWebPush({
          subscriptionJson: sub,
          vapid: {
            subject: this.env.VAPID_SUBJECT,
            publicKey: this.env.VAPID_PUBLIC_KEY,
            privateKey: this.env.VAPID_PRIVATE_KEY,
          },
          kind,
        });
      }
    }
    return hadWs || pushed;
  }

  private async getState(): Promise<StoredState> {
    const state = (await this.ctx.storage.get<StoredState>("state"))!;
    if (!state.settings.engagement) {
      state.settings.engagement = { ...DEFAULT_ENGAGEMENT };
    }
    if (state.settings.engagement.lastNudgeAt === undefined) {
      state.settings.engagement.lastNudgeAt = null;
    }
    const week = isoWeekKey();
    if (state.settings.engagement.weekKey !== week) {
      state.settings.engagement = {
        weekKey: week,
        checkinsThisWeek: 0,
        missedNudges: state.settings.engagement.missedNudges,
        backoffUntil: state.settings.engagement.backoffUntil,
        lastNudgeAt: state.settings.engagement.lastNudgeAt,
      };
    }
    const tz = state.settings.ianaTimeZone;
    if (tz) {
      const today = logicalDayKey(new Date(), tz);
      if (state.dayKey === "pending") {
        state.dayKey = today;
        await this.ctx.storage.put("state", state);
      } else if (state.dayKey !== today) {
        state.dayKey = today;
        state.dayLog = [];
        state.lastBrief = null;
        await this.ctx.storage.put("state", state);
      }
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
      state.settings.overwhelmUntil = nextDayBoundaryUnix(Date.now(), state.settings.ianaTimeZone);
      state.settings.engagement.missedNudges = 0;
      state.settings.engagement.lastNudgeAt = null;
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
      state.settings.engagement.lastNudgeAt = null;
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
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(data);
      } catch {
        /* ignore */
      }
    }
  }

  private async scheduleNextAlarm() {
    const state = await this.getState();
    const now = Date.now();
    const tz = state.settings.ianaTimeZone ?? "UTC";
    const candidates: Array<{ at: number; kind: NudgeKind }> = [];
    const addHour = (h: number, kind: NudgeKind) => {
      candidates.push({ at: nextUnixForLocalHour(h, tz, now), kind });
    };
    addHour(state.settings.checkinHour, "morning");
    addHour(state.settings.reflectionHour, "evening");
    if (state.settings.eatReminderEnabled) addHour(state.settings.eatReminderHour, "eat");
    if (state.settings.chimeFrequencyMin && state.settings.chimeFrequencyMin > 0) {
      candidates.push({ at: now + state.settings.chimeFrequencyMin * 60_000, kind: "chime" });
    }

    // If quiet hours cover a candidate, skip past quiet end for that slot.
    const filtered = candidates
      .map((c) => {
        const hour = zonedParts(new Date(c.at), tz).hour;
        if (!isQuietHours(hour, state.settings.quietHoursStart, state.settings.quietHoursEnd)) {
          return c;
        }
        const end = state.settings.quietHoursEnd;
        if (end == null) return null;
        return { at: nextUnixForLocalHour(end, tz, c.at), kind: c.kind };
      })
      .filter((c): c is { at: number; kind: NudgeKind } => !!c && c.at > now);

    if (!filtered.length) {
      // No scheduled nudges — wake at next day boundary to re-evaluate.
      const boundaryMs = nextDayBoundaryUnix(now, tz) * 1000;
      await this.ctx.storage.put("nextAlarm", { kinds: null, at: boundaryMs });
      await this.ctx.storage.setAlarm(boundaryMs);
      return;
    }

    filtered.sort((a, b) => a.at - b.at);
    const nextAt = filtered[0]!.at;
    const kinds = filtered.filter((c) => c.at === nextAt).map((c) => c.kind);
    await this.ctx.storage.put("nextAlarm", { kinds, at: nextAt });
    await this.ctx.storage.setAlarm(nextAt);
  }
}
