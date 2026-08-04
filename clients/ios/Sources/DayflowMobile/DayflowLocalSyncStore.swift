import Foundation
import CryptoKit
import SQLite3

public enum DayflowMobileSyncHealthState: String, Codable, Equatable, Sendable {
    case unknown
    case synced
    case waitingForApproval = "waiting_for_approval"
    case failed
}

public struct DayflowMobileSyncHealth: Codable, Equatable, Sendable {
    public let lastSyncAt: Date?
    public let lastSuccessfulSyncAt: Date?
    public let state: DayflowMobileSyncHealthState
    public let failureCode: String?

    public init(
        lastSyncAt: Date? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        state: DayflowMobileSyncHealthState = .unknown,
        failureCode: String? = nil
    ) {
        self.lastSyncAt = lastSyncAt
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.state = state
        self.failureCode = failureCode
    }

    public static let initial = DayflowMobileSyncHealth()

    public func summary(pendingEventCount: Int, now: Date = Date()) -> String {
        var parts: [String] = []
        switch state {
        case .synced:
            let date = lastSuccessfulSyncAt ?? lastSyncAt
            parts.append(date.map { "Last synced \(Self.relativeTime(from: $0, to: now))" } ?? "Synced locally")
        case .waitingForApproval:
            parts.append("Waiting for device approval")
        case .failed:
            parts.append("Last sync failed")
        case .unknown:
            parts.append("Not synced yet")
        }
        if pendingEventCount > 0 {
            parts.append("\(pendingEventCount) encrypted event\(pendingEventCount == 1 ? "" : "s") queued")
        } else if state == .synced {
            parts.append("No events queued")
        }
        if state == .failed, let failureCode, failureCode.isEmpty == false {
            parts.append("Reason: \(failureCode.replacingOccurrences(of: "_", with: " "))")
        }
        return parts.joined(separator: " · ")
    }

    private static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case 0..<60: return "just now"
        case 60..<3_600: return "\(seconds / 60)m ago"
        case 3_600..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}

public enum DayflowMobileLocalSyncStoreError: Error, Equatable {
    case openFailed(String)
    case databaseFailed(String)
    case invalidEnvelope
    case invalidAccount
    case conflictingEnvelope(String)
}

