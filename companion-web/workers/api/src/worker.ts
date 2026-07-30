import { Hono } from "hono";
import { cors } from "hono/cors";
import { CompanionStateDO, type Env } from "./companion-state-do";
import { createAuthRoutes, resolveUser } from "./auth";
import { completeJson, localFallback, promptForEngine } from "./ai";

export { CompanionStateDO };

const app = new Hono<{ Bindings: Env }>();

app.use("*", async (c, next) => {
  const origin = c.env.APP_HOMEPAGE_URL;
  return cors({
    origin: [origin, "http://localhost:5173", "http://127.0.0.1:5173"],
    credentials: true,
  })(c, next);
});

app.get("/api/health", (c) =>
  c.json({
    ok: true,
    service: "companion-api",
    contract: "platform-rethink-v1",
    authBypass: c.env.DEV_AUTH_BYPASS === "true",
  }),
);

app.route("/api/auth", createAuthRoutes());

app.get("/api/vapid-public-key", (c) =>
  c.json({ publicKey: c.env.VAPID_PUBLIC_KEY ?? null }),
);

app.post("/api/push/subscribe", async (c) => {
  const user = await resolveUser(c);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  const body = await c.req.json();
  await c.env.KV.put(`push:${user.id}`, JSON.stringify(body));
  return c.json({ ok: true });
});

app.post("/api/consent", async (c) => {
  const user = await resolveUser(c);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  const { healthDataConsent } = (await c.req.json()) as { healthDataConsent: boolean };
  const stub = doStub(c.env, user.id);
  await stub.fetch("https://do/settings", {
    method: "POST",
    body: JSON.stringify({ healthDataConsent }),
  });
  return c.json({ ok: true });
});

app.delete("/api/me/data", async (c) => {
  const user = await resolveUser(c);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  await c.env.KV.delete(`push:${user.id}`);
  await c.env.KV.delete(`orkey:${user.id}`);
  const stub = doStub(c.env, user.id);
  await stub.fetch("https://do/wipe", { method: "POST" });
  return c.json({ ok: true, deleted: true });
});

app.get("/api/privacy", (c) =>
  c.text(
    `ADHD Companion — Consumer Health Data Privacy Notice

We store check-in messages, priorities, reflection summaries, and nudge events to deliver your companion loop.
We do not claim to diagnose or treat ADHD.
Screen capture is not part of this PWA.
You may delete all data via Settings → Delete my data.
Washington MHMDA / similar health-data laws: separate consent is required before we collect check-in content.
`,
  ),
);

app.get("/api/state", async (c) => {
  const user = await resolveUser(c);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  const stub = doStub(c.env, user.id);
  return stub.fetch("https://do/state");
});

app.get("/api/events", async (c) => {
  const user = await resolveUser(c);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  const after = c.req.query("after") ?? "0";
  const stub = doStub(c.env, user.id);
  return stub.fetch(`https://do/events?after=${after}`);
});

app.post("/api/mutate", async (c) => {
  const user = await resolveUser(c);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  const bodyText = await c.req.text();
  let kind: string | undefined;
  try {
    kind = (JSON.parse(bodyText) as { kind?: string }).kind;
  } catch {
    /* invalid JSON handled by DO */
  }
  const overwhelmBypass = kind === "overwhelm_on" || kind === "overwhelm_off";
  if (!overwhelmBypass && !(await userHasHealthConsent(c.env, user.id))) {
    return c.json({ error: "health_consent_required" }, 403);
  }
  const stub = doStub(c.env, user.id);
  return stub.fetch("https://do/mutate", { method: "POST", body: bodyText });
});

const USER_SETTINGS_KEYS = [
  "checkinHour",
  "reflectionHour",
  "chimeFrequencyMin",
  "eatReminderEnabled",
  "eatReminderHour",
  "quietHoursStart",
  "quietHoursEnd",
  "ttsEnabled",
  "ianaTimeZone",
] as const;

app.post("/api/settings", async (c) => {
  const user = await resolveUser(c);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  const body = (await c.req.json()) as Record<string, unknown>;
  const patch: Record<string, unknown> = {};
  for (const key of USER_SETTINGS_KEYS) {
    if (key in body) patch[key] = body[key];
  }
  const stub = doStub(c.env, user.id);
  return stub.fetch("https://do/settings", {
    method: "POST",
    body: JSON.stringify(patch),
  });
});

