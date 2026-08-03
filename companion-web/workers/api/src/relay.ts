export const RELAY_EVENT_SCHEMA_VERSION = 1;
export const MAX_EVENT_BATCH_SIZE = 100;
export const MAX_CIPHERTEXT_LENGTH = 2_000_000;
export const MAX_WRAPPED_KEY_LENGTH = 16_384;
const EVENT_NONCE_BYTES = 24;
const EVENT_AUTH_TAG_BYTES = 16;

export type DevicePlatform = "macos" | "windows" | "android" | "chromeos" | "ios";
export type DeviceStatus = "pending" | "approved" | "revoked";

export interface EventEnvelope {
  event_id: string;
  device_id: string;
  logical_clock: number;
  schema_version: number;
  key_version: number;
  nonce: string;
  ciphertext: string;
}

export interface DeviceRegistration {
  device_id: string;
  public_key: string;
  signing_public_key: string;
  display_name: string;
  platform: DevicePlatform;
  recovery_mode?: boolean;
}

export interface DeviceRecord extends DeviceRegistration {
  status: DeviceStatus;
  created_at: number;
  last_seen_at: number;
}

/**
 * Returned only by device registration. The relay persists this admission
 * grant against the first device identity so a retry after a client crash can
 * finish bootstrap without allowing later devices to fork the account key.
 */
export interface DeviceRegistrationResult extends DeviceRecord {
  key_bootstrap_required: boolean;
}

export interface WrappedKeyRecord {
  device_id: string;
  key_version: number;
  wrapped_account_key: string;
  wrapped_by_device_id: string;
  created_at: number;
}

export interface RelaySuccess<T> {
  ok: true;
  value: T;
}

export interface RelayFailure {
  ok: false;
  error: "invalid_request" | "not_found" | "not_approved" | "conflict" | "forbidden";
  message: string;
}

export type RelayResult<T> = RelaySuccess<T> | RelayFailure;

export interface PushResult {
  accepted_event_ids: string[];
  duplicate_event_ids: string[];
  cursor: string;
  notification_count: number;
}

export interface PulledEvent {
  sequence: number;
  envelope: EventEnvelope;
}

export interface PullResult {
  cursor: string;
  events: PulledEvent[];
}

export interface NotificationHint {
  sequence: number;
  kind: "sync_available";
}

export interface NotificationHintsResult {
  cursor: string;
  hints: NotificationHint[];
}

/** A platform token is a wake address, never a journal or capture payload. */
export interface PushRegistrationInput {
  token: string;
}

export interface PushRegistrationResult {
  device_id: string;
  platform: DevicePlatform;
  registered: boolean;
}

export interface PushWakeJob {
  device_id: string;
  platform: DevicePlatform;
  token: string;
  sequence: number;
  kind: "sync_available";
}

export interface PushWakeBatch {
  schema_version: 1;
  wakes: PushWakeJob[];
}

/**
 * Builds the exact provider boundary. Keeping the projection explicit makes
 * it impossible for a future relay event field to leak into a wake payload by
 * spreading an event or database row into the dispatcher request.
 */
export function buildPushWakeBatch(wakes: readonly PushWakeJob[]): PushWakeBatch {
  return {
    schema_version: 1,
    wakes: wakes.map((wake) => ({
      device_id: wake.device_id,
      platform: wake.platform,
      token: wake.token,
      sequence: wake.sequence,
      kind: wake.kind,
    })),
  };
}

export class RelayValidationError extends Error {}

const DEVICE_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;
const EVENT_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;
const BASE64_PATTERN = /^[A-Za-z0-9+/=_-]+$/;
const MAX_PUSH_TOKEN_LENGTH = 4_096;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requiredString(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw new RelayValidationError(`${field} must be a non-empty string of at most ${maxLength} characters`);
  }
  return value;
}

function pushToken(value: unknown): string {
  const parsed = requiredString(value, "token", MAX_PUSH_TOKEN_LENGTH);
  if ([...parsed].some((character) => character.charCodeAt(0) < 0x20 || character.charCodeAt(0) === 0x7f)) {
    throw new RelayValidationError("token contains unsupported control characters");
  }
  return parsed;
}

function identifier(value: unknown, field: string, pattern: RegExp): string {
  const parsed = requiredString(value, field, 128);
  if (!pattern.test(parsed)) {
    throw new RelayValidationError(`${field} contains unsupported characters`);
  }
  return parsed;
}

function integer(value: unknown, field: string, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new RelayValidationError(`${field} must be a safe integer between ${minimum} and ${maximum}`);
  }
  return value;
}

function opaqueBase64(value: unknown, field: string, maxLength: number): string {
  const parsed = requiredString(value, field, maxLength);
  if (!BASE64_PATTERN.test(parsed)) {
    throw new RelayValidationError(`${field} must be base64 or base64url text`);
  }
  return parsed;
}

