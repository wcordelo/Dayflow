import XCTest
import Foundation
import SQLite3
@testable import DayflowMobile
#if canImport(DayflowCoreBindings)
import DayflowCoreBindings
#endif

final class DayflowMobileTests: XCTestCase {
    private static let validNonce = String(repeating: "A", count: 32)
    private static let validCiphertext = String(repeating: "A", count: 24)

    func testSharedCapturePauseParsingFailsClosed() {
        XCTAssertFalse(ActivityCaptureSession.sharedCapturePauseEnabled(nil))
        XCTAssertFalse(ActivityCaptureSession.sharedCapturePauseEnabled(" false "))
        XCTAssertTrue(ActivityCaptureSession.sharedCapturePauseEnabled("TRUE"))
        XCTAssertTrue(ActivityCaptureSession.sharedCapturePauseEnabled("unexpected"))
    }

    func testSharedSettingContractRejectsMalformedDatedKeys() {
        XCTAssertTrue(DayflowMobileSharedSettingContract.isAllowedKey("day_goal:2026-02-28"))
        XCTAssertTrue(DayflowMobileSharedSettingContract.isAllowedKey("daily_standup:2026-08-01"))
        XCTAssertFalse(DayflowMobileSharedSettingContract.isAllowedKey("day_goal:2026-02-29"))
        XCTAssertFalse(DayflowMobileSharedSettingContract.isAllowedKey("daily_standup:not-a-date"))
        XCTAssertFalse(DayflowMobileSharedSettingContract.isAllowedKey("dayflow.provider.api_key"))
    }

    @MainActor
    func testNativeStatusFieldsKeepCaptureAndDerivedSyncStateExplicit() {
        let session = ActivityCaptureSession()
        let fields = session.statusFields(
            sharedCapturePaused: true,
            derivedSync: ""
        )

        XCTAssertEqual(fields.capturePermission, "not_active")
        XCTAssertEqual(fields.captureSession, "idle")
        XCTAssertEqual(fields.capturePaused, "paused")
        XCTAssertEqual(fields.derivedSync, "unknown")
        XCTAssertEqual(
            fields.asDictionary()[DayflowNativeStatusKey.capturePermission],
            "not_active"
        )
    }

    func testOpaqueCursorEncodingDoesNotAllowQuerySeparators() {
        XCTAssertEqual(
            DayflowMobileHTTP.encodedQueryComponent("cursor&next=2/%value"),
            "cursor%26next%3D2%2F%25value"
        )
    }

    func testNotificationHintsDecodeAndPersistAnIndependentCursor() throws {
        let response = try JSONDecoder().decode(
            DayflowMobileRelayNotificationHintsResponse.self,
            from: Data("""
            {"cursor":"notification-cursor-2","hints":[{"sequence":7,"kind":"sync_available"}]}
            """.utf8)
        )
        XCTAssertEqual(response.cursor, "notification-cursor-2")
        XCTAssertEqual(response.hints, [
            DayflowMobileRelayNotificationHint(sequence: 7, kind: "sync_available"),
        ])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-notification-cursor-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try DayflowMobileLocalSyncStore(url: url)
        XCTAssertNil(try store.notificationCursor())
        try store.setNotificationCursor(response.cursor)
        XCTAssertEqual(try store.notificationCursor(), response.cursor)
        XCTAssertNil(try store.cursor())
    }

    func testRemoteNotificationWakeRequiresAnExactSilentPayload() {
        XCTAssertTrue(
            DayflowMobilePushWakeContract.accepts([
                "aps": ["content-available": 1],
                "kind": DayflowMobilePushWakeContract.syncAvailable,
            ])
        )
        XCTAssertFalse(
            DayflowMobilePushWakeContract.accepts([
                "aps": ["content-available": 1],
                "kind": DayflowMobilePushWakeContract.syncAvailable,
                "journal": "private text",
            ])
        )
        XCTAssertFalse(
            DayflowMobilePushWakeContract.accepts([
                "aps": ["alert": ["body": "private text"]],
                "kind": DayflowMobilePushWakeContract.syncAvailable,
            ])
        )
        XCTAssertFalse(
            DayflowMobilePushWakeContract.accepts([
                "aps": ["content-available": true],
                "kind": DayflowMobilePushWakeContract.syncAvailable,
            ])
        )
    }

