import type { DeviceRecord } from "./relay";
import { decodeBase64, RelayValidationError } from "./relay";

export const DEVICE_PROOF_MAX_SKEW_SECONDS = 300;

export function canonicalDeviceRequest(
  method: string,
  pathWithQuery: string,
  bodySha256: string,
  timestamp: number,
  nonce: string,
  deviceID: string,
): string {
  return `dayflow:v1:${timestamp}:${method.toUpperCase()}:${pathWithQuery}:${bodySha256}:${nonce}:${deviceID}`;
}

export function sha256Hex(bytes: Uint8Array): Promise<string> {
  return crypto.subtle.digest("SHA-256", asArrayBuffer(bytes)).then((digest) =>
    Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join(""),
  );
}

function asArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

export interface DeviceProofFailure {
  ok: false;
  message: string;
}

export interface DeviceProofSuccess {
  ok: true;
  nonce: string;
}

export type DeviceProofResult = DeviceProofSuccess | DeviceProofFailure;

function header(request: Request, name: string): string | null {
  const value = request.headers.get(name);
  return value === null || value.trim().length === 0 ? null : value.trim();
}

export async function verifyDeviceProof(
  request: Request,
  body: string,
  device: DeviceRecord,
): Promise<DeviceProofResult> {
  const timestampText = header(request, "X-Dayflow-Device-Timestamp");
  const nonce = header(request, "X-Dayflow-Device-Nonce");
  const signatureText = header(request, "X-Dayflow-Device-Signature");
  if (timestampText === null || nonce === null || signatureText === null) {
    return { ok: false, message: "device request signature headers are required" };
  }

  if (!/^\d{1,16}$/.test(timestampText) || !/^[A-Za-z0-9_-]{16,128}$/.test(nonce)) {
    return { ok: false, message: "device request timestamp or nonce is invalid" };
  }
  const timestamp = Number(timestampText);
  if (!Number.isSafeInteger(timestamp)) {
    return { ok: false, message: "device request timestamp is invalid" };
  }
  const skew = Math.abs(Math.floor(Date.now() / 1_000) - timestamp);
  if (skew > DEVICE_PROOF_MAX_SKEW_SECONDS) {
    return { ok: false, message: "device request signature has expired" };
  }

  let publicKey: Uint8Array;
  let signature: Uint8Array;
  try {
    publicKey = decodeBase64(device.signing_public_key, "signing_public_key");
    signature = decodeBase64(signatureText, "device signature");
  } catch (error) {
    return {
      ok: false,
      message: error instanceof RelayValidationError ? error.message : "device signature is invalid",
    };
  }
  if (publicKey.byteLength !== 32 || signature.byteLength !== 64) {
    return { ok: false, message: "device signing material has an invalid length" };
  }

  const url = new URL(request.url);
  const bodySha256 = await sha256Hex(new TextEncoder().encode(body));
  const message = canonicalDeviceRequest(
    request.method,
    `${url.pathname}${url.search}`,
    bodySha256,
    timestamp,
    nonce,
    device.device_id,
  );

  try {
    const key = await crypto.subtle.importKey(
      "raw",
      asArrayBuffer(publicKey),
      { name: "Ed25519", namedCurve: "Ed25519" } as AlgorithmIdentifier,
      false,
      ["verify"],
    );
    const valid = await crypto.subtle.verify(
      { name: "Ed25519" } as AlgorithmIdentifier,
      key,
      asArrayBuffer(signature),
      asArrayBuffer(new TextEncoder().encode(message)),
    );
    return valid
      ? { ok: true, nonce }
      : { ok: false, message: "device request signature is invalid" };
  } catch {
    return { ok: false, message: "device request signature could not be verified" };
  }
}