function encryptedEventField(
  value: unknown,
  field: string,
  maxLength: number,
  expectedLength: number | null,
  minimumLength: number | null,
): string {
  const parsed = opaqueBase64(value, field, maxLength);
  const decoded = decodeBase64(parsed, field);
  if (expectedLength !== null && decoded.byteLength !== expectedLength) {
    throw new RelayValidationError(`${field} must contain exactly ${expectedLength} bytes`);
  }
  if (minimumLength !== null && decoded.byteLength < minimumLength) {
    throw new RelayValidationError(`${field} must contain at least ${minimumLength} bytes`);
  }
  return parsed;
}

export function decodeBase64(value: string, field: string): Uint8Array {
  try {
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
    const decoded = atob(padded);
    return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  } catch {
    throw new RelayValidationError(`${field} must be valid base64 or base64url text`);
  }
}

export function parseEventEnvelope(value: unknown): EventEnvelope {
  if (!isRecord(value)) {
    throw new RelayValidationError("event envelope must be an object");
  }

  const schemaVersion = integer(value.schema_version, "schema_version", 1, 65_535);
  if (schemaVersion !== RELAY_EVENT_SCHEMA_VERSION) {
    throw new RelayValidationError("event schema_version is not supported");
  }

  return {
    event_id: identifier(value.event_id, "event_id", EVENT_ID_PATTERN),
    device_id: identifier(value.device_id, "device_id", DEVICE_ID_PATTERN),
    logical_clock: integer(value.logical_clock, "logical_clock", 1, Number.MAX_SAFE_INTEGER),
    schema_version: schemaVersion,
    key_version: integer(value.key_version, "key_version", 1, 4_294_967_295),
    nonce: encryptedEventField(value.nonce, "nonce", 256, EVENT_NONCE_BYTES, null),
    ciphertext: encryptedEventField(value.ciphertext, "ciphertext", MAX_CIPHERTEXT_LENGTH, null, EVENT_AUTH_TAG_BYTES),
  };
}

export function parseDeviceRegistration(value: unknown): DeviceRegistration {
  if (!isRecord(value)) {
    throw new RelayValidationError("device registration must be an object");
  }

  const platform = value.platform;
  if (platform !== "macos" && platform !== "windows" && platform !== "android" && platform !== "chromeos" && platform !== "ios") {
    throw new RelayValidationError("platform is not supported");
  }
  if (value.recovery_mode !== undefined && typeof value.recovery_mode !== "boolean") {
    throw new RelayValidationError("recovery_mode must be a boolean");
  }

  const publicKey = opaqueBase64(value.public_key, "public_key", 512);
  const signingPublicKey = opaqueBase64(value.signing_public_key, "signing_public_key", 512);
  if (decodeBase64(publicKey, "public_key").byteLength !== 32) {
    throw new RelayValidationError("public_key must contain 32 bytes");
  }
  if (decodeBase64(signingPublicKey, "signing_public_key").byteLength !== 32) {
    throw new RelayValidationError("signing_public_key must contain 32 bytes");
  }

  return {
    device_id: identifier(value.device_id, "device_id", DEVICE_ID_PATTERN),
    public_key: publicKey,
    signing_public_key: signingPublicKey,
    display_name: requiredString(value.display_name, "display_name", 128),
    platform,
    recovery_mode: value.recovery_mode === true,
  };
}

export function parseWrappedKey(value: unknown, expectedDeviceID: string, approverDeviceID: string): Omit<WrappedKeyRecord, "created_at"> {
  if (!isRecord(value)) {
    throw new RelayValidationError("wrapped key must be an object");
  }

  const wrappedBy = identifier(value.wrapped_by_device_id, "wrapped_by_device_id", DEVICE_ID_PATTERN);
  if (wrappedBy !== approverDeviceID) {
    throw new RelayValidationError("wrapped key approver does not match the authenticated device");
  }

  return {
    device_id: identifier(expectedDeviceID, "device_id", DEVICE_ID_PATTERN),
    key_version: integer(value.key_version, "key_version", 1, 4_294_967_295),
    wrapped_account_key: opaqueBase64(value.wrapped_account_key, "wrapped_account_key", MAX_WRAPPED_KEY_LENGTH),
    wrapped_by_device_id: wrappedBy,
  };
}

export function parsePushRegistration(value: unknown): PushRegistrationInput {
  if (!isRecord(value)) {
    throw new RelayValidationError("push registration must be an object");
  }
  return { token: pushToken(value.token) };
}

export function parseCursor(value: string | null): number {
  if (value === null || value.length === 0) {
    return 0;
  }

  try {
    const decoded = atob(value.replace(/-/g, "+").replace(/_/g, "/"));
    return integer(Number(decoded), "cursor", 0, Number.MAX_SAFE_INTEGER);
  } catch {
    throw new RelayValidationError("cursor is invalid");
  }
}

export function formatCursor(sequence: number): string {
  integer(sequence, "sequence", 0, Number.MAX_SAFE_INTEGER);
  return btoa(String(sequence)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

export function success<T>(value: T): RelaySuccess<T> {
  return { ok: true, value };
}

export function failure(
  error: RelayFailure["error"],
  message: string,
): RelayFailure {
  return { ok: false, error, message };
}