    func testEnvelopeUsesRustWireKeys() throws {
        let envelope = DayflowEventEnvelope(
            eventID: "event-1",
            deviceID: "ios-1",
            logicalClock: 1,
            schemaVersion: 1,
            keyVersion: 1,
            nonce: "bm9uY2U",
            ciphertext: "Y2lwaGVydGV4dA"
        )
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["event_id"] as? String, "event-1")
        XCTAssertNil(json["eventID"])
    }

    func testEnvelopeShapeMatchesTheRustWireContract() {
        XCTAssertTrue(
            DayflowWireEnvelopeValidation.hasValidEncryptedFieldShape(
                nonce: Self.validNonce,
                ciphertext: Self.validCiphertext
            )
        )
        XCTAssertTrue(
            DayflowWireEnvelopeValidation.hasValidEncryptedFieldShape(
                nonce: String(repeating: "_", count: 31) + "-",
                ciphertext: String(repeating: "_", count: 21) + "w"
            )
        )
        XCTAssertFalse(
            DayflowWireEnvelopeValidation.hasValidEncryptedFieldShape(
                nonce: "bm9uY2U",
                ciphertext: "Y2lwaGVydGV4dA"
            )
        )
    }

    func testLocalSQLiteRejectsUnsupportedEnvelopeMetadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-invalid-envelope-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try DayflowMobileLocalSyncStore(url: url)
        let valid = DayflowEventEnvelope(
            eventID: "valid-event",
            deviceID: "ios-1",
            logicalClock: 1,
            schemaVersion: DayflowEventEnvelope.currentSchemaVersion,
            keyVersion: 1,
            nonce: "bm9uY2U",
            ciphertext: "Y2lwaGVydGV4dA"
        )
        let invalidEnvelopes = [
            DayflowEventEnvelope(
                eventID: "unsupported-schema",
                deviceID: valid.deviceID,
                logicalClock: valid.logicalClock,
                schemaVersion: 2,
                keyVersion: valid.keyVersion,
                nonce: valid.nonce,
                ciphertext: valid.ciphertext
            ),
            DayflowEventEnvelope(
                eventID: "missing-key-version",
                deviceID: valid.deviceID,
                logicalClock: valid.logicalClock,
                schemaVersion: valid.schemaVersion,
                keyVersion: 0,
                nonce: valid.nonce,
                ciphertext: valid.ciphertext
            ),
            DayflowEventEnvelope(
                eventID: "sqlite-clock-overflow",
                deviceID: valid.deviceID,
                logicalClock: UInt64.max,
                schemaVersion: valid.schemaVersion,
                keyVersion: valid.keyVersion,
                nonce: valid.nonce,
                ciphertext: valid.ciphertext
            ),
        ]

        for envelope in invalidEnvelopes {
            XCTAssertThrowsError(try store.enqueue(envelope)) { error in
                XCTAssertEqual(error as? DayflowMobileLocalSyncStoreError, .invalidEnvelope)
            }
        }
        XCTAssertTrue(try store.allEnvelopes().isEmpty)
    }

    func testUnavailableCoreDoesNotPretendToProject() {
        let bridge = UnavailableDayflowCoreBridge()
        XCTAssertThrowsError(try bridge.project(envelopes: [], accountRootKey: Data(repeating: 0, count: 32))) { error in
            XCTAssertEqual(error as? DayflowCoreBridgeError, .unavailable)
        }
    }

    #if canImport(DayflowCoreBindings)
    func testGeneratedRustBridgeProjectsEmptyEventLog() throws {
        let bridge = UniFFIDayflowCoreBridge()
        let projection = try bridge.project(
            envelopes: [],
            accountRootKey: Data(repeating: 7, count: 32)
        )
        XCTAssertTrue(projection.contains("timeline_cards"))
        XCTAssertTrue(projection.contains("journal_entries"))
    }

    func testGeneratedRustBridgeUsesTheFourAmLogicalDay() throws {
        let bridge = UniFFIDayflowCoreBridge()
        XCTAssertEqual(
            try bridge.logicalDayKey(timestampUnix: 14_399, timezoneOffsetMinutes: 0, boundaryHour: 4),
            "1969-12-31"
        )
        XCTAssertEqual(
            try bridge.logicalDayKey(timestampUnix: 14_400, timezoneOffsetMinutes: 0, boundaryHour: 4),
            "1970-01-01"
        )
    }

    func testGeneratedRustBridgeMatchesCanonicalRequestVector() throws {
        let bridge = UniFFIDayflowCoreBridge()
        XCTAssertEqual(
            try bridge.canonicalDeviceRequest(
                method: "post",
                pathWithQuery: "/v1/sync/events?cursor=abc",
                body: Data(#"{"hello":"opaque"}"#.utf8),
                timestamp: 1_723_456_789,
                nonce: "0123456789abcdef0123456789abcdef",
                deviceID: "mac-device"
            ),
            "dayflow:v1:1723456789:POST:/v1/sync/events?cursor=abc:b7e6d00fedcbdee445a53f6b804273eeb7a62879a6891f7bdc4f9b238675a4f4:0123456789abcdef0123456789abcdef:mac-device"
        )
    }

    func testProjectionDecodesLocalChatContext() throws {
        let projection = try JSONDecoder().decode(
            DayflowMobileProjection.self,
            from: Data("""
            {"timeline_cards":{},"journal_entries":{},"priorities":{"priority-1":{"id":"priority-1","day":"2026-08-01","rank":1,"text":"Ship sync","status":"open"}},"reflections":{"reflection-1":{"id":"reflection-1","day":"2026-08-01","body":"The replay is deterministic"}},"settings":{"dayflow.theme":"dark"},"chat_context":[{"id":"journal-1","kind":"journal","day":"2026-08-01","content":"Ship sync"}]}
            """.utf8)
        )
        XCTAssertEqual(projection.chatContext.first?.content, "Ship sync")
        XCTAssertEqual(projection.priorities["priority-1"]?.text, "Ship sync")
        XCTAssertEqual(projection.reflections["reflection-1"]?.body, "The replay is deterministic")
        XCTAssertEqual(projection.settings["dayflow.theme"], "dark")
    }

    func testProjectionRetainsCompleteTimelineCardReadModel() throws {
        let projection = try JSONDecoder().decode(
            DayflowMobileProjection.self,
            from: Data("""
            {"timeline_cards":{"card-1":{"id":"card-1","day":"2026-08-01","start_timestamp":1,"end_timestamp":2,"title":"Build","summary":"Shared core","category":"focus","subcategory":"engineering","detailed_summary":"Replayed locally","source":"windows_graphics_capture","derivation_mode":"privacy_gated_foreground_metadata"}},"journal_entries":{},"priorities":{},"reflections":{},"settings":{},"chat_context":[]}
            """.utf8)
        )
        let card = try XCTUnwrap(projection.timelineCards["card-1"])
        XCTAssertEqual(card.subcategory, "engineering")
        XCTAssertEqual(card.detailedSummary, "Replayed locally")
        XCTAssertEqual(card.source, "windows_graphics_capture")
        XCTAssertEqual(card.derivationMode, "privacy_gated_foreground_metadata")
    }

    func testGeneratedRustBridgeWrapsAndUnwrapsAccountKey() throws {
        let bridge = UniFFIDayflowCoreBridge()
        let privateKey = generateDevicePrivateKey()
        let publicKey = try devicePublicKey(privateKey: privateKey)
        let rootKey = Data(repeating: 9, count: 32)
        let wrapped = try bridge.wrapAccountKey(
            accountRootKey: rootKey,
            recipientDeviceID: "ios-1",
            recipientPublicKey: publicKey
        )
        let restored = try bridge.unwrapAccountKey(wrappedKey: wrapped, privateKey: privateKey)
        XCTAssertEqual(restored, rootKey)
    }

    func testGeneratedRustBridgeRecoveryKitRetainsKeyVersionsAndRejectsWrongPassphrase() throws {
        let bridge = UniFFIDayflowCoreBridge()
        var keyRing = try DayflowMobileAccountKeyRing(rootKey: Data(repeating: 7, count: 32))
        keyRing = try keyRing.adding(Data(repeating: 9, count: 32), version: 2, active: true)

        let kit = try bridge.exportRecoveryKit(keyRing: keyRing, passphrase: "correct horse battery")
        let restored = try bridge.restoreRecoveryKeyRing(kit: kit, passphrase: "correct horse battery")

        XCTAssertEqual(restored, keyRing)
        XCTAssertEqual(restored.activeKeyVersion, 2)
        XCTAssertEqual(restored.keyData(for: 1), Data(repeating: 7, count: 32))
        XCTAssertEqual(restored.keyData(for: 2), Data(repeating: 9, count: 32))
        XCTAssertThrowsError(try bridge.restoreRecoveryKeyRing(kit: kit, passphrase: "wrong passphrase"))
    }

    func testLocalSQLiteOutboxRejectsConflictingEventEnvelope() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-conflict-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try DayflowMobileLocalSyncStore(url: url)
        let original = DayflowEventEnvelope(
            eventID: "event-conflict",
            deviceID: "ios-1",
            logicalClock: 1,
            schemaVersion: 1,
            keyVersion: 1,
            nonce: Self.validNonce,
            ciphertext: Self.validCiphertext
        )
        var conflicting = original
        conflicting = DayflowEventEnvelope(
            eventID: original.eventID,
            deviceID: original.deviceID,
            logicalClock: original.logicalClock,
            schemaVersion: original.schemaVersion,
            keyVersion: original.keyVersion,
            nonce: original.nonce,
            ciphertext: String(Self.validCiphertext.dropLast()) + "B"
        )

        try store.enqueue(original)
        XCTAssertEqual(try store.envelope(eventID: original.eventID), original)
        XCTAssertNil(try store.envelope(eventID: "missing-event"))
        XCTAssertThrowsError(try store.enqueue(conflicting)) { error in
            XCTAssertEqual(
                error as? DayflowMobileLocalSyncStoreError,
                .conflictingEnvelope(original.eventID)
            )
        }
        XCTAssertEqual(try store.allEnvelopes(), [original])
    }

    func testLocalSQLiteEnqueueConflictRollsBackTheAtomicWrite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-atomic-enqueue-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try DayflowMobileLocalSyncStore(url: url)
        let original = DayflowEventEnvelope(
            eventID: "event-atomic-enqueue",
            deviceID: "ios-1",
            logicalClock: 1,
            schemaVersion: 1,
            keyVersion: 1,
            nonce: Self.validNonce,
            ciphertext: Self.validCiphertext
        )
        let newEvent = DayflowEventEnvelope(
            eventID: "event-after-conflict",
            deviceID: "ios-1",
            logicalClock: 2,
            schemaVersion: 1,
            keyVersion: 1,
            nonce: Self.validNonce,
            ciphertext: Self.validCiphertext
        )
        let conflicting = DayflowEventEnvelope(
            eventID: original.eventID,
            deviceID: original.deviceID,
            logicalClock: original.logicalClock,
            schemaVersion: original.schemaVersion,
            keyVersion: original.keyVersion,
            nonce: original.nonce,
            ciphertext: String(Self.validCiphertext.dropLast()) + "B"
        )

        try store.enqueue(original)
        XCTAssertThrowsError(try store.enqueue(conflicting)) { error in
            XCTAssertEqual(
                error as? DayflowMobileLocalSyncStoreError,
                .conflictingEnvelope(original.eventID)
            )
        }
        XCTAssertNil(try store.envelope(eventID: newEvent.eventID))
        XCTAssertEqual(try store.allEnvelopes(), [original])

        try store.enqueue(newEvent)
        XCTAssertEqual(try store.allEnvelopes(), [original, newEvent])
    }

    func testLocalSQLiteMergeRejectsConflictingBatchAtomically() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-conflicting-batch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try DayflowMobileLocalSyncStore(url: url)
        let original = DayflowEventEnvelope(
            eventID: "event-conflict-batch",
            deviceID: "ios-1",
            logicalClock: 1,
            schemaVersion: 1,
            keyVersion: 1,
            nonce: Self.validNonce,
            ciphertext: Self.validCiphertext
        )
        let newEvent = DayflowEventEnvelope(
            eventID: "event-before-conflict",
            deviceID: "ios-2",
            logicalClock: 2,
            schemaVersion: 1,
            keyVersion: 1,
            nonce: Self.validNonce,
            ciphertext: Self.validCiphertext
        )
        let conflicting = DayflowEventEnvelope(
            eventID: original.eventID,
            deviceID: original.deviceID,
            logicalClock: original.logicalClock,
            schemaVersion: original.schemaVersion,
            keyVersion: original.keyVersion,
            nonce: original.nonce,
            ciphertext: String(Self.validCiphertext.dropLast()) + "B"
        )

        try store.enqueue(original)
        XCTAssertThrowsError(try store.merge([newEvent, conflicting])) { error in
            XCTAssertEqual(error as? DayflowMobileLocalSyncStoreError, .conflictingEnvelope(original.eventID))
        }
        XCTAssertEqual(try store.allEnvelopes(), [original])
    }

    func testGeneratedRustBridgeReplaysHistoricalKeyVersions() throws {
        let bridge = UniFFIDayflowCoreBridge()
        let firstKey = Data(repeating: 7, count: 32)
        let secondKey = Data(repeating: 8, count: 32)
        let keyRing = try DayflowMobileAccountKeyRing(
            activeKeyVersion: 2,
            keyData: [1: firstKey, 2: secondKey]
        )
        let firstPayload = try JSONSerialization.data(withJSONObject: [
            "kind": "JournalUpsert",
            "value": ["id": "journal-v1", "day": "2026-08-01", "body": "before rotation"],
        ], options: [.sortedKeys])
        let secondPayload = try JSONSerialization.data(withJSONObject: [
            "kind": "JournalUpsert",
            "value": ["id": "journal-v2", "day": "2026-08-01", "body": "after rotation"],
        ], options: [.sortedKeys])
        let first = try bridge.seal(
            payload: firstPayload,
            eventID: "journal-v1",
            deviceID: "ios-1",
            logicalClock: 1,
            keyVersion: 1,
            accountRootKey: firstKey
        )
        let second = try bridge.seal(
            payload: secondPayload,
            eventID: "journal-v2",
            deviceID: "ios-1",
            logicalClock: 2,
            keyVersion: 2,
            accountRootKey: secondKey
        )
        XCTAssertEqual(first.keyVersion, 1)
        XCTAssertEqual(second.keyVersion, 2)
        let projection = try bridge.project(envelopes: [first, second], keyRing: keyRing)
        XCTAssertTrue(projection.contains("before rotation"))
        XCTAssertTrue(projection.contains("after rotation"))
    }

    func testGeneratedRustBridgeSignsARequest() throws {
        let bridge = UniFFIDayflowCoreBridge()
        let privateKey = generateDeviceSigningPrivateKey()
        let signature = try bridge.signRequest(
            message: "dayflow:v1:1:GET:/v1/sync/events::nonce:ios-1",
            privateKey: privateKey
        )
        XCTAssertEqual(signature.count, 64)
    }

    func testGeneratedRustBridgeAppliesApplicationPrivacyPolicy() throws {
        let context = """
        {"permission_granted":true,"user_paused":false,"device_locked":false,"sleeping":false,"private_context":false,"drm_content":false,"application_id":"com.example.bank","window_title":"Password reset"}
        """
        let policy = """
        {"ignore_private_context":true,"pause_on_drm":true,"blocked_application_ids":["com.example.bank"],"blocked_window_title_fragments":["password"]}
        """
        let decision = try UniFFIDayflowCoreBridge().captureDecision(
            contextJSON: context,
            policyJSON: policy
        )
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "blocked_application")
    }

    func testLocalSQLiteOutboxStoresOpaqueEnvelopesAndCursorWithoutProjectionCache() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try DayflowMobileLocalSyncStore(url: url)
        XCTAssertEqual(try store.nextLogicalClock(), 1)
        XCTAssertEqual(try store.nextLogicalClock(), 2)
        let envelope = DayflowEventEnvelope(
            eventID: "event-1",
            deviceID: "ios-1",
            logicalClock: 1,
            schemaVersion: 1,
            keyVersion: 1,
            nonce: Self.validNonce,
            ciphertext: Self.validCiphertext
        )
        try store.enqueue(envelope)
        XCTAssertEqual(try store.pending(), [envelope])
        XCTAssertEqual(try store.pendingCount(), 1)
        XCTAssertEqual(try store.acknowledge(eventIDs: [envelope.eventID]), 1)
        XCTAssertEqual(try store.pending(), [])
        XCTAssertEqual(try store.pendingCount(), 0)
        try store.setCursor("cursor-1")
        XCTAssertEqual(try store.cursor(), "cursor-1")
    }

    func testLocalSQLiteSyncHealthPersistsBoundedStateAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-sync-health-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = try DayflowMobileLocalSyncStore(url: url)
            try store.recordSyncHealth(
                .failed,
                failureCode: "Relay response included user journal text!",
                at: Date(timeIntervalSince1970: 100)
            )
            let health = try store.syncHealth()
            XCTAssertEqual(health.state, .failed)
            XCTAssertEqual(health.failureCode, "relayresponseincludeduserjournaltext")
            XCTAssertNil(health.lastSuccessfulSyncAt)
        }

        do {
            let store = try DayflowMobileLocalSyncStore(url: url)
            try store.recordSyncHealth(.synced, at: Date(timeIntervalSince1970: 200))
            let health = try store.syncHealth()
            XCTAssertEqual(health.state, .synced)
            XCTAssertEqual(health.lastSyncAt, Date(timeIntervalSince1970: 200))
            XCTAssertEqual(health.lastSuccessfulSyncAt, Date(timeIntervalSince1970: 200))
            XCTAssertNil(health.failureCode)
        }
    }

    func testLocalSQLiteClockSeedPreventsReuseAfterWorkspaceLink() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-clock-seed-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try DayflowMobileLocalSyncStore(url: url)
        XCTAssertEqual(try store.nextLogicalClock(), 1)
        XCTAssertEqual(try store.nextLogicalClock(), 2)
        try store.ensureLogicalClock(atLeast: 9)
        XCTAssertEqual(try store.nextLogicalClock(), 10)
        try store.ensureLogicalClock(atLeast: 4)
        XCTAssertEqual(try store.nextLogicalClock(), 11)
    }

    func testLocalSQLiteMergeAdvancesClockBeforeTheNextLocalEvent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-remote-clock-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try DayflowMobileLocalSyncStore(url: url)
        let remote = DayflowEventEnvelope(
            eventID: "remote-clock-17",
            deviceID: "android-clock-test",
            logicalClock: 17,
            schemaVersion: 1,
            keyVersion: 1,
            nonce: Self.validNonce,
            ciphertext: Self.validCiphertext
        )
        XCTAssertEqual(try store.merge([remote]), 1)
        XCTAssertEqual(try store.nextLogicalClock(), 18)

        let later = DayflowEventEnvelope(
            eventID: "remote-clock-25",
            deviceID: "windows-clock-test",
            logicalClock: 25,
            schemaVersion: 1,
            keyVersion: 1,
            nonce: Self.validNonce,
            ciphertext: Self.validCiphertext
        )
        XCTAssertEqual(try store.merge([later]), 1)
        XCTAssertEqual(try store.nextLogicalClock(), 26)
    }

    func testLocalSQLiteStoreRemovesLegacyProjectionCacheOnOpen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-legacy-cache-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE sync_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL); INSERT INTO sync_metadata(key, value) VALUES ('projection_json', '{\\\"journal_entries\\\":{}}');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(database)
        database = nil

        _ = try DayflowMobileLocalSyncStore(url: url)

        XCTAssertEqual(
            sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK
        )
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "SELECT value FROM sync_metadata WHERE key = 'projection_json'",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func testProductionStoreUsesSeparateDatabasePerAccount() throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayflow-mobile-accounts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let envelope = DayflowEventEnvelope(
            eventID: "account-a-event",
            deviceID: "ios-a",
            logicalClock: 1,
            schemaVersion: 1,
            keyVersion: 1,
            nonce: Self.validNonce,
            ciphertext: Self.validCiphertext
        )

        do {
            let first = try DayflowMobileLocalSyncStore(
                accountID: "account-a",
                baseDirectory: baseDirectory
            )
            let second = try DayflowMobileLocalSyncStore(
                accountID: "account-b",
                baseDirectory: baseDirectory
            )
            try first.enqueue(envelope)
            XCTAssertEqual(try first.pending(), [envelope])
            XCTAssertEqual(try second.pending(), [])
            XCTAssertEqual(try first.nextLogicalClock(), 1)
            XCTAssertEqual(try second.nextLogicalClock(), 1)
        }
    }

    func testAIProviderConfigurationKeepsSecretOutOfRouteDocument() throws {
        let configuration = DayflowAIProviderConfiguration(
            providerID: DayflowAIProviderIds.gemini,
            endpoint: "https://generativelanguage.googleapis.com",
            modelID: "gemini-3.5-flash"
        )
        XCTAssertTrue(configuration.isConfigured)
        XCTAssertTrue(configuration.requiresAPIKey)
        let data = try JSONEncoder().encode(configuration)
        let document = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(document.contains("secret"))
        XCTAssertFalse(document.contains("api_key"))
    }

    func testAIProviderRejectsRemoteHTTPButAllowsLoopbackHTTP() {
        let remote = DayflowAIProviderConfiguration(
            providerID: DayflowAIProviderIds.gemini,
            endpoint: "http://sync.example.com",
            modelID: "gemini-3.5-flash"
        )
        let local = DayflowAIProviderConfiguration(
            providerID: DayflowAIProviderIds.local,
            endpoint: "http://127.0.0.1:11434",
            modelID: "llama"
        )

        XCTAssertFalse(remote.isConfigured)
        XCTAssertTrue(local.isConfigured)
    }

    func testEndpointPolicyRejectsCredentialsQueriesAndFragments() {
        let cases = [
            "https://user:pass@example.com",
            "https://example.com?token=secret",
            "https://example.com/path#fragment",
        ]

        for value in cases {
            guard let endpoint = URL(string: value) else {
                XCTFail("The endpoint fixture should parse: \(value)")
                continue
            }
            XCTAssertFalse(DayflowMobileHTTP.isAllowedEndpoint(endpoint))
        }

        XCTAssertTrue(
            DayflowMobileHTTP.isAllowedEndpoint(
                try! XCTUnwrap(URL(string: "https://api.dayflow.so"))
            )
        )
    }

    func testSyncRelayRejectsRemoteHTTP() async {
        let endpoint = try! XCTUnwrap(URL(string: "http://sync.example.com"))
        let client = DayflowMobileSyncRelayClient(baseURL: endpoint)

        do {
            _ = try await client.listDevices(token: "test-token")
            XCTFail("Remote HTTP must never be used for the encrypted relay.")
        } catch let error as DayflowMobileSyncError {
            XCTAssertEqual(error, .invalidEndpoint)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChatPromptIsBoundedAndIncludesOnlyProjectionContext() {
        let context = (0..<100).map { index in
            DayflowMobileChatContextItem(
                id: "item-\(index)",
                kind: "journal",
                day: "2026-08-01",
                content: String(repeating: "context ", count: 1000)
            )
        }
        let prompt = DayflowMobileAIChatClient.prompt(question: "What should I do next?", context: context)
        XCTAssertLessThanOrEqual(prompt.count, 13_000)
        XCTAssertTrue(prompt.contains("What should I do next?"))
        XCTAssertTrue(prompt.contains("Local Dayflow context:"))
    }
    #endif
}
