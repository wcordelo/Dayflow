import type { AuthPrincipal } from "./auth";
import { authenticateRequest } from "./auth";
import { verifyDeviceProof } from "./device-proof";
import { AccountRelay } from "./relay-do";
import {
  MAX_EVENT_BATCH_SIZE,
  RelayValidationError,
  formatCursor,
  parseCursor,
  success,
} from "./relay";

export { AccountRelay };

const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
};

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: JSON_HEADERS,
  });
}

function errorResponse(status: number, code: string, message: string): Response {
  return json({ error: code, message }, status);
}

function resultResponse<T>(result: { ok: true; value: T } | { ok: false; error: string; message: string }): Response {
  if (!result.ok) {
    const status = result.error === "not_found" ? 404 : result.error === "forbidden" ? 403 : result.error === "not_approved" ? 409 : result.error === "conflict" ? 409 : 400;
    return errorResponse(status, result.error, result.message);
  }
  return json(result.value);
}

async function readJson(request: Request): Promise<unknown> {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength !== null && Number(contentLength) > 4_000_000) {
    throw new RelayValidationError("request body is too large");
  }
  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > 4_000_000) {
    throw new RelayValidationError("request body is too large");
  }
  try {
    return JSON.parse(body) as unknown;
  } catch {
    throw new RelayValidationError("request body must be valid JSON");
  }
}

function deviceID(request: Request): string | null {
  const value = request.headers.get("X-Dayflow-Device-ID");
  return value === null || value.length === 0 ? null : value;
}

function decodePathSegment(value: string): string | null {
  try {
    return decodeURIComponent(value);
  } catch {
    return null;
  }
}

async function signedBody(request: Request): Promise<string> {
  if (request.method === "GET" || request.method === "HEAD") {
    return "";
  }
  return request.clone().text();
}

async function requireDeviceProof(
  request: Request,
  relay: DurableObjectStub<AccountRelay>,
): Promise<Response | null> {
  const currentDeviceID = deviceID(request);
  if (currentDeviceID === null) {
    return errorResponse(400, "invalid_request", "X-Dayflow-Device-ID is required");
  }
  const device = await relay.getDevice(currentDeviceID);
  if (!device.ok) {
    return resultResponse(device);
  }
  const proof = await verifyDeviceProof(request, await signedBody(request), device.value);
  if (!proof.ok) {
    return errorResponse(403, "forbidden", proof.message);
  }
  const consumed = await relay.consumeRequestNonce(
    currentDeviceID,
    proof.nonce,
    Math.floor(Date.now() / 1_000) + 300,
  );
  if (!consumed.ok) {
    return resultResponse(consumed);
  }
  return null;
}

function accountRelay(env: Env, principal: AuthPrincipal): DurableObjectStub<AccountRelay> {
  return env.ACCOUNT_RELAY.getByName(principal.account_id);
}

async function authenticated(
  request: Request,
  env: Env,
): Promise<{ principal: AuthPrincipal; relay: DurableObjectStub<AccountRelay> } | Response> {
  const principal = await authenticateRequest(request, env.DAYFLOW_AUTH);
  if (principal === null) {
    return errorResponse(401, "unauthorized", "Dayflow account authentication is required");
  }
  return { principal, relay: accountRelay(env, principal) };
}

function parseLimit(url: URL): number {
  const value = url.searchParams.get("limit");
  if (value === null) {
    return MAX_EVENT_BATCH_SIZE;
  }
  const limit = Number(value);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_EVENT_BATCH_SIZE) {
    throw new RelayValidationError(`limit must be between 1 and ${MAX_EVENT_BATCH_SIZE}`);
  }
  return limit;
}

