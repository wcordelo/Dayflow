import { describe, expect, it } from "vitest";
import { canonicalDeviceRequest, sha256Hex, verifyDeviceProof } from "./device-proof";
import type { DeviceRecord } from "./relay";

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function base64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

describe("device request proof", () => {
  it("matches the Rust canonical request vector", () => {
    expect(
      canonicalDeviceRequest(
        "post",
        "/v1/sync/events?cursor=abc",
        "b7e6d00fedcbdee445a53f6b804273eeb7a62879a6891f7bdc4f9b238675a4f4",
        1_723_456_789,
        "0123456789abcdef0123456789abcdef",
        "mac-device",
      ),
    ).toBe(
      "dayflow:v1:1723456789:POST:/v1/sync/events?cursor=abc:b7e6d00fedcbdee445a53f6b804273eeb7a62879a6891f7bdc4f9b238675a4f4:0123456789abcdef0123456789abcdef:mac-device",
    );
  });

  it("verifies the canonical request and rejects a changed body", async () => {
    const keys = await crypto.subtle.generateKey(
      { name: "Ed25519", namedCurve: "Ed25519" } as AlgorithmIdentifier,
      true,
      ["sign", "verify"],
    ) as CryptoKeyPair;
    const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
    const body = JSON.stringify({ hello: "opaque" });
    const timestamp = Math.floor(Date.now() / 1_000);
    const nonce = "0123456789abcdef0123456789abcdef";
    const deviceID = "mac-device";
    const request = new Request("https://relay.example/v1/sync/events", {
      method: "POST",
      body,
      headers: {
        "X-Dayflow-Device-ID": deviceID,
        "X-Dayflow-Device-Timestamp": String(timestamp),
        "X-Dayflow-Device-Nonce": nonce,
      },
    });
    const bodyHash = await sha256Hex(new TextEncoder().encode(body));
    const message = canonicalDeviceRequest(
      "POST",
      "/v1/sync/events",
      bodyHash,
      timestamp,
      nonce,
      deviceID,
    );
    const signature = new Uint8Array(await crypto.subtle.sign(
      { name: "Ed25519" } as AlgorithmIdentifier,
      keys.privateKey,
      arrayBuffer(new TextEncoder().encode(message)),
    ));
    request.headers.set("X-Dayflow-Device-Signature", base64(signature));

    const device: DeviceRecord = {
      device_id: deviceID,
      public_key: base64(new Uint8Array(32)),
      signing_public_key: base64(publicKey),
      display_name: "Mac",
      platform: "macos",
      status: "approved",
      created_at: timestamp,
      last_seen_at: timestamp,
    };

    expect((await verifyDeviceProof(request, body, device)).ok).toBe(true);
    expect((await verifyDeviceProof(request, JSON.stringify({ hello: "changed" }), device)).ok).toBe(false);
  });
});
