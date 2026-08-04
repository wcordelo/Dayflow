import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { canonicalDeviceRequest, sha256Hex } from "./device-proof";

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function base64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

async function signedRequest(
  path: string,
  method: "GET" | "POST" | "PUT" | "DELETE",
  deviceID: string,
  signingKey: CryptoKey,
  body = "",
  nonce = "0123456789abcdef0123456789abcdef",
): Promise<Request> {
  const timestamp = Math.floor(Date.now() / 1_000);
  const bodyHash = await sha256Hex(new TextEncoder().encode(body));
  const message = canonicalDeviceRequest(
    method,
    path,
    bodyHash,
    timestamp,
    nonce,
    deviceID,
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "Ed25519" } as AlgorithmIdentifier,
      signingKey,
      arrayBuffer(new TextEncoder().encode(message)),
    ),
  );

  return new Request(`https://relay.example${path}`, {
    method,
    body: method === "GET" ? undefined : body,
    headers: {
      Authorization: "Bearer test-token",
      "X-Dayflow-Device-ID": deviceID,
      "X-Dayflow-Device-Timestamp": String(timestamp),
      "X-Dayflow-Device-Nonce": nonce,
      "X-Dayflow-Device-Signature": base64(signature),
      ...(method === "POST" || method === "PUT" ? { "Content-Type": "application/json" } : {}),
    },
  });
}

describe("sync relay HTTP boundary", () => {
  it("returns a client error for malformed encoded device route identifiers", async () => {
    const response = await SELF.fetch(
      new Request("https://relay.example/v1/sync/devices/%E0%A4%A/approve", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-token",
          "X-Dayflow-Device-ID": "http-mac",
        },
      }),
    );
    expect(response.status).toBe(400);
    expect((await response.json() as { error: string }).error).toBe("invalid_request");
  });

  it("requires account auth, verifies device proof, and never returns plaintext event fields", async () => {
    const unauthorized = await SELF.fetch(
      new Request("https://relay.example/v1/sync/devices", { method: "GET" }),
    );
    expect(unauthorized.status).toBe(401);

    const signingKeys = await crypto.subtle.generateKey(
      { name: "Ed25519", namedCurve: "Ed25519" } as AlgorithmIdentifier,
      true,
      ["sign", "verify"],
    ) as CryptoKeyPair;
    const signingPublicKey = new Uint8Array(await crypto.subtle.exportKey("raw", signingKeys.publicKey));
    const deviceID = "http-mac";
    const registration = {
      device_id: deviceID,
      public_key: base64(new Uint8Array(32)),
      signing_public_key: base64(signingPublicKey),
      display_name: "HTTP test Mac",
      platform: "macos",
    };
    const registrationResponse = await SELF.fetch(
      new Request("https://relay.example/v1/sync/devices", {
        method: "POST",
        body: JSON.stringify(registration),
        headers: {
          Authorization: "Bearer test-token",
          "Content-Type": "application/json",
        },
      }),
    );
    expect(registrationResponse.status).toBe(200);
    expect((await registrationResponse.json() as { status: string }).status).toBe("approved");

    const eventBody = JSON.stringify({
      envelopes: [{
        event_id: "http-event-1",
        device_id: deviceID,
        logical_clock: 1,
        schema_version: 1,
        key_version: 1,
        nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        ciphertext: "ZW5jcnlwdGVkLXBheWxvYWQ",
      }],
    });
    const pushResponse = await SELF.fetch(
      await signedRequest(
        "/v1/sync/events",
        "POST",
        deviceID,
        signingKeys.privateKey,
        eventBody,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      ),
    );
    expect(pushResponse.status).toBe(200);
    expect((await pushResponse.json() as { accepted_event_ids: string[] }).accepted_event_ids).toEqual(["http-event-1"]);

    const pushTokenResponse = await SELF.fetch(
      await signedRequest(
        "/v1/sync/notifications",
        "PUT",
        deviceID,
        signingKeys.privateKey,
        JSON.stringify({ token: "apns-or-fcm-token" }),
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      ),
    );
    expect(pushTokenResponse.status).toBe(200);
    expect(await pushTokenResponse.json()).toEqual({
      device_id: deviceID,
      platform: "macos",
      registered: true,
    });

    const unregisterPushTokenResponse = await SELF.fetch(
      await signedRequest(
        "/v1/sync/notifications",
        "DELETE",
        deviceID,
        signingKeys.privateKey,
        "",
        "cccccccccccccccccccccccccccccccc",
      ),
    );
    expect(unregisterPushTokenResponse.status).toBe(200);
    expect(await unregisterPushTokenResponse.json()).toEqual({
      device_id: deviceID,
      platform: "macos",
      registered: false,
    });

    const pullRequest = await signedRequest("/v1/sync/events?cursor=MA", "GET", deviceID, signingKeys.privateKey);
    const pullResponse = await SELF.fetch(pullRequest);
    expect(pullResponse.status).toBe(200);
    const pulled = await pullResponse.json() as {
      events: Array<{ envelope: Record<string, unknown> }>;
    };
    expect(pulled.events).toHaveLength(1);
    expect(pulled.events[0]?.envelope.ciphertext).toBe("ZW5jcnlwdGVkLXBheWxvYWQ");
    expect(pulled.events[0]?.envelope).not.toHaveProperty("payload");
    expect(pulled.events[0]?.envelope).not.toHaveProperty("screenshot");

    const replayedProof = await SELF.fetch(
      await signedRequest(
        "/v1/sync/events?cursor=MA",
        "GET",
        deviceID,
        signingKeys.privateKey,
        "",
        "fedcba9876543210fedcba9876543210",
      ),
    );
    expect(replayedProof.status).toBe(200);

    const replayedNonce = await SELF.fetch(
      await signedRequest(
        "/v1/sync/events?cursor=MA",
        "GET",
        deviceID,
        signingKeys.privateKey,
        "",
        "fedcba9876543210fedcba9876543210",
      ),
    );
    expect(replayedNonce.status).toBe(403);
  });
});
