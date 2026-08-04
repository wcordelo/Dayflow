import { DurableObject } from "cloudflare:workers";
import type {
  DeviceRecord,
  DeviceRegistrationResult,
  DeviceRegistration,
  DeviceStatus,
  EventEnvelope,
  NotificationHintsResult,
  PullResult,
  PushResult,
  PushRegistrationResult,
  PushWakeJob,
  RelayResult,
  WrappedKeyRecord,
} from "./relay";
import {
  MAX_EVENT_BATCH_SIZE,
  buildPushWakeBatch,
  formatCursor,
  failure,
  parseDeviceRegistration,
  parseEventEnvelope,
  parsePushRegistration,
  parseWrappedKey,
  success,
} from "./relay";

type DeviceRow = DeviceRecord & Record<string, SqlStorageValue>;

type EventRow = {
  sequence: number;
  event_id: string;
  device_id: string;
  logical_clock: number;
  schema_version: number;
  key_version: number;
  nonce: string;
  ciphertext: string;
} & Record<string, SqlStorageValue>;

type StoredEventEnvelope = Pick<
  EventEnvelope,
  "device_id" | "logical_clock" | "schema_version" | "key_version" | "nonce" | "ciphertext"
>;

type NotificationRow = {
  sequence: number;
  kind: "sync_available";
} & Record<string, SqlStorageValue>;

type PushRegistrationRow = {
  device_id: string;
  platform: "macos" | "windows" | "android" | "chromeos" | "ios";
  token: string | null;
} & Record<string, SqlStorageValue>;

type WrappedKeyRow = WrappedKeyRecord & Record<string, SqlStorageValue>;

function sameEventEnvelope(left: StoredEventEnvelope, right: StoredEventEnvelope): boolean {
  return (
    left.device_id === right.device_id &&
    left.logical_clock === right.logical_clock &&
    left.schema_version === right.schema_version &&
    left.key_version === right.key_version &&
    left.nonce === right.nonce &&
    left.ciphertext === right.ciphertext
  );
}

