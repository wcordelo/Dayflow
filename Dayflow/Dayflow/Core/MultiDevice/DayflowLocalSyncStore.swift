import Foundation
import GRDB

private enum DayflowLocalSyncStoreError: LocalizedError {
  case missingAccount
  case invalidEnvelope(String)
  case conflictingEnvelope(String)
  case databaseFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingAccount:
      return "Dayflow cannot merge encrypted events without an active account."
    case .invalidEnvelope(let message):
      return message
    case .conflictingEnvelope(let eventID):
      return "Event ID '\(eventID)' already exists with a different envelope."
    case .databaseFailed(let message):
      return message
    }
  }
}

/// Local encrypted outbox storage for the Mac client.
///
/// The table contains routing metadata and ciphertext only. This is intentionally
/// a seam: the Rust core will own envelope creation/decryption once its Apple
/// binary is packaged, while GRDB owns crash-safe local durability today.
extension StorageManager {
  func ensureMultiDeviceSchema() {
    do {
      try timedWrite("migrate_multi_device_sync") { db in
        try db.execute(
          sql: """
            CREATE TABLE IF NOT EXISTS dayflow_sync_events (
              event_id TEXT PRIMARY KEY NOT NULL,
              device_id TEXT NOT NULL,
              logical_clock INTEGER NOT NULL,
              schema_version INTEGER NOT NULL,
              key_version INTEGER NOT NULL,
              nonce TEXT NOT NULL,
              ciphertext TEXT NOT NULL,
              state TEXT NOT NULL DEFAULT 'pending'
                CHECK(state IN ('pending', 'acknowledged')),
              created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
              acknowledged_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_dayflow_sync_events_state_clock
              ON dayflow_sync_events(state, logical_clock, event_id);
            CREATE INDEX IF NOT EXISTS idx_dayflow_sync_events_device_clock
              ON dayflow_sync_events(device_id, logical_clock);

            CREATE TABLE IF NOT EXISTS dayflow_sync_metadata (
              key TEXT PRIMARY KEY NOT NULL,
              value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS dayflow_sync_migration_records (
              stable_id TEXT PRIMARY KEY NOT NULL,
              event_id TEXT NOT NULL UNIQUE,
              source_kind TEXT NOT NULL,
              source_day TEXT NOT NULL,
              source_record_id TEXT,
              migration_version INTEGER NOT NULL,
              migrated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_dayflow_sync_migration_version
              ON dayflow_sync_migration_records(migration_version, source_day);

            CREATE TABLE IF NOT EXISTS dayflow_sync_projection (
              id INTEGER PRIMARY KEY CHECK(id = 1),
              projection_json TEXT NOT NULL,
              updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );

            CREATE TABLE IF NOT EXISTS dayflow_sync_projection_records (
              stable_id TEXT PRIMARY KEY NOT NULL,
              record_kind TEXT NOT NULL,
              local_record_id INTEGER,
              updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );

            -- Account-scoped v2 tables. The original tables are intentionally
            -- left readable for rollback/debugging, but no current account is
            -- ever allowed to read their unscoped rows.
            CREATE TABLE IF NOT EXISTS dayflow_sync_events_v2 (
              account_id TEXT NOT NULL,
              event_id TEXT NOT NULL,
              device_id TEXT NOT NULL,
              logical_clock INTEGER NOT NULL,
              schema_version INTEGER NOT NULL,
              key_version INTEGER NOT NULL,
              nonce TEXT NOT NULL,
              ciphertext TEXT NOT NULL,
              state TEXT NOT NULL DEFAULT 'pending'
                CHECK(state IN ('pending', 'acknowledged')),
              created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
              acknowledged_at INTEGER,
              PRIMARY KEY(account_id, event_id)
            );
            CREATE INDEX IF NOT EXISTS idx_dayflow_sync_events_v2_state_clock
              ON dayflow_sync_events_v2(account_id, state, logical_clock, event_id);
            CREATE INDEX IF NOT EXISTS idx_dayflow_sync_events_v2_device_clock
              ON dayflow_sync_events_v2(account_id, device_id, logical_clock);

            CREATE TABLE IF NOT EXISTS dayflow_sync_metadata_v2 (
              account_id TEXT NOT NULL,
              key TEXT NOT NULL,
              value TEXT NOT NULL,
              PRIMARY KEY(account_id, key)
            );

            CREATE TABLE IF NOT EXISTS dayflow_sync_migration_records_v2 (
              account_id TEXT NOT NULL,
              stable_id TEXT NOT NULL,
              event_id TEXT NOT NULL,
              source_kind TEXT NOT NULL,
              source_day TEXT NOT NULL,
              source_record_id TEXT,
              migration_version INTEGER NOT NULL,
              migrated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
              PRIMARY KEY(account_id, stable_id),
              UNIQUE(account_id, event_id)
            );
            CREATE INDEX IF NOT EXISTS idx_dayflow_sync_migration_v2_version
              ON dayflow_sync_migration_records_v2(account_id, migration_version, source_day);

            CREATE TABLE IF NOT EXISTS dayflow_sync_projections_v2 (
              account_id TEXT PRIMARY KEY NOT NULL,
              projection_json TEXT NOT NULL,
              updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
            );

            CREATE TABLE IF NOT EXISTS dayflow_sync_projection_records_v2 (
              account_id TEXT NOT NULL,
              stable_id TEXT NOT NULL,
              record_kind TEXT NOT NULL,
              local_record_id INTEGER,
              updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
              PRIMARY KEY(account_id, stable_id)
            );

            CREATE TABLE IF NOT EXISTS dayflow_sync_priorities_v2 (
              account_id TEXT NOT NULL,
              stable_id TEXT NOT NULL,
              day TEXT NOT NULL,
              rank INTEGER NOT NULL,
              text TEXT NOT NULL,
              status TEXT NOT NULL,
              updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
              PRIMARY KEY(account_id, stable_id)
            );
            CREATE INDEX IF NOT EXISTS idx_dayflow_sync_priorities_v2_day
              ON dayflow_sync_priorities_v2(account_id, day, rank, stable_id);

            CREATE TABLE IF NOT EXISTS dayflow_sync_settings_v2 (
              account_id TEXT NOT NULL,
              key TEXT NOT NULL,
              value TEXT NOT NULL,
              updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
              PRIMARY KEY(account_id, key)
            );

            -- Projection JSON is derived plaintext, not sync state. The v2
            -- cache table is retained only for rollback/schema compatibility;
            -- current code never reads it, so opening one account must not
            -- delete another account's derived cache.
            """
        )
      }
    } catch {
      print("⚠️ [MultiDevice] Unable to create local encrypted sync schema: \(error)")
    }
  }