app.post("/api/keys/openrouter", async (c) => {
  const user = await resolveUser(c);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  const { apiKey } = (await c.req.json()) as { apiKey: string };
  if (!apiKey?.trim()) return c.json({ error: "empty key" }, 400);
  const encSecret = c.env.KEY_ENCRYPTION_SECRET;
  if (!encSecret) return c.json({ error: "key_encryption_not_configured" }, 503);
  const enc = await encryptKey(apiKey.trim(), encSecret);
  await c.env.KV.put(`orkey:${user.id}`, enc);
  const stub = doStub(c.env, user.id);
  await stub.fetch("https://do/settings", {
    method: "POST",
    body: JSON.stringify({ openRouterKeySet: true }),
  });
  return c.json({ ok: true });
});

app.post("/api/ai/:engine", async (c) => {
  const user = await resolveUser(c);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  if (!(await userHasHealthConsent(c.env, user.id))) {
    return c.json({ error: "health_consent_required" }, 403);
  }
  const engine = c.req.param("engine") as "checkin" | "brief" | "midday";
  if (!["checkin", "brief", "midday"].includes(engine)) {
    return c.json({ error: "unknown engine" }, 400);
  }
  const body = (await c.req.json()) as { message?: string; context?: unknown };
  const stored = await c.env.KV.get(`orkey:${user.id}`);
  let userKey = c.env.OPENROUTER_FALLBACK_KEY;
  if (stored) {
    const encSecret = c.env.KEY_ENCRYPTION_SECRET;
    if (!encSecret) return c.json({ error: "key_encryption_not_configured" }, 503);
    userKey = await decryptKey(stored, encSecret);
  }

  if (!userKey) {
    return c.json({
      source: "local_template",
      result: JSON.parse(localFallback(engine, body.message)),
    });
  }

  try {
    const logical = engine === "brief" ? "brief-fast" : "checkin-fast";
    const { text, model } = await completeJson({
      baseUrl: c.env.LITELLM_BASE_URL,
      apiKey: userKey,
      logicalModel: logical,
      system: promptForEngine(engine),
      user: JSON.stringify({ message: body.message ?? null, context: body.context ?? {} }),
    });
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = { reply: text, raw: true };
    }
    return c.json({ source: "openrouter", model, result: parsed });
  } catch (e) {
    return c.json({
      source: "local_template",
      error: e instanceof Error ? e.message : "ai_failed",
      result: JSON.parse(localFallback(engine, body.message)),
    });
  }
});

/** WebSocket proxy into the user's CompanionStateDO */
app.get("/api/ws", async (c) => {
  const user = await resolveUser(c);
  if (!user) return c.text("unauthorized", 401);
  const stub = doStub(c.env, user.id);
  return stub.fetch(new Request("https://do/", c.req.raw));
});

function doStub(env: Env, userId: string) {
  const id = env.COMPANION_STATE.idFromName(userId);
  return env.COMPANION_STATE.get(id);
}

async function userHasHealthConsent(env: Env, userId: string): Promise<boolean> {
  const stub = doStub(env, userId);
  const res = await stub.fetch("https://do/state");
  if (!res.ok) return false;
  const state = (await res.json()) as { settings?: { healthDataConsent?: boolean } };
  return state.settings?.healthDataConsent === true;
}

async function encryptKey(plain: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret)),
    { name: "AES-GCM" },
    false,
    ["encrypt"],
  );
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(plain));
  const out = new Uint8Array(iv.length + new Uint8Array(ct).length);
  out.set(iv, 0);
  out.set(new Uint8Array(ct), iv.length);
  return btoa(String.fromCharCode(...out));
}

async function decryptKey(blob: string, secret: string): Promise<string> {
  const raw = Uint8Array.from(atob(blob), (c) => c.charCodeAt(0));
  const iv = raw.slice(0, 12);
  const data = raw.slice(12);
  const key = await crypto.subtle.importKey(
    "raw",
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret)),
    { name: "AES-GCM" },
    false,
    ["decrypt"],
  );
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, data);
  return new TextDecoder().decode(pt);
}

export default app;