export class AccountRelay extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => this.migrate());
  }

  private migrate(): void {
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS _schema_migrations (
        id INTEGER PRIMARY KEY,
        applied_at INTEGER NOT NULL
      );
    `);

    const currentVersion = this.ctx.storage.sql
      .exec<{ id: number }>("SELECT COALESCE(MAX(id), 0) AS id FROM _schema_migrations")
      .one().id;

    if (currentVersion < 1) {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS devices (
          device_id TEXT PRIMARY KEY NOT NULL,
          public_key TEXT NOT NULL,
          display_name TEXT NOT NULL,
          platform TEXT NOT NULL,
          status TEXT NOT NULL CHECK(status IN ('pending', 'approved', 'revoked')),
          created_at INTEGER NOT NULL,
          last_seen_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS wrapped_keys (
          device_id TEXT PRIMARY KEY NOT NULL,
          key_version INTEGER NOT NULL,
          wrapped_account_key TEXT NOT NULL,
          wrapped_by_device_id TEXT NOT NULL,
          created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          event_id TEXT NOT NULL UNIQUE,
          device_id TEXT NOT NULL,
          logical_clock INTEGER NOT NULL,
          schema_version INTEGER NOT NULL,
          key_version INTEGER NOT NULL,
          nonce TEXT NOT NULL,
          ciphertext TEXT NOT NULL,
          received_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_sequence ON events(sequence);
        CREATE TABLE IF NOT EXISTS notification_hints (
          device_id TEXT NOT NULL,
          sequence INTEGER NOT NULL,
          kind TEXT NOT NULL CHECK(kind = 'sync_available'),
          created_at INTEGER NOT NULL,
          PRIMARY KEY(device_id, sequence)
        );
        CREATE INDEX IF NOT EXISTS idx_notification_hints_device_sequence
          ON notification_hints(device_id, sequence);
        CREATE TABLE IF NOT EXISTS key_bootstrap_grants (
          device_id TEXT PRIMARY KEY NOT NULL,
          created_at INTEGER NOT NULL
        );
        INSERT INTO _schema_migrations (id, applied_at)
        VALUES (1, strftime('%s', 'now'));
      `);
    }

    if (currentVersion < 2) {
      this.ctx.storage.sql.exec(`
        ALTER TABLE devices ADD COLUMN signing_public_key TEXT NOT NULL DEFAULT '';
        CREATE TABLE IF NOT EXISTS request_nonces (
          device_id TEXT NOT NULL,
          nonce TEXT NOT NULL,
          expires_at INTEGER NOT NULL,
          PRIMARY KEY(device_id, nonce)
        );
        CREATE INDEX IF NOT EXISTS idx_request_nonces_expiry ON request_nonces(expires_at);
        INSERT INTO _schema_migrations (id, applied_at)
        VALUES (2, strftime('%s', 'now'));
      `);
    }

    if (currentVersion < 3) {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS wrapped_key_versions (
          device_id TEXT NOT NULL,
          key_version INTEGER NOT NULL,
          wrapped_account_key TEXT NOT NULL,
          wrapped_by_device_id TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          PRIMARY KEY(device_id, key_version)
        );
        INSERT OR IGNORE INTO wrapped_key_versions
          (device_id, key_version, wrapped_account_key, wrapped_by_device_id, created_at)
        SELECT device_id, key_version, wrapped_account_key, wrapped_by_device_id, created_at
        FROM wrapped_keys;
        CREATE INDEX IF NOT EXISTS idx_wrapped_key_versions_device
          ON wrapped_key_versions(device_id, key_version);
        INSERT INTO _schema_migrations (id, applied_at)
        VALUES (3, strftime('%s', 'now'));
      `);
    }

    if (currentVersion < 4) {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS key_bootstrap_grants (
          device_id TEXT PRIMARY KEY NOT NULL,
          created_at INTEGER NOT NULL
        );
        INSERT INTO _schema_migrations (id, applied_at)
        VALUES (4, strftime('%s', 'now'));
      `);
    }

    if (currentVersion < 5) {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS push_registrations (
          device_id TEXT PRIMARY KEY NOT NULL,
          token TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_push_registrations_device
          ON push_registrations(device_id);
        INSERT INTO _schema_migrations (id, applied_at)
        VALUES (5, strftime('%s', 'now'));
      `);
    }
  }

  private now(): number {
    return Math.floor(Date.now() / 1_000);
  }

  private findDevice(deviceID: string): DeviceRow | null {
    return this.ctx.storage.sql
      .exec<DeviceRow>(
        `SELECT device_id, public_key, signing_public_key, display_name, platform, status, created_at, last_seen_at
         FROM devices WHERE device_id = ?`,
        deviceID,
      )
      .toArray()[0] ?? null;
  }

  private requireApproved(deviceID: string): RelayResult<DeviceRow> {
    const device = this.findDevice(deviceID);
    if (device === null) {
      return failure("not_found", "device is not registered");
    }
    if (device.status !== "approved") {
      return failure("not_approved", "device is not approved");
    }
    this.ctx.storage.sql.exec(
      "UPDATE devices SET last_seen_at = ? WHERE device_id = ?",
      this.now(),
      deviceID,
    );
    return success(device);
  }

  async registerDevice(input: unknown): Promise<RelayResult<DeviceRegistrationResult>> {
    let registration: DeviceRegistration;
    try {
      registration = parseDeviceRegistration(input);
    } catch (error) {
      return failure("invalid_request", error instanceof Error ? error.message : "invalid device registration");
    }

    const existing = this.findDevice(registration.device_id);
    if (existing !== null) {
      const hasApprovedDevice = this.ctx.storage.sql
        .exec<{ count: number }>("SELECT COUNT(*) AS count FROM devices WHERE status = 'approved'")
        .one().count > 0;
      const canReAdmitRevokedDevice =
        existing.status === "revoked" && registration.recovery_mode === true && !hasApprovedDevice;

      // Recovery kits are the authority for re-admitting a device after every
      // approved device has been removed. Device IDs are stable per install,
      // so a restored kit can legitimately arrive with the same ID as a
      // previously revoked record. Permit replacement identity material only
      // in this narrow recovery state; ordinary registrations must never
      // overwrite a device's public keys.
      if (existing.status === "revoked" && registration.recovery_mode === true && !canReAdmitRevokedDevice) {
        return failure(
          "forbidden",
          "a revoked device can only be re-admitted in recovery mode after all approved devices are gone",
        );
      }

      if (canReAdmitRevokedDevice) {
        const now = this.now();
        // Delete stale wrappers before changing the device back to approved.
        // If a request is interrupted, the device remains revoked and the
        // recovery request can safely retry; an approved device is never left
        // pointing at ciphertext wrapped to an old public key.
        this.ctx.storage.sql.exec(
          "DELETE FROM wrapped_key_versions WHERE device_id = ?",
          registration.device_id,
        );
        this.ctx.storage.sql.exec(
          "DELETE FROM wrapped_keys WHERE device_id = ?",
          registration.device_id,
        );
        this.ctx.storage.sql.exec(
          "DELETE FROM push_registrations WHERE device_id = ?",
          registration.device_id,
        );
        this.ctx.storage.sql.exec(
          "DELETE FROM key_bootstrap_grants WHERE device_id = ?",
          registration.device_id,
        );
        this.ctx.storage.sql.exec(
          `UPDATE devices
           SET public_key = ?, signing_public_key = ?, display_name = ?, platform = ?,
               status = 'approved', created_at = ?, last_seen_at = ?
           WHERE device_id = ?`,
          registration.public_key,
          registration.signing_public_key,
          registration.display_name,
          registration.platform,
          now,
          now,
          registration.device_id,
        );
        return success({
          ...registration,
          status: "approved",
          created_at: now,
          last_seen_at: now,
          key_bootstrap_required: false,
        });
      }

      if (
        existing.public_key !== registration.public_key ||
        existing.platform !== registration.platform ||
        (existing.signing_public_key !== "" && existing.signing_public_key !== registration.signing_public_key)
      ) {
        return failure("conflict", "device ID is already registered with different identity material");
      }
      const bootstrapGrant = this.ctx.storage.sql
        .exec<{ device_id: string }>(
          "SELECT device_id FROM key_bootstrap_grants WHERE device_id = ?",
          registration.device_id,
        )
        .toArray()[0] !== undefined;
      if (existing.signing_public_key === "") {
        this.ctx.storage.sql.exec(
          "UPDATE devices SET signing_public_key = ? WHERE device_id = ?",
          registration.signing_public_key,
          registration.device_id,
        );
        return success({
          ...existing,
          signing_public_key: registration.signing_public_key,
          key_bootstrap_required: bootstrapGrant,
        });
      }
      return success({ ...existing, key_bootstrap_required: bootstrapGrant });
    }

    const now = this.now();
    const hasDevice = this.ctx.storage.sql
      .exec<{ count: number }>("SELECT COUNT(*) AS count FROM devices")
      .one().count > 0;
    const hasApprovedDevice = this.ctx.storage.sql
      .exec<{ count: number }>("SELECT COUNT(*) AS count FROM devices WHERE status = 'approved'")
      .one().count > 0;
    if (registration.recovery_mode === true && hasApprovedDevice) {
      return failure(
        "forbidden",
        "recovery admission is only allowed when no approved device remains",
      );
    }
    const status: DeviceStatus = hasApprovedDevice
      ? "pending"
      : registration.recovery_mode === true || !hasDevice
        ? "approved"
        : "pending";
    const keyBootstrapRequired = status === "approved" && registration.recovery_mode !== true && !hasDevice;
    this.ctx.storage.sql.exec(
      `INSERT INTO devices
       (device_id, public_key, signing_public_key, display_name, platform, status, created_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      registration.device_id,
      registration.public_key,
      registration.signing_public_key,
      registration.display_name,
      registration.platform,
      status,
      now,
      now,
    );
    if (keyBootstrapRequired) {
      this.ctx.storage.sql.exec(
        `INSERT OR IGNORE INTO key_bootstrap_grants (device_id, created_at)
         VALUES (?, ?)`,
        registration.device_id,
        now,
      );
    }

    return success({
      ...registration,
      status,
      created_at: now,
      last_seen_at: now,
      key_bootstrap_required: keyBootstrapRequired,
    });
  }

  async listDevices(): Promise<RelayResult<DeviceRecord[]>> {
    const devices = this.ctx.storage.sql
      .exec<DeviceRow>(
        `SELECT device_id, public_key, signing_public_key, display_name, platform, status, created_at, last_seen_at
         FROM devices ORDER BY created_at ASC, device_id ASC`,
      )
      .toArray();
    return success(devices);
  }

  async getDevice(deviceID: string): Promise<RelayResult<DeviceRecord>> {
    const device = this.findDevice(deviceID);
    return device === null
      ? failure("not_found", "device is not registered")
      : success(device);
  }

  async registerPushToken(
    deviceID: string,
    input: unknown,
  ): Promise<RelayResult<PushRegistrationResult>> {
    const device = this.requireApproved(deviceID);
    if (!device.ok) {
      return device;
    }
    try {
      const registration = parsePushRegistration(input);
      const now = this.now();
      this.ctx.storage.sql.exec(
        `INSERT INTO push_registrations (device_id, token, created_at, updated_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(device_id) DO UPDATE SET token = excluded.token, updated_at = excluded.updated_at`,
        deviceID,
        registration.token,
        now,
        now,
      );
      return success({
        device_id: deviceID,
        platform: device.value.platform,
        registered: true,
      });
    } catch (error) {
      return failure("invalid_request", error instanceof Error ? error.message : "invalid push registration");
    }
  }

  async unregisterPushToken(deviceID: string): Promise<RelayResult<PushRegistrationResult>> {
    const device = this.requireApproved(deviceID);
    if (!device.ok) {
      return device;
    }
    this.ctx.storage.sql.exec(
      "DELETE FROM push_registrations WHERE device_id = ?",
      deviceID,
    );
    return success({
      device_id: deviceID,
      platform: device.value.platform,
      registered: false,
    });
  }

  async consumeRequestNonce(deviceID: string, nonce: string, expiresAt: number): Promise<RelayResult<null>> {
    const device = this.findDevice(deviceID);
    if (device === null) {
      return failure("not_found", "device is not registered");
    }
    const now = this.now();
    this.ctx.storage.sql.exec("DELETE FROM request_nonces WHERE expires_at < ?", now);
    this.ctx.storage.sql.exec(
      `INSERT OR IGNORE INTO request_nonces (device_id, nonce, expires_at)
       VALUES (?, ?, ?)`,
      deviceID,
      nonce,
      expiresAt,
    );
    const inserted = this.ctx.storage.sql
      .exec<{ changes: number }>("SELECT changes() AS changes")
      .one().changes === 1;
    return inserted
      ? success(null)
      : failure("forbidden", "device request nonce has already been used");
  }

  async approveDevice(
    targetDeviceID: string,
    approverDeviceID: string,
    input: unknown,
  ): Promise<RelayResult<DeviceRecord>> {
    const approver = this.requireApproved(approverDeviceID);
    if (!approver.ok) {
      return approver;
    }
    const target = this.findDevice(targetDeviceID);
    if (target === null) {
      return failure("not_found", "target device is not registered");
    }
    if (target.status === "revoked") {
      return failure("forbidden", "revoked devices cannot be re-approved");
    }

    let wrappedKey: Omit<WrappedKeyRecord, "created_at">;
    try {
      wrappedKey = parseWrappedKey(input, targetDeviceID, approverDeviceID);
    } catch (error) {
      return failure("invalid_request", error instanceof Error ? error.message : "invalid wrapped key");
    }

    const existingWrappedKey = this.ctx.storage.sql
      .exec<WrappedKeyRow>(
        `SELECT device_id, key_version, wrapped_account_key, wrapped_by_device_id, created_at
         FROM wrapped_key_versions WHERE device_id = ? AND key_version = ?`,
        wrappedKey.device_id,
        wrappedKey.key_version,
      )
      .toArray()[0];
    if (
      existingWrappedKey !== undefined &&
      (existingWrappedKey.wrapped_account_key !== wrappedKey.wrapped_account_key ||
        existingWrappedKey.wrapped_by_device_id !== wrappedKey.wrapped_by_device_id)
    ) {
      return failure(
        "conflict",
        "a different wrapped account key already exists for this device and key version",
      );
    }

    const now = this.now();
    this.ctx.storage.sql.exec(
      `INSERT OR IGNORE INTO wrapped_key_versions
       (device_id, key_version, wrapped_account_key, wrapped_by_device_id, created_at)
       VALUES (?, ?, ?, ?, ?)`,
      wrappedKey.device_id,
      wrappedKey.key_version,
      wrappedKey.wrapped_account_key,
      wrappedKey.wrapped_by_device_id,
      now,
    );
    this.ctx.storage.sql.exec(
      "UPDATE devices SET status = 'approved', last_seen_at = ? WHERE device_id = ?",
      now,
      targetDeviceID,
    );

    return success({ ...target, status: "approved", last_seen_at: now });
  }

  async getWrappedKey(deviceID: string): Promise<RelayResult<WrappedKeyRecord | null>> {
    const device = this.requireApproved(deviceID);
    if (!device.ok) {
      return device;
    }
    const wrappedKey = this.ctx.storage.sql
      .exec<WrappedKeyRow>(
        `SELECT device_id, key_version, wrapped_account_key, wrapped_by_device_id, created_at
         FROM wrapped_key_versions WHERE device_id = ?
         ORDER BY key_version DESC, created_at DESC LIMIT 1`,
        deviceID,
      )
      .toArray()[0] ?? null;
    return success(wrappedKey);
  }

  async getWrappedKeys(deviceID: string): Promise<RelayResult<WrappedKeyRecord[]>> {
    const device = this.requireApproved(deviceID);
    if (!device.ok) {
      return device;
    }
    const wrappedKeys = this.ctx.storage.sql
      .exec<WrappedKeyRow>(
        `SELECT device_id, key_version, wrapped_account_key, wrapped_by_device_id, created_at
         FROM wrapped_key_versions WHERE device_id = ?
         ORDER BY key_version ASC, created_at ASC`,
        deviceID,
      )
      .toArray();
    return success(wrappedKeys);
  }

  async revokeDevice(
    targetDeviceID: string,
    actorDeviceID: string,
  ): Promise<RelayResult<DeviceRecord>> {
    const actor = this.requireApproved(actorDeviceID);
    if (!actor.ok) {
      return actor;
    }
    const target = this.findDevice(targetDeviceID);
    if (target === null) {
      return failure("not_found", "target device is not registered");
    }
    const now = this.now();
    this.ctx.storage.sql.exec(
      "UPDATE devices SET status = 'revoked', last_seen_at = ? WHERE device_id = ?",
      now,
      targetDeviceID,
    );
    this.ctx.storage.sql.exec(
      "DELETE FROM push_registrations WHERE device_id = ?",
      targetDeviceID,
    );
    return success({ ...target, status: "revoked", last_seen_at: now });
  }

  async pushEvents(deviceID: string, input: unknown): Promise<RelayResult<PushResult>> {
    const device = this.requireApproved(deviceID);
    if (!device.ok) {
      return device;
    }
    if (!Array.isArray(input) || input.length === 0 || input.length > MAX_EVENT_BATCH_SIZE) {
      return failure("invalid_request", `events must contain between 1 and ${MAX_EVENT_BATCH_SIZE} envelopes`);
    }

    const envelopes: EventEnvelope[] = [];
    try {
      for (const value of input) {
        const envelope = parseEventEnvelope(value);
        if (envelope.device_id !== deviceID) {
          return failure("forbidden", "event device_id does not match the authenticated device");
        }
        if (envelope.schema_version !== 1) {
          return failure("invalid_request", "event schema_version is not supported");
        }
        envelopes.push(envelope);
      }
    } catch (error) {
      return failure("invalid_request", error instanceof Error ? error.message : "invalid event envelope");
    }

    // Preflight the complete batch before mutating storage. A retry batch must
    // be idempotent, but a conflicting envelope must not leave earlier events
    // from the same request committed when the request is rejected.
    const batchEnvelopes = new Map<string, EventEnvelope>();
    for (const envelope of envelopes) {
      const batchExisting = batchEnvelopes.get(envelope.event_id);
      if (batchExisting !== undefined && !sameEventEnvelope(batchExisting, envelope)) {
        return failure("conflict", "event_id appears more than once with different envelopes");
      }
      batchEnvelopes.set(envelope.event_id, envelope);

      const stored = this.ctx.storage.sql
        .exec<StoredEventEnvelope>(
          `SELECT device_id, logical_clock, schema_version, key_version, nonce, ciphertext
           FROM events WHERE event_id = ?`,
          envelope.event_id,
        )
        .toArray()[0];
      if (stored !== undefined && !sameEventEnvelope(stored, envelope)) {
        return failure("conflict", "event_id already exists with a different envelope");
      }
    }

    const acceptedEventIDs: string[] = [];
    const duplicateEventIDs: string[] = [];
    let latestSequence = this.ctx.storage.sql
      .exec<{ sequence: number }>("SELECT COALESCE(MAX(sequence), 0) AS sequence FROM events")
      .one().sequence;
    let notificationCount = 0;
    const pushWakes: PushWakeJob[] = [];

    for (const envelope of envelopes) {
      this.ctx.storage.sql.exec(
        `INSERT OR IGNORE INTO events
         (event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext, received_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        envelope.event_id,
        envelope.device_id,
        envelope.logical_clock,
        envelope.schema_version,
        envelope.key_version,
        envelope.nonce,
        envelope.ciphertext,
        this.now(),
      );
      const inserted = this.ctx.storage.sql
        .exec<{ changes: number }>("SELECT changes() AS changes")
        .one().changes === 1;

      const row = this.ctx.storage.sql
        .exec<{ sequence: number; device_id: string }>(
          "SELECT sequence, device_id FROM events WHERE event_id = ?",
          envelope.event_id,
        )
        .one();
      latestSequence = Math.max(latestSequence, row.sequence);
      if (inserted) {
        acceptedEventIDs.push(envelope.event_id);
      } else {
        duplicateEventIDs.push(envelope.event_id);
      }

      if (inserted) {
        const approvedDevices = this.ctx.storage.sql
          .exec<PushRegistrationRow>(
            `SELECT d.device_id, d.platform, p.token
             FROM devices d
             LEFT JOIN push_registrations p ON p.device_id = d.device_id
             WHERE d.status = 'approved' AND d.device_id <> ?`,
            deviceID,
          )
          .toArray();
        for (const recipient of approvedDevices) {
          this.ctx.storage.sql.exec(
            `INSERT OR IGNORE INTO notification_hints (device_id, sequence, kind, created_at)
             VALUES (?, ?, 'sync_available', ?)`,
            recipient.device_id,
            row.sequence,
            this.now(),
          );
          const hintInserted = this.ctx.storage.sql
            .exec<{ changes: number }>("SELECT changes() AS changes")
            .one().changes;
          notificationCount += hintInserted;
          if (hintInserted === 1 && recipient.token !== null) {
            pushWakes.push({
              device_id: recipient.device_id,
              platform: recipient.platform,
              token: recipient.token,
              sequence: row.sequence,
              kind: "sync_available",
            });
          }
        }
      }
    }

    // The first-device grant is retryable until the client has successfully
    // submitted its first encrypted event. Once the account has durable event
    // history, consume the grant so losing the local root key cannot authorize
    // a replacement key that would fork the account.
    if (acceptedEventIDs.length > 0) {
      this.ctx.storage.sql.exec(
        "DELETE FROM key_bootstrap_grants WHERE device_id = ?",
        deviceID,
      );
    }

    await this.dispatchPushWakes(pushWakes);

    return success({
      accepted_event_ids: acceptedEventIDs,
      duplicate_event_ids: duplicateEventIDs,
      cursor: formatCursor(latestSequence),
      notification_count: notificationCount,
    });
  }

  private async dispatchPushWakes(wakes: PushWakeJob[]): Promise<void> {
    if (wakes.length === 0) {
      return;
    }
    // The provider-specific dispatcher is intentionally optional in local
    // development and in relay-only deployments. Its input contains only a
    // platform token and a sync sequence; it never receives decrypted event
    // content, journal text, capture metadata, or ciphertext.
    const dispatcher = (this.env as Env & { DAYFLOW_PUSH_DISPATCHER?: Fetcher }).DAYFLOW_PUSH_DISPATCHER;
    if (dispatcher === undefined) {
      return;
    }
    try {
      const response = await dispatcher.fetch(new Request("https://dayflow.internal/v1/wake", {
        method: "POST",
        signal: AbortSignal.timeout(2_000),
        headers: {
          "content-type": "application/json",
          "x-dayflow-push-schema": "1",
        },
        body: JSON.stringify(buildPushWakeBatch(wakes)),
      }));
      if (!response.ok) {
        console.warn(JSON.stringify({ event: "dayflow_push_dispatch_failed", status: response.status }));
      }
    } catch (error) {
      // Push is advisory. A provider outage must not turn a committed
      // encrypted event into a failed sync response; foreground activation
      // and the durable notification-hint cursor remain the fallback.
      console.warn(JSON.stringify({
        event: "dayflow_push_dispatch_unavailable",
        message: error instanceof Error ? error.message : "unknown error",
      }));
    }
  }

  async pullEvents(deviceID: string, cursor: number, limit: number): Promise<RelayResult<PullResult>> {
    const device = this.requireApproved(deviceID);
    if (!device.ok) {
      return device;
    }
    const boundedLimit = Math.max(1, Math.min(limit, MAX_EVENT_BATCH_SIZE));
    const rows = this.ctx.storage.sql
      .exec<EventRow>(
        `SELECT sequence, event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext
         FROM events WHERE sequence > ? ORDER BY sequence ASC LIMIT ?`,
        cursor,
        boundedLimit,
      )
      .toArray();
    const events = rows.map((row) => ({
      sequence: row.sequence,
      envelope: {
        event_id: row.event_id,
        device_id: row.device_id,
        logical_clock: row.logical_clock,
        schema_version: row.schema_version,
        key_version: row.key_version,
        nonce: row.nonce,
        ciphertext: row.ciphertext,
      },
    }));
    const nextCursor = events.at(-1)?.sequence ?? cursor;
    return success({ cursor: formatCursor(nextCursor), events });
  }

  async pullNotificationHints(
    deviceID: string,
    cursor: number,
    limit: number,
  ): Promise<RelayResult<NotificationHintsResult>> {
    const device = this.requireApproved(deviceID);
    if (!device.ok) {
      return device;
    }
    const boundedLimit = Math.max(1, Math.min(limit, MAX_EVENT_BATCH_SIZE));
    const rows = this.ctx.storage.sql
      .exec<NotificationRow>(
        `SELECT sequence, kind FROM notification_hints
         WHERE device_id = ? AND sequence > ? ORDER BY sequence ASC LIMIT ?`,
        deviceID,
        cursor,
        boundedLimit,
      )
      .toArray();
    const nextCursor = rows.at(-1)?.sequence ?? cursor;
    return success({ cursor: formatCursor(nextCursor), hints: rows });
  }
}