/// Device-local SQLite storage for encrypted event envelopes.
/// The database never stores a plaintext event payload or derived projection:
/// `ciphertext` and `nonce` are the opaque values produced by the Rust core,
/// and projections are rebuilt in memory when needed.
public final class DayflowMobileLocalSyncStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL) throws {
        let databaseURL = url
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(handle)
            throw DayflowMobileLocalSyncStoreError.openFailed(message)
        }
        database = handle
        do {
            try execute("""
                PRAGMA journal_mode = WAL;
                CREATE TABLE IF NOT EXISTS event_envelopes (
                    event_id TEXT PRIMARY KEY NOT NULL,
                    device_id TEXT NOT NULL,
                    logical_clock INTEGER NOT NULL,
                    schema_version INTEGER NOT NULL,
                    key_version INTEGER NOT NULL,
                    nonce TEXT NOT NULL,
                    ciphertext TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('pending', 'acknowledged'))
                );
                CREATE INDEX IF NOT EXISTS idx_mobile_event_state ON event_envelopes(state, logical_clock);
                CREATE TABLE IF NOT EXISTS sync_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                DELETE FROM sync_metadata WHERE key = 'projection_json';
                """)
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    /// Opens the production database in an account-specific directory. A
    /// caller must provide the account explicitly; using one shared mobile
    /// database would allow a sign-out/sign-in transition to mix outbox and
    /// projection state between accounts.
    public convenience init(accountID: String, baseDirectory: URL? = nil) throws {
        guard accountID.isEmpty == false else {
            throw DayflowMobileLocalSyncStoreError.invalidAccount
        }
        try self.init(url: Self.defaultURL(accountID: accountID, baseDirectory: baseDirectory))
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func enqueue(_ envelope: DayflowEventEnvelope) throws {
        try validate(envelope)
        try withLock {
            // Capture, journal, and foreground sync may open separate store
            // instances. Keep immutable-ID preflight and INSERT atomic so a
            // racing envelope cannot pass the check and be silently
            // discarded by INSERT OR IGNORE.
            try executeUnlocked("BEGIN IMMEDIATE TRANSACTION")
            do {
                try rejectConflictingEnvelope(envelope)
                let statement = try prepare("""
                    INSERT OR IGNORE INTO event_envelopes
                    (event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext, state)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'pending')
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(envelope.eventID, to: statement, index: 1)
                try bind(envelope.deviceID, to: statement, index: 2)
                sqlite3_bind_int64(statement, 3, Int64(envelope.logicalClock))
                sqlite3_bind_int(statement, 4, Int32(envelope.schemaVersion))
                sqlite3_bind_int64(statement, 5, Int64(envelope.keyVersion))
                try bind(envelope.nonce, to: statement, index: 6)
                try bind(envelope.ciphertext, to: statement, index: 7)
                try step(statement)
                try executeUnlocked("COMMIT")
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    @discardableResult
    public func acknowledge(eventIDs: [String]) throws -> Int {
        guard eventIDs.isEmpty == false else { return 0 }
        return try withLock {
            let statement = try prepare("UPDATE event_envelopes SET state = 'acknowledged' WHERE event_id = ?")
            defer { sqlite3_finalize(statement) }
            var count = 0
            for eventID in eventIDs {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(eventID, to: statement, index: 1)
                try step(statement)
                count += Int(sqlite3_changes(database))
            }
            return count
        }
    }

    public func pending(limit: Int = 100) throws -> [DayflowEventEnvelope] {
        try query(
            """
            SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext
            FROM event_envelopes WHERE state = 'pending'
            ORDER BY logical_clock ASC, device_id ASC, event_id ASC LIMIT ?
            """,
            limit: limit
        )
    }

    public func pendingCount() throws -> Int {
        try withLock {
            let statement = try prepare("SELECT COUNT(*) FROM event_envelopes WHERE state = 'pending'")
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW else { throw databaseError() }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    @discardableResult
    public func merge(_ envelopes: [DayflowEventEnvelope]) throws -> Int {
        guard envelopes.isEmpty == false else { return 0 }
        return try withLock {
            try executeUnlocked("BEGIN IMMEDIATE TRANSACTION")
            do {
                let statement = try prepare("""
                    INSERT OR IGNORE INTO event_envelopes
                    (event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext, state)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'acknowledged')
                    """)
                defer { sqlite3_finalize(statement) }
                var inserted = 0
                for envelope in envelopes {
                    try validate(envelope)
                    try rejectConflictingEnvelope(envelope)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(envelope.eventID, to: statement, index: 1)
                    try bind(envelope.deviceID, to: statement, index: 2)
                    sqlite3_bind_int64(statement, 3, Int64(envelope.logicalClock))
                    sqlite3_bind_int(statement, 4, Int32(envelope.schemaVersion))
                    sqlite3_bind_int64(statement, 5, Int64(envelope.keyVersion))
                    try bind(envelope.nonce, to: statement, index: 6)
                    try bind(envelope.ciphertext, to: statement, index: 7)
                    try step(statement)
                    inserted += Int(sqlite3_changes(database))
                }
                // Keep the local Lamport clock ahead of every accepted remote
                // event. This belongs to the same transaction as the merge so
                // a conflicting batch cannot advance the clock by itself.
                if let maximumRemoteClock = envelopes.map(\.logicalClock).max() {
                    try ensureLogicalClockUnlocked(atLeast: maximumRemoteClock)
                }
                try executeUnlocked("COMMIT")
                return inserted
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    public func allEnvelopes() throws -> [DayflowEventEnvelope] {
        try query(
            """
            SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext
            FROM event_envelopes ORDER BY logical_clock ASC, device_id ASC, event_id ASC
            """
        )
    }

    public func envelope(eventID: String) throws -> DayflowEventEnvelope? {
        try withLock {
            let statement = try prepare("""
                SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext
                FROM event_envelopes WHERE event_id = ? LIMIT 1
                """)
            defer { sqlite3_finalize(statement) }
            try bind(eventID, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard
                let storedEventID = sqliteText(statement, column: 0),
                let deviceID = sqliteText(statement, column: 1),
                let nonce = sqliteText(statement, column: 5),
                let ciphertext = sqliteText(statement, column: 6)
            else { throw DayflowMobileLocalSyncStoreError.databaseFailed("event row is invalid") }
            return DayflowEventEnvelope(
                eventID: storedEventID,
                deviceID: deviceID,
                logicalClock: UInt64(clamping: sqlite3_column_int64(statement, 2)),
                schemaVersion: UInt16(clamping: sqlite3_column_int(statement, 3)),
                keyVersion: UInt32(clamping: sqlite3_column_int64(statement, 4)),
                nonce: nonce,
                ciphertext: ciphertext
            )
        }
    }

    public func cursor() throws -> String? {
        try metadataValue(for: "relay_cursor")
    }

    public func setCursor(_ value: String) throws {
        try setMetadata(value, for: "relay_cursor")
    }

    /// Notification hints use an independent opaque cursor. Advancing it
    /// never advances encrypted event replay.
    public func notificationCursor() throws -> String? {
        try metadataValue(for: "notification_cursor")
    }

    public func setNotificationCursor(_ value: String) throws {
        guard value.isEmpty == false else {
            throw DayflowMobileLocalSyncStoreError.databaseFailed("notification cursor cannot be empty")
        }
        try setMetadata(value, for: "notification_cursor")
    }

    public func linkedAccountID() throws -> String? {
        try metadataValue(for: "linked_account_id")
    }

    public func setLinkedAccountID(_ value: String) throws {
        guard value.isEmpty == false else {
            throw DayflowMobileLocalSyncStoreError.invalidAccount
        }
        try setMetadata(value, for: "linked_account_id")
    }

    public func syncHealth() throws -> DayflowMobileSyncHealth {
        let lastSyncAt = try metadataValue(for: "last_sync_at").flatMap { seconds in
            Double(seconds).map { Date(timeIntervalSince1970: $0) }
        }
        let lastSuccessfulSyncAt = try metadataValue(for: "last_successful_sync_at").flatMap { seconds in
            Double(seconds).map { Date(timeIntervalSince1970: $0) }
        }
        return DayflowMobileSyncHealth(
            lastSyncAt: lastSyncAt,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            state: DayflowMobileSyncHealthState(rawValue: try metadataValue(for: "last_sync_state") ?? "") ?? .unknown,
            failureCode: try metadataValue(for: "last_sync_failure")
        )
    }

    /// Persists only bounded sync metadata; event content and raw errors never
    /// enter this table.
    public func recordSyncHealth(
        _ state: DayflowMobileSyncHealthState,
        failureCode: String? = nil,
        at date: Date = Date()
    ) throws {
        let timestamp = String(Int64(date.timeIntervalSince1970))
        try withLock {
            try executeUnlocked("BEGIN IMMEDIATE TRANSACTION")
            do {
                try setMetadataUnlocked(timestamp, for: "last_sync_at")
                try setMetadataUnlocked(state.rawValue, for: "last_sync_state")
                switch state {
                case .synced:
                    try setMetadataUnlocked(timestamp, for: "last_successful_sync_at")
                    try deleteMetadataUnlocked(for: "last_sync_failure")
                case .failed:
                    try setMetadataUnlocked(boundedFailureCode(failureCode), for: "last_sync_failure")
                case .unknown, .waitingForApproval:
                    break
                }
                try executeUnlocked("COMMIT")
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    /// Seeds the destination workspace clock after local-workspace linking.
    /// The source and destination share one physical device identity, so a
    /// fresh destination clock must not reuse source logical-clock values.
    public func ensureLogicalClock(atLeast value: UInt64) throws {
        guard value <= DayflowEventEnvelope.maxLogicalClock else {
            throw DayflowMobileLocalSyncStoreError.databaseFailed(
                "The local logical clock exceeds the JSON relay's safe integer range"
            )
        }
        try withLock {
            try ensureLogicalClockUnlocked(atLeast: value)
        }
    }

    public func nextLogicalClock() throws -> UInt64 {
        try withLock {
            let read = try prepare("SELECT value FROM sync_metadata WHERE key = 'logical_clock'")
            defer { sqlite3_finalize(read) }
            let status = sqlite3_step(read)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw databaseError() }
            let current = status == SQLITE_ROW ? UInt64(sqlite3_column_int64(read, 0)) : 0
            guard current < DayflowEventEnvelope.maxLogicalClock else { throw DayflowMobileLocalSyncStoreError.databaseFailed("logical clock exhausted") }
            let next = current + 1
            let write = try prepare("INSERT INTO sync_metadata (key, value) VALUES ('logical_clock', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
            defer { sqlite3_finalize(write) }
            try bind(String(next), to: write, index: 1)
            try step(write)
            return next
        }
    }

    /// Caller must hold `lock` and may already be inside a SQLite transaction.
    private func ensureLogicalClockUnlocked(atLeast value: UInt64) throws {
        let read = try prepare("SELECT value FROM sync_metadata WHERE key = 'logical_clock'")
        defer { sqlite3_finalize(read) }
        let status = sqlite3_step(read)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw databaseError() }
        let current = status == SQLITE_ROW ? UInt64(clamping: sqlite3_column_int64(read, 0)) : 0
        guard current < value else { return }

        let write = try prepare("INSERT INTO sync_metadata (key, value) VALUES ('logical_clock', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        defer { sqlite3_finalize(write) }
        try bind(String(value), to: write, index: 1)
        try step(write)
    }

    private func query(_ sql: String, limit: Int? = nil) throws -> [DayflowEventEnvelope] {
        try withLock {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let limit {
                sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 1000))))
            }
            var result: [DayflowEventEnvelope] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw databaseError() }
                guard
                    let eventID = sqliteText(statement, column: 0),
                    let deviceID = sqliteText(statement, column: 1),
                    let nonce = sqliteText(statement, column: 5),
                    let ciphertext = sqliteText(statement, column: 6)
                else { throw DayflowMobileLocalSyncStoreError.databaseFailed("event row is invalid") }
                result.append(DayflowEventEnvelope(
                    eventID: eventID,
                    deviceID: deviceID,
                    logicalClock: UInt64(sqlite3_column_int64(statement, 2)),
                    schemaVersion: UInt16(sqlite3_column_int(statement, 3)),
                    keyVersion: UInt32(sqlite3_column_int64(statement, 4)),
                    nonce: nonce,
                    ciphertext: ciphertext
                ))
            }
            return result
        }
    }

    private func metadataValue(for key: String) throws -> String? {
        try withLock {
            let statement = try prepare("SELECT value FROM sync_metadata WHERE key = ?")
            defer { sqlite3_finalize(statement) }
            try bind(key, to: statement, index: 1)
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw databaseError() }
            return status == SQLITE_ROW ? sqliteText(statement, column: 0) : nil
        }
    }

    private func setMetadata(_ value: String, for key: String) throws {
        try withLock {
            try setMetadataUnlocked(value, for: key)
        }
    }

    private func setMetadataUnlocked(_ value: String, for key: String) throws {
        let statement = try prepare("""
            INSERT INTO sync_metadata (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """)
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, index: 1)
        try bind(value, to: statement, index: 2)
        try step(statement)
    }

    private func deleteMetadataUnlocked(for key: String) throws {
        let statement = try prepare("DELETE FROM sync_metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, index: 1)
        try step(statement)
    }

    private func boundedFailureCode(_ value: String?) -> String {
        let normalized = value?.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(48)
        let result = normalized.map(String.init) ?? ""
        return result.isEmpty ? "unknown" : result
    }

    private func validate(_ envelope: DayflowEventEnvelope) throws {
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
        else { throw DayflowMobileLocalSyncStoreError.invalidEnvelope }
    }

    /// Event IDs are immutable identities. Exact re-delivery is harmless, but
    /// a different envelope for an existing ID is a protocol conflict and must
    /// never be silently discarded by SQLite's conflict-ignore behavior.
    private func rejectConflictingEnvelope(_ envelope: DayflowEventEnvelope) throws {
        let statement = try prepare("""
            SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext
            FROM event_envelopes WHERE event_id = ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind(envelope.eventID, to: statement, index: 1)
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw databaseError() }
        guard status == SQLITE_ROW else { return }
        guard
            let eventID = sqliteText(statement, column: 0),
            let deviceID = sqliteText(statement, column: 1),
            let nonce = sqliteText(statement, column: 5),
            let ciphertext = sqliteText(statement, column: 6)
        else { throw DayflowMobileLocalSyncStoreError.databaseFailed("event row is invalid") }

        let existing = DayflowEventEnvelope(
            eventID: eventID,
            deviceID: deviceID,
            logicalClock: UInt64(clamping: sqlite3_column_int64(statement, 2)),
            schemaVersion: UInt16(clamping: sqlite3_column_int(statement, 3)),
            keyVersion: UInt32(clamping: sqlite3_column_int64(statement, 4)),
            nonce: nonce,
            ciphertext: ciphertext
        )
        guard existing == envelope else {
            throw DayflowMobileLocalSyncStoreError.conflictingEnvelope(envelope.eventID)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func execute(_ sql: String) throws {
        try withLock {
            try executeUnlocked(sql)
        }
    }

    private func executeUnlocked(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? databaseErrorMessage()
            sqlite3_free(errorPointer)
            throw DayflowMobileLocalSyncStoreError.databaseFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw databaseError() }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func sqliteText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func databaseError() -> DayflowMobileLocalSyncStoreError {
        .databaseFailed(databaseErrorMessage())
    }

    private func databaseErrorMessage() -> String {
        guard let database else { return "SQLite database is unavailable" }
        return String(cString: sqlite3_errmsg(database))
    }

    private static func defaultURL(accountID: String, baseDirectory: URL?) throws -> URL {
        let support: URL
        if let baseDirectory {
            support = baseDirectory
        } else if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            support = applicationSupport
        } else {
            throw DayflowMobileLocalSyncStoreError.openFailed("application support directory is unavailable")
        }
        let digest = SHA256.hash(data: Data(accountID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return support.appendingPathComponent("Dayflow/Mobile/dayflow-sync-\(digest).sqlite")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