function parseEventBatch(value: unknown): unknown[] {
  if (Array.isArray(value)) {
    return value;
  }
  if (isRecord(value)) {
    const envelopes = value.envelopes;
    if (Array.isArray(envelopes)) {
      return envelopes;
    }
  }
  throw new RelayValidationError("event push body must contain an envelopes array");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function handleSync(request: Request, env: Env): Promise<Response> {
  const auth = await authenticated(request, env);
  if (auth instanceof Response) {
    return auth;
  }

  const url = new URL(request.url);
  const parts = url.pathname.split("/").filter(Boolean);
  // parts: v1, sync, ...
  const resource = parts[2];

  if (resource === "devices" && parts.length === 3) {
    if (request.method === "GET") {
      return resultResponse(await auth.relay.listDevices());
    }
    if (request.method === "POST") {
      return resultResponse(await auth.relay.registerDevice(await readJson(request)));
    }
  }

  if (resource === "devices" && parts.length === 5) {
    const targetDeviceID = decodePathSegment(parts[3]);
    if (targetDeviceID === null) {
      return errorResponse(400, "invalid_request", "device route contains an invalid URL-encoded identifier");
    }
    const action = parts[4];
    const actorDeviceID = deviceID(request);
    if (actorDeviceID === null) {
      return errorResponse(400, "invalid_request", "X-Dayflow-Device-ID is required");
    }
    const proofError = await requireDeviceProof(request, auth.relay);
    if (proofError !== null) {
      return proofError;
    }
    if (action === "approve" && request.method === "POST") {
      return resultResponse(await auth.relay.approveDevice(targetDeviceID, actorDeviceID, await readJson(request)));
    }
    if (action === "revoke" && request.method === "POST") {
      return resultResponse(await auth.relay.revokeDevice(targetDeviceID, actorDeviceID));
    }
    if (action === "wrapped-key" && request.method === "GET") {
      if (targetDeviceID !== actorDeviceID) {
        return errorResponse(403, "forbidden", "a device may only retrieve its own wrapped account key");
      }
      return resultResponse(await auth.relay.getWrappedKey(actorDeviceID));
    }
    if (action === "wrapped-keys" && request.method === "GET") {
      if (targetDeviceID !== actorDeviceID) {
        return errorResponse(403, "forbidden", "a device may only retrieve its own wrapped account keys");
      }
      return resultResponse(await auth.relay.getWrappedKeys(actorDeviceID));
    }
  }

  if (resource === "events" && parts.length === 3) {
    const currentDeviceID = deviceID(request);
    if (currentDeviceID === null) {
      return errorResponse(400, "invalid_request", "X-Dayflow-Device-ID is required");
    }
    const proofError = await requireDeviceProof(request, auth.relay);
    if (proofError !== null) {
      return proofError;
    }
    if (request.method === "POST") {
      return resultResponse(await auth.relay.pushEvents(currentDeviceID, parseEventBatch(await readJson(request))));
    }
    if (request.method === "GET") {
      return resultResponse(await auth.relay.pullEvents(currentDeviceID, parseCursor(url.searchParams.get("cursor")), parseLimit(url)));
    }
  }

  if (resource === "notifications" && parts.length === 3) {
    const currentDeviceID = deviceID(request);
    if (currentDeviceID === null) {
      return errorResponse(400, "invalid_request", "X-Dayflow-Device-ID is required");
    }
    const proofError = await requireDeviceProof(request, auth.relay);
    if (proofError !== null) {
      return proofError;
    }
    if (request.method === "GET") {
      return resultResponse(await auth.relay.pullNotificationHints(currentDeviceID, parseCursor(url.searchParams.get("cursor")), parseLimit(url)));
    }
    if (request.method === "PUT") {
      return resultResponse(await auth.relay.registerPushToken(currentDeviceID, await readJson(request)));
    }
    if (request.method === "DELETE") {
      return resultResponse(await auth.relay.unregisterPushToken(currentDeviceID));
    }
  }

  return errorResponse(404, "not_found", "sync route not found");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (url.pathname === "/healthz" && request.method === "GET") {
        return json({ ok: true, service: "dayflow-sync-relay", contract_version: "0.1" });
      }
      if (url.pathname.startsWith("/v1/sync/")) {
        return await handleSync(request, env);
      }
      return errorResponse(404, "not_found", "route not found");
    } catch (error) {
      if (error instanceof RelayValidationError) {
        return errorResponse(400, "invalid_request", error.message);
      }
      console.error(JSON.stringify({ event: "sync_relay_error", message: error instanceof Error ? error.message : "unknown error" }));
      return errorResponse(500, "internal_error", "the relay could not complete the request");
    }
  },
} satisfies ExportedHandler<Env>;