  @discardableResult
  func enqueueMultiDeviceEvent(
    _ envelope: DayflowEventEnvelope,
    accountScope: String? = nil
  ) -> Bool {
    let accountID = accountScope ?? DayflowMultiDeviceAccountScope.current
      ?? DayflowMultiDeviceAccountScope.localWorkspace
    do {
      try validateEnvelope(envelope)
      try timedWrite("enqueue_multi_device_event") { db in
        try rejectConflictingEnvelope(envelope, accountID: accountID, in: db)
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO dayflow_sync_events_v2
              (account_id, event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            accountID,
            envelope.eventID,
            envelope.deviceID,
            Int64(clamping: envelope.logicalClock),
            Int64(envelope.schemaVersion),
            Int64(envelope.keyVersion),
            envelope.nonce,
            envelope.ciphertext,
          ]
        )
      }
      return true
    } catch {
      print("⚠️ [MultiDevice] Unable to enqueue encrypted event: \(error)")
      return false
    }
  }

  func pendingMultiDeviceEvents(
    limit: Int = 100,
    accountScope: String? = nil
  ) -> [DayflowEventEnvelope] {
    do {
      return try throwingPendingMultiDeviceEvents(limit: limit, accountScope: accountScope)
    } catch {
      print("⚠️ [MultiDevice] Unable to read encrypted outbox: \(error)")
      return []
    }
  }

  /// Reads the pending outbox without converting a database or row-shape
  /// failure into an empty queue. Sync uses this throwing form so a local
  /// storage problem cannot be mistaken for "nothing to push".
  func throwingPendingMultiDeviceEvents(
    limit: Int = 100,
    accountScope: String? = nil
  ) throws -> [DayflowEventEnvelope] {
    let accountID = accountScope ?? DayflowMultiDeviceAccountScope.current
      ?? DayflowMultiDeviceAccountScope.localWorkspace
    let boundedLimit = max(1, min(limit, 1_000))
    return try timedRead("fetch_pending_multi_device_events") { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext
          FROM dayflow_sync_events_v2
          WHERE account_id = ? AND state = 'pending'
          ORDER BY logical_clock ASC, device_id ASC, event_id ASC
          LIMIT ?
          """,
        arguments: [accountID, boundedLimit]
      )

      return try rows.map { try decodeMultiDeviceEnvelope(from: $0) }
    }
  }

  func allMultiDeviceEvents(
    limit: Int = 100_000,
    accountScope: String? = nil
  ) -> [DayflowEventEnvelope] {
    do {
      return try throwingAllMultiDeviceEvents(limit: limit, accountScope: accountScope)
    } catch {
      print("⚠️ [MultiDevice] Unable to read local encrypted events: \(error)")
      return []
    }
  }

  /// Reads the complete local encrypted event stream without silently
  /// dropping a failed query or malformed row. Projection and local-workspace
  /// linking use this throwing form because an empty stream is not a valid
  /// fallback for a storage failure.
  func throwingAllMultiDeviceEvents(
    limit: Int = 100_000,
    accountScope: String? = nil
  ) throws -> [DayflowEventEnvelope] {
    let accountID = accountScope ?? DayflowMultiDeviceAccountScope.current
      ?? DayflowMultiDeviceAccountScope.localWorkspace
    let boundedLimit = max(1, min(limit, 100_000))
    return try timedRead("fetch_all_multi_device_events") { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext
          FROM dayflow_sync_events_v2
          WHERE account_id = ?
          ORDER BY logical_clock ASC, device_id ASC, event_id ASC
          LIMIT ?
          """,
        arguments: [accountID, boundedLimit]
      )
      return try rows.map { try decodeMultiDeviceEnvelope(from: $0) }
    }
  }

  func multiDeviceEvent(
    eventID: String,
    accountScope: String? = nil
  ) -> DayflowEventEnvelope? {
    do {
      return try throwingMultiDeviceEvent(eventID: eventID, accountScope: accountScope)
    } catch {
      print("⚠️ [MultiDevice] Unable to read migration event: \(error)")
      return nil
    }
  }

  /// Reads one immutable event without hiding local database failures. The
  /// migration retry path uses this form so it never reseals an event merely
  /// because a lookup failed.
  func throwingMultiDeviceEvent(
    eventID: String,
    accountScope: String? = nil
  ) throws -> DayflowEventEnvelope? {
    let accountID = accountScope ?? DayflowMultiDeviceAccountScope.current
      ?? DayflowMultiDeviceAccountScope.localWorkspace
    guard eventID.isEmpty == false else { return nil }

    return try timedRead("fetch_multi_device_event") { db in
      guard let row = try Row.fetchOne(
        db,
        sql: """
          SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext
          FROM dayflow_sync_events_v2
          WHERE account_id = ? AND event_id = ?
          """,
        arguments: [accountID, eventID]
      ) else {
        return nil
      }
      return try decodeMultiDeviceEnvelope(from: row)
    }
  }

  /// Merge remote envelopes without ever decoding their ciphertext in Swift.
  /// The Rust core validates/authenticates them before this method is called;
  /// GRDB additionally refuses a conflicting immutable event ID at rest.
  @discardableResult
  func mergeMultiDeviceEvents(
    _ envelopes: [DayflowEventEnvelope],
    accountScope: String? = nil
  ) throws -> Int {
    guard let accountID = accountScope ?? DayflowMultiDeviceAccountScope.current else {
      throw DayflowLocalSyncStoreError.missingAccount
    }
    guard envelopes.isEmpty == false else { return 0 }

    for envelope in envelopes {
      try validateEnvelope(envelope)
    }

    // Do not turn a protocol conflict or a database failure into a successful
    // zero-insert result. The sync coordinator must surface the failure so the
    // user can retry, rather than advancing its cursor while local state is
    // incomplete.
    return try timedWrite("merge_multi_device_events") { db in
      var inserted = 0
      for envelope in envelopes {
        try rejectConflictingEnvelope(envelope, accountID: accountID, in: db)
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO dayflow_sync_events_v2
              (account_id, event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext, state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'acknowledged')
          """,
          arguments: [
            accountID,
            envelope.eventID,
            envelope.deviceID,
            Int64(clamping: envelope.logicalClock),
            Int64(envelope.schemaVersion),
            Int64(envelope.keyVersion),
            envelope.nonce,
            envelope.ciphertext,
          ]
        )
        inserted += db.changesCount
      }

      // A Lamport clock must move past remote events before this device emits
      // its next local event. Keep the clock update in the same transaction as
      // the envelope merge so a failed/conflicting batch cannot advance it.
      if let maximumRemoteClock = envelopes.map(\.logicalClock).max() {
        let currentClock = try Int64.fetchOne(
          db,
          sql: "SELECT value FROM dayflow_sync_metadata_v2 WHERE account_id = ? AND key = 'logical_clock'",
          arguments: [accountID]
        ) ?? 0
        if currentClock < Int64(clamping: maximumRemoteClock) {
          try db.execute(
            sql: """
              INSERT INTO dayflow_sync_metadata_v2(account_id, key, value)
              VALUES (?, 'logical_clock', ?)
              ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value
              """,
            arguments: [accountID, String(maximumRemoteClock)]
          )
        }
      }
      return inserted
    }
  }

  private func rejectConflictingEnvelope(
    _ envelope: DayflowEventEnvelope,
    accountID: String,
    in db: Database
  ) throws {
    guard let row = try Row.fetchOne(
      db,
      sql: """
        SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext
        FROM dayflow_sync_events_v2
        WHERE account_id = ? AND event_id = ?
        """,
      arguments: [accountID, envelope.eventID]
    ) else {
      return
    }

    guard
      let eventID: String = row["event_id"],
      let deviceID: String = row["device_id"],
      let logicalClock: Int64 = row["logical_clock"],
      let schemaVersion: Int64 = row["schema_version"],
      let keyVersion: Int64 = row["key_version"],
      let nonce: String = row["nonce"],
      let ciphertext: String = row["ciphertext"]
    else {
      throw DayflowLocalSyncStoreError.conflictingEnvelope(envelope.eventID)
    }

    let existing = DayflowEventEnvelope(
      eventID: eventID,
      deviceID: deviceID,
      logicalClock: UInt64(clamping: logicalClock),
      schemaVersion: UInt16(clamping: schemaVersion),
      keyVersion: UInt32(clamping: keyVersion),
      nonce: nonce,
      ciphertext: ciphertext
    )
    guard existing == envelope else {
      throw DayflowLocalSyncStoreError.conflictingEnvelope(envelope.eventID)
    }
  }

  private func decodeMultiDeviceEnvelope(from row: Row) throws -> DayflowEventEnvelope {
    guard
      let eventID: String = row["event_id"],
      let deviceID: String = row["device_id"],
      let logicalClock: Int64 = row["logical_clock"],
      let schemaVersion: Int64 = row["schema_version"],
      let keyVersion: Int64 = row["key_version"],
      let nonce: String = row["nonce"],
      let ciphertext: String = row["ciphertext"]
    else {
      throw DayflowLocalSyncStoreError.databaseFailed(
        "The encrypted event row is missing required envelope fields."
      )
    }

    let envelope = DayflowEventEnvelope(
      eventID: eventID,
      deviceID: deviceID,
      logicalClock: UInt64(clamping: logicalClock),
      schemaVersion: UInt16(clamping: schemaVersion),
      keyVersion: UInt32(clamping: keyVersion),
      nonce: nonce,
      ciphertext: ciphertext
    )
    try validateEnvelope(envelope)
    return envelope
  }

  private func validateEnvelope(_ envelope: DayflowEventEnvelope) throws {
    guard envelope.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      envelope.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      envelope.logicalClock > 0,
      envelope.logicalClock <= DayflowEventEnvelope.maxLogicalClock,
      envelope.schemaVersion == DayflowEventEnvelope.currentSchemaVersion,
      envelope.keyVersion > 0,
      DayflowWireEnvelopeValidation.hasValidEncryptedFieldShape(
        nonce: envelope.nonce,
        ciphertext: envelope.ciphertext
      )
    else {
      throw DayflowLocalSyncStoreError.invalidEnvelope(
        "The encrypted event envelope is incomplete or outside the shared wire contract."
      )
    }
  }

  @discardableResult
  func acknowledgeMultiDeviceEvents(_ eventIDs: [String]) -> Int {
    guard let accountID = DayflowMultiDeviceAccountScope.current else { return 0 }
    let ids = eventIDs.filter { $0.isEmpty == false }
    guard ids.isEmpty == false else { return 0 }

    do {
      return try timedWrite("acknowledge_multi_device_events") { db in
        var acknowledged = 0
        for eventID in ids {
          try db.execute(
            sql: """
              UPDATE dayflow_sync_events_v2
              SET state = 'acknowledged', acknowledged_at = strftime('%s', 'now')
              WHERE account_id = ? AND event_id = ? AND state = 'pending'
              """,
            arguments: [accountID, eventID]
          )
          acknowledged += db.changesCount
        }
        return acknowledged
      }
    } catch {
      print("⚠️ [MultiDevice] Unable to acknowledge encrypted events: \(error)")
      return 0
    }
  }

  func multiDeviceSyncStatus() -> DayflowSyncStatus {
    let accountID = DayflowMultiDeviceAccountScope.current
      ?? DayflowMultiDeviceAccountScope.localWorkspace
    do {
      return try timedRead("multi_device_sync_status") { db in
        let pendingCount = try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM dayflow_sync_events_v2 WHERE account_id = ? AND state = 'pending'",
          arguments: [accountID]
        ) ?? 0
        let acknowledgedAtSeconds = try Int64.fetchOne(
          db,
          sql: """
            SELECT acknowledged_at
            FROM dayflow_sync_events_v2
            WHERE account_id = ? AND acknowledged_at IS NOT NULL
            ORDER BY acknowledged_at DESC
            LIMIT 1
            """,
          arguments: [accountID]
        )
        let lastSyncSeconds = try Int64.fetchOne(
          db,
          sql: """
            SELECT value
            FROM dayflow_sync_metadata_v2
            WHERE account_id = ? AND key = 'last_sync_at'
            """,
          arguments: [accountID]
        )
        let lastSuccessfulSyncSeconds = try Int64.fetchOne(
          db,
          sql: """
            SELECT value
            FROM dayflow_sync_metadata_v2
            WHERE account_id = ? AND key = 'last_successful_sync_at'
            """,
          arguments: [accountID]
        )
        let lastSyncStateRaw = try String.fetchOne(
          db,
          sql: """
            SELECT value
            FROM dayflow_sync_metadata_v2
            WHERE account_id = ? AND key = 'last_sync_state'
            """,
          arguments: [accountID]
        )
        let lastFailureCode = try String.fetchOne(
          db,
          sql: """
            SELECT value
            FROM dayflow_sync_metadata_v2
            WHERE account_id = ? AND key = 'last_sync_failure'
            """,
          arguments: [accountID]
        )
        return DayflowSyncStatus(
          pendingCount: pendingCount,
          lastAcknowledgedAt: acknowledgedAtSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) },
          lastSyncAt: lastSyncSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) },
          lastSuccessfulSyncAt: lastSuccessfulSyncSeconds.map {
            Date(timeIntervalSince1970: TimeInterval($0))
          },
          lastSyncState: DayflowSyncState(rawValue: lastSyncStateRaw ?? "") ?? .unknown,
          lastFailureCode: lastFailureCode,
          sharedCoreContractVersion: "0.1"
        )
      }
    } catch {
      return .initial
    }
  }

  /// Persists only bounded sync health metadata. Event contents and raw relay
  /// errors never enter this table, which keeps restart state useful without
  /// turning diagnostics into a second plaintext projection.
  func recordMultiDeviceSync(
    state: DayflowSyncState,
    failureCode: String? = nil,
    at date: Date = Date()
  ) throws {
    guard let accountID = DayflowMultiDeviceAccountScope.current else {
      throw DayflowLocalSyncStoreError.missingAccount
    }
    let timestamp = String(Int64(date.timeIntervalSince1970))
    let boundedFailureCode = failureCode?.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
      .prefix(48)

    try timedWrite("record_multi_device_sync") { db in
      try db.execute(
        sql: """
          INSERT INTO dayflow_sync_metadata_v2(account_id, key, value)
          VALUES (?, 'last_sync_at', ?)
          ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value
          """,
        arguments: [accountID, timestamp]
      )
      try db.execute(
        sql: """
          INSERT INTO dayflow_sync_metadata_v2(account_id, key, value)
          VALUES (?, 'last_sync_state', ?)
          ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value
          """,
        arguments: [accountID, state.rawValue]
      )

      if state == .synced {
        try db.execute(
          sql: """
            INSERT INTO dayflow_sync_metadata_v2(account_id, key, value)
            VALUES (?, 'last_successful_sync_at', ?)
            ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value
            """,
          arguments: [accountID, timestamp]
        )
        try db.execute(
          sql: "DELETE FROM dayflow_sync_metadata_v2 WHERE account_id = ? AND key = 'last_sync_failure'",
          arguments: [accountID]
        )
      } else if state == .failed {
        try db.execute(
          sql: """
            INSERT INTO dayflow_sync_metadata_v2(account_id, key, value)
            VALUES (?, 'last_sync_failure', ?)
            ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value
            """,
          arguments: [accountID, String(boundedFailureCode ?? Substring("unknown"))]
        )
      }
    }
  }

  /// The relay cursor is account-scoped sync state, so keep it beside the
  /// encrypted event log. A cursor update is deliberately written only after
  /// the corresponding envelope batch has been merged successfully.
  func multiDeviceRelayCursor() throws -> String? {
    guard let accountID = DayflowMultiDeviceAccountScope.current else {
      throw DayflowLocalSyncStoreError.missingAccount
    }
    return try timedRead("read_multi_device_relay_cursor") { db in
      try String.fetchOne(
        db,
        sql: "SELECT value FROM dayflow_sync_metadata_v2 WHERE account_id = ? AND key = 'relay_cursor'",
        arguments: [accountID]
      )
    }
  }

  func setMultiDeviceRelayCursor(_ value: String) throws {
    guard let accountID = DayflowMultiDeviceAccountScope.current else {
      throw DayflowLocalSyncStoreError.missingAccount
    }
    guard value.isEmpty == false else {
      throw DayflowLocalSyncStoreError.databaseFailed("relay cursor cannot be empty")
    }
    try timedWrite("write_multi_device_relay_cursor") { db in
      try db.execute(
        sql: """
          INSERT INTO dayflow_sync_metadata_v2(account_id, key, value)
          VALUES (?, 'relay_cursor', ?)
          ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value
          """,
        arguments: [accountID, value]
      )
    }
  }

  /// Notification hints have a separate opaque cursor from encrypted event
  /// replay. A hint is advisory; advancing this cursor never advances event
  /// replay or changes the local projection.
  func multiDeviceNotificationCursor() throws -> String? {
    guard let accountID = DayflowMultiDeviceAccountScope.current else {
      throw DayflowLocalSyncStoreError.missingAccount
    }
    return try timedRead("read_multi_device_notification_cursor") { db in
      try String.fetchOne(
        db,
        sql: "SELECT value FROM dayflow_sync_metadata_v2 WHERE account_id = ? AND key = 'notification_cursor'",
        arguments: [accountID]
      )
    }
  }

  func setMultiDeviceNotificationCursor(_ value: String) throws {
    guard let accountID = DayflowMultiDeviceAccountScope.current else {
      throw DayflowLocalSyncStoreError.missingAccount
    }
    guard value.isEmpty == false else {
      throw DayflowLocalSyncStoreError.databaseFailed("notification cursor cannot be empty")
    }
    try timedWrite("write_multi_device_notification_cursor") { db in
      try db.execute(
        sql: """
          INSERT INTO dayflow_sync_metadata_v2(account_id, key, value)
          VALUES (?, 'notification_cursor', ?)
          ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value
          """,
        arguments: [accountID, value]
      )
    }
  }

  /// Allocate a device-local logical clock transactionally. The value is
  /// persisted before encryption so a crash cannot cause the next event to
  /// reuse an earlier clock.
  func ensureMultiDeviceLogicalClock(
    atLeast value: UInt64,
    accountScope: String? = nil
  ) throws {
    guard value <= DayflowEventEnvelope.maxLogicalClock else {
      throw DayflowLocalSyncStoreError.databaseFailed(
        "The local logical clock exceeds the JSON relay's safe integer range"
      )
    }
    let accountID = accountScope ?? DayflowMultiDeviceAccountScope.current
      ?? DayflowMultiDeviceAccountScope.localWorkspace
    try timedWrite("seed_multi_device_logical_clock") { db in
      let current = try Int64.fetchOne(
        db,
        sql: "SELECT value FROM dayflow_sync_metadata_v2 WHERE account_id = ? AND key = 'logical_clock'",
        arguments: [accountID]
      ) ?? 0
      guard current < Int64(clamping: value) else { return }
      try db.execute(
        sql: """
          INSERT INTO dayflow_sync_metadata_v2(account_id, key, value) VALUES (?, 'logical_clock', ?)
          ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value
          """,
        arguments: [accountID, String(value)]
      )
    }
  }

  func nextMultiDeviceLogicalClock(accountScope: String? = nil) -> UInt64? {
    let accountID = accountScope ?? DayflowMultiDeviceAccountScope.current
      ?? DayflowMultiDeviceAccountScope.localWorkspace
    do {
      return try timedWrite("next_multi_device_logical_clock") { db in
        let current = try Int64.fetchOne(
          db,
          sql: "SELECT value FROM dayflow_sync_metadata_v2 WHERE account_id = ? AND key = 'logical_clock'",
          arguments: [accountID]
        ) ?? 0
        guard current < Int64(DayflowEventEnvelope.maxLogicalClock) else { return nil }
        let next = current + 1
        try db.execute(
          sql: """
            INSERT INTO dayflow_sync_metadata_v2(account_id, key, value) VALUES (?, 'logical_clock', ?)
            ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value
            """,
          arguments: [accountID, String(next)]
        )
        return UInt64(next)
      }
    } catch {
      print("⚠️ [MultiDevice] Unable to allocate logical clock: \(error)")
      return nil
    }
  }

  func hasMultiDeviceMigrationRecord(stableID: String, version: Int) -> Bool {
    guard let accountID = DayflowMultiDeviceAccountScope.current else { return false }
    guard stableID.isEmpty == false else { return false }
    let count: Int = (try? timedRead("has_multi_device_migration_record") { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM dayflow_sync_migration_records_v2
          WHERE account_id = ? AND stable_id = ? AND migration_version = ?
          """,
        arguments: [accountID, stableID, version]
      ) ?? 0
    }) ?? 0
    return count > 0
  }

  @discardableResult
  func recordMultiDeviceMigration(
    stableID: String,
    eventID: String,
    sourceKind: String,
    sourceDay: String,
    sourceRecordID: String?,
    version: Int
  ) -> Bool {
    guard let accountID = DayflowMultiDeviceAccountScope.current else { return false }
    do {
      try timedWrite("record_multi_device_migration") { db in
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO dayflow_sync_migration_records_v2
              (account_id, stable_id, event_id, source_kind, source_day, source_record_id, migration_version)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [accountID, stableID, eventID, sourceKind, sourceDay, sourceRecordID, version]
        )
      }
      return true
    } catch {
      print("⚠️ [MultiDevice] Unable to record migration marker: \(error)")
      return false
    }
  }

  func multiDeviceMigrationCount(version: Int) -> Int {
    guard let accountID = DayflowMultiDeviceAccountScope.current else { return 0 }
    return (try? timedRead("multi_device_migration_count") { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM dayflow_sync_migration_records_v2 WHERE account_id = ? AND migration_version = ?",
        arguments: [accountID, version]
      ) ?? 0
    }) ?? 0
  }

  func localWorkspaceLinkedAccountID() -> String? {
    (try? timedRead("read_local_workspace_link") { db in
      try String.fetchOne(
        db,
        sql: "SELECT value FROM dayflow_sync_metadata_v2 WHERE account_id = ? AND key = 'linked_account_id'",
        arguments: [DayflowMultiDeviceAccountScope.localWorkspace]
      )
    }) ?? nil
  }

  func setLocalWorkspaceLinkedAccountID(_ accountID: String) throws {
    let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.isEmpty == false else {
      throw DayflowLocalSyncStoreError.missingAccount
    }
    try timedWrite("write_local_workspace_link") { db in
      try db.execute(
        sql: """
          INSERT INTO dayflow_sync_metadata_v2(account_id, key, value)
          VALUES (?, 'linked_account_id', ?)
          ON CONFLICT(account_id, key) DO UPDATE SET value = excluded.value
          """,
        arguments: [DayflowMultiDeviceAccountScope.localWorkspace, normalized]
      )
    }
  }

  func multiDeviceTimelineDays(limit: Int = 10_000) -> [String] {
    let boundedLimit = max(1, min(limit, 100_000))
    return (try? timedRead("multi_device_timeline_days") { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT DISTINCT day FROM timeline_cards
          WHERE is_deleted = 0 AND day IS NOT NULL AND day != ''
          ORDER BY day DESC
          LIMIT ?
          """,
        arguments: [boundedLimit]
      )
    }) ?? []
  }
}
