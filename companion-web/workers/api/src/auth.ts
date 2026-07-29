import { Hono } from "hono";
import { getCookie, setCookie, deleteCookie } from "hono/cookie";
import type { Env } from "./companion-state-do";

const FLOW_COOKIE = "companion_auth_flow";
const SESSION_COOKIE = "companion_session";
const FLOW_MAX_AGE = 10 * 60;
const SESSION_MAX_AGE = 30 * 24 * 60 * 60;

type AuthFlow = { state: string; codeVerifier: string; returnTo: string; issuedAt: number };

/** Simplified WorkOS AuthKit (SignalSci pattern) — no organizations. */
export function createAuthRoutes() {
  const app = new Hono<{ Bindings: Env }>();

  app.get("/login", async (c) => {
    if (c.env.DEV_AUTH_BYPASS === "true" && !c.env.WORKOS_API_KEY) {
      setCookie(c, SESSION_COOKIE, "dev:local-user", {
        path: "/",
        httpOnly: true,
        sameSite: "Lax",
        maxAge: SESSION_MAX_AGE,
      });
      return c.redirect(c.env.APP_HOMEPAGE_URL, 302);
    }
    if (!c.env.WORKOS_API_KEY || !c.env.WORKOS_CLIENT_ID || !c.env.WORKOS_COOKIE_PASSWORD) {
      return c.text("WorkOS is not configured. Set WORKOS_* or DEV_AUTH_BYPASS=true.", 503);
    }

    const { WorkOS } = await import("@workos-inc/node");
    const workos = new WorkOS(c.env.WORKOS_API_KEY);
    const { url, state, codeVerifier } = await workos.userManagement.getAuthorizationUrlWithPKCE({
      provider: "authkit",
      clientId: c.env.WORKOS_CLIENT_ID,
      redirectUri: c.env.AUTH_REDIRECT_URI,
    });
    const flow: AuthFlow = {
      state,
      codeVerifier,
      returnTo: c.req.query("return_to") || "/",
      issuedAt: Date.now(),
    };
    setCookie(c, FLOW_COOKIE, JSON.stringify(flow), {
      path: "/api/auth",
      httpOnly: true,
      sameSite: "Lax",
      maxAge: FLOW_MAX_AGE,
      secure: c.env.AUTH_REDIRECT_URI.startsWith("https"),
    });
    return c.redirect(url, 302);
  });

  app.get("/callback", async (c) => {
    if (!c.env.WORKOS_API_KEY || !c.env.WORKOS_CLIENT_ID || !c.env.WORKOS_COOKIE_PASSWORD) {
      return c.text("WorkOS not configured", 503);
    }
    const raw = getCookie(c, FLOW_COOKIE);
    deleteCookie(c, FLOW_COOKIE, { path: "/api/auth" });
    if (!raw) return c.text("Sign-in could not be verified.", 400);
    const flow = JSON.parse(raw) as AuthFlow;
    const code = c.req.query("code");
    const state = c.req.query("state");
    if (!code || !state || state !== flow.state || Date.now() - flow.issuedAt > FLOW_MAX_AGE * 1000) {
      return c.text("Sign-in could not be verified.", 400);
    }
    const { WorkOS } = await import("@workos-inc/node");
    const workos = new WorkOS(c.env.WORKOS_API_KEY);
    const auth = await workos.userManagement.authenticateWithCode({
      code,
      codeVerifier: flow.codeVerifier,
      clientId: c.env.WORKOS_CLIENT_ID,
      session: { sealSession: true, cookiePassword: c.env.WORKOS_COOKIE_PASSWORD },
    });
    if (!auth.user.emailVerified) return c.text("Verify your email first.", 403);
    const sealed = auth.sealedSession;
    if (!sealed) return c.text("Session seal failed", 500);
    setCookie(c, SESSION_COOKIE, sealed, {
      path: "/",
      httpOnly: true,
      sameSite: "Lax",
      maxAge: SESSION_MAX_AGE,
      secure: c.env.AUTH_REDIRECT_URI.startsWith("https"),
    });
    return c.redirect(c.env.APP_HOMEPAGE_URL + (flow.returnTo || "/"), 302);
  });

  app.post("/logout", (c) => {
    deleteCookie(c, SESSION_COOKIE, { path: "/" });
    return c.json({ ok: true });
  });

  app.get("/me", async (c) => {
    const user = await resolveUser(c);
    if (!user) return c.json({ user: null }, 401);
    return c.json({ user });
  });

  return app;
}

export type CompanionUser = { id: string; email?: string; mode: "workos" | "dev" };

export async function resolveUser(c: {
  env: Env;
  req: { header: (n: string) => string | undefined };
}): Promise<CompanionUser | null> {
  const cookie = c.req.header("cookie") ?? "";
  const match = cookie.match(new RegExp(`${SESSION_COOKIE}=([^;]+)`));
  const sealed = match?.[1] ? decodeURIComponent(match[1]) : undefined;
  if (!sealed) return null;

  if (sealed.startsWith("dev:") && c.env.DEV_AUTH_BYPASS === "true") {
    return { id: sealed.slice(4) || "local-user", email: "dev@localhost", mode: "dev" };
  }

  if (!c.env.WORKOS_API_KEY || !c.env.WORKOS_COOKIE_PASSWORD || !c.env.WORKOS_CLIENT_ID) {
    return null;
  }
  const { WorkOS } = await import("@workos-inc/node");
  const workos = new WorkOS(c.env.WORKOS_API_KEY);
  const session = workos.userManagement.loadSealedSession({
    sessionData: sealed,
    cookiePassword: c.env.WORKOS_COOKIE_PASSWORD,
  });
  const authResult = await session.authenticate();
  if (authResult.authenticated) {
    return { id: authResult.user.id, email: authResult.user.email, mode: "workos" };
  }
  const refreshed = await session.refresh();
  if (!refreshed.authenticated) return null;
  return { id: refreshed.user.id, email: refreshed.user.email, mode: "workos" };
}

export { SESSION_COOKIE };
