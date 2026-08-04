import XCTest
import GRDB
@testable import Dayflow

final class DayflowMultiDeviceTests: XCTestCase {
  func testSharedCapturePauseParsingFailsClosed() {
    XCTAssertFalse(DayflowSharedCapturePause.isPaused(nil))
    XCTAssertFalse(DayflowSharedCapturePause.isPaused(" false "))
    XCTAssertTrue(DayflowSharedCapturePause.isPaused("TRUE"))
    XCTAssertTrue(DayflowSharedCapturePause.isPaused("unexpected"))
  }

  func testMacStatusFieldsExposeTheNativeStatusContract() {
    let fields = DayflowMacStatusFields(
      capturePermission: "granted",
      captureSession: "running",
      capturePaused: "not_paused",
      derivedSync: "Last synced just now"
    )

    XCTAssertEqual(fields.asDictionary[DayflowMacStatusFields.capturePermissionKey], "granted")
    XCTAssertEqual(fields.asDictionary[DayflowMacStatusFields.captureSessionKey], "running")
    XCTAssertEqual(fields.asDictionary[DayflowMacStatusFields.capturePausedKey], "not_paused")
    XCTAssertEqual(fields.asDictionary[DayflowMacStatusFields.derivedSyncKey], "Last synced just now")
  }

  func testEnvelopeShapeMatchesRustWireContract() {
    XCTAssertTrue(
      DayflowWireEnvelopeValidation.hasValidEncryptedFieldShape(
        nonce: String(repeating: "A", count: 32),
        ciphertext: String(repeating: "A", count: 24)
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

  func testEventEnvelopeUsesRustWireKeys() throws {
    let envelope = DayflowEventEnvelope(
      eventID: "event-1",
      deviceID: "mac",
      logicalClock: 7,
      schemaVersion: 1,
      keyVersion: 1,
      nonce: "bm9uY2U=",
      ciphertext: "Y2lwaGVydGV4dA=="
    )

    let data = try JSONEncoder().encode(envelope)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(json["event_id"] as? String, "event-1")
    XCTAssertEqual(json["device_id"] as? String, "mac")
    XCTAssertEqual(json["logical_clock"] as? Int, 7)
    XCTAssertNil(json["eventID"])
  }

  func testEventEnvelopeRoundTripsWithoutChangingCiphertext() throws {
    let envelope = DayflowEventEnvelope(
      eventID: "event-2",
      deviceID: "phone",
      logicalClock: 9,
      schemaVersion: 1,
      keyVersion: 2,
      nonce: "nonce",
      ciphertext: "ciphertext"
    )

    let decoded = try JSONDecoder().decode(
      DayflowEventEnvelope.self,
      from: JSONEncoder().encode(envelope)
    )

    XCTAssertEqual(decoded, envelope)
    XCTAssertEqual(decoded.id, "event-2")
  }

  func testRelayRegistrationBootstrapRequiresExplicitAdmission() throws {
    let registration = try JSONDecoder().decode(
      DayflowRelayDevice.self,
      from: Data("""
        {
          "device_id": "mac-1",
          "public_key": "cHVibGlj",
          "signing_public_key": "c2lnbmluZw",
          "display_name": "Test Mac",
          "platform": "macos",
          "status": "approved",
          "created_at": 1,
          "last_seen_at": 2,
          "key_bootstrap_required": true
        }
        """.utf8)
    )
    XCTAssertEqual(registration.keyBootstrapRequired, true)

    let olderRelayResponse = try JSONDecoder().decode(
      DayflowRelayDevice.self,
      from: Data("""
        {
          "device_id": "mac-1",
          "public_key": "cHVibGlj",
          "signing_public_key": "c2lnbmluZw",
          "display_name": "Test Mac",
          "platform": "macos",
          "status": "approved",
          "created_at": 1,
          "last_seen_at": 2
        }
        """.utf8)
    )
    XCTAssertNil(olderRelayResponse.keyBootstrapRequired)
  }

  func testAccountScopeIsStableAndDifferentPerAccount() {
    let first = DayflowMultiDeviceAccountScope.token(for: "account-a")
    let second = DayflowMultiDeviceAccountScope.token(for: "account-a")
    let other = DayflowMultiDeviceAccountScope.token(for: "account-b")

    XCTAssertEqual(first, second)
    XCTAssertNotEqual(first, other)
    XCTAssertEqual(first?.count, 64)
    XCTAssertNil(DayflowMultiDeviceAccountScope.token(for: nil))
    XCTAssertEqual(
      DayflowMultiDeviceAccountScope.localWorkspace,
      DayflowMultiDeviceAccountScope.token(for: DayflowMultiDeviceAccountScope.localWorkspaceID)
    )
  }

  func testMacSQLiteMergeAdvancesClockAndRollsBackWithConflictingBatch() throws {
    let baseDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dayflow-clock-merge-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: baseDirectory) }

    let storage = StorageManager(
      baseDirectory: baseDirectory,
      enableBackgroundMaintenance: false
    )
    storage.ensureMultiDeviceSchema()
    let accountScope = try XCTUnwrap(DayflowMultiDeviceAccountScope.token(for: "mac-clock-test"))
    let validNonce = String(repeating: "A", count: 32)
    let validCiphertext = String(repeating: "A", count: 24)

    XCTAssertEqual(storage.nextMultiDeviceLogicalClock(accountScope: accountScope), 1)
    let remote = DayflowEventEnvelope(
      eventID: "remote-clock-17",
      deviceID: "android-clock-test",
      logicalClock: 17,
      schemaVersion: 1,
      keyVersion: 1,
      nonce: validNonce,
      ciphertext: validCiphertext
    )
    XCTAssertEqual(
      try storage.mergeMultiDeviceEvents([remote], accountScope: accountScope),
      1
    )
    XCTAssertEqual(storage.nextMultiDeviceLogicalClock(accountScope: accountScope), 18)

    let later = DayflowEventEnvelope(
      eventID: "remote-clock-40",
      deviceID: "windows-clock-test",
      logicalClock: 40,
      schemaVersion: 1,
      keyVersion: 1,
      nonce: validNonce,
      ciphertext: validCiphertext
    )
    let conflicting = DayflowEventEnvelope(
      eventID: remote.eventID,
      deviceID: remote.deviceID,
      logicalClock: remote.logicalClock,
      schemaVersion: remote.schemaVersion,
      keyVersion: remote.keyVersion,
      nonce: remote.nonce,
      ciphertext: String(repeating: "A", count: 23) + "B"
    )
    XCTAssertThrowsError(
      try storage.mergeMultiDeviceEvents([later, conflicting], accountScope: accountScope)
    )
    // The failed batch must not move the clock to 40 or leave its first row.
    XCTAssertEqual(storage.nextMultiDeviceLogicalClock(accountScope: accountScope), 19)
    XCTAssertEqual(storage.allMultiDeviceEvents(accountScope: accountScope).count, 1)
  }

  func testAccountServiceEndpointUsesTheNativeHTTPSBoundary() {
    XCTAssertEqual(
      DayflowBackendConfiguration.validatedEndpointURL(from: "https://api.dayflow.so/")?.absoluteString,
      "https://api.dayflow.so"
    )
    XCTAssertEqual(
      DayflowBackendConfiguration.validatedEndpointURL(from: "http://localhost:8787")?.host,
      "localhost"
    )
    XCTAssertNil(
      DayflowBackendConfiguration.validatedEndpointURL(from: "http://api.dayflow.so")
    )
    XCTAssertNil(
      DayflowBackendConfiguration.validatedEndpointURL(from: "https://api.dayflow.so?token=secret")
    )
    XCTAssertNil(
      DayflowBackendConfiguration.validatedEndpointURL(from: "https://user:password@api.dayflow.so")
    )
  }

  func testMacGeminiProviderKeepsAPIKeyOutOfURLQuery() throws {
    let provider = GeminiDirectProvider(apiKey: "secret-value")
    let url = try XCTUnwrap(URL(string: provider.endpointForModel(.flash35)))
    let request = provider.authorizedRequest(url: url)

    XCTAssertNil(request.url?.query)
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret-value")
  }

  func testLegacyMacDataCannotBeReboundToAnotherAccount() throws {
    let defaults = UserDefaults.standard
    let key = "dayflowLocalDataAccountBinding"
    let previous = defaults.string(forKey: key)
    defer {
      if let previous { defaults.set(previous, forKey: key) }
      else { defaults.removeObject(forKey: key) }
    }

    defaults.removeObject(forKey: key)
    try DayflowLocalDataAccountBinding.bindIfNeeded(to: "account-a")
    XCTAssertThrowsError(try DayflowLocalDataAccountBinding.bindIfNeeded(to: "account-b")) { error in
      XCTAssertEqual(error as? DayflowMigrationError, .localDataBoundToAnotherAccount)
    }
  }

  func testMacCorePrivacyDecisionHonorsBlockedApplication() throws {
    let decision = try DayflowCoreBridge.shared.captureDecision(
      context: DayflowCaptureContext(
        permissionGranted: true,
        userPaused: false,
        deviceLocked: false,
        sleeping: false,
        privateContext: false,
        drmContent: false,
        applicationID: "com.example.bank",
        windowTitle: "Password reset"
      ),
      policy: DayflowPrivacyPolicy(
        ignorePrivateContext: true,
        pauseOnDRM: true,
        blockedApplicationIDs: ["com.example.bank"],
        blockedWindowTitleFragments: ["password"]
      )
    )

    XCTAssertFalse(decision.allowed)
    XCTAssertEqual(decision.reason, "blocked_application")
  }

  func testMacPrivacySignalsProtectPrivateMeetingAndDRMWindowTitles() {
    XCTAssertTrue(
      RecordingPrivacyPreferences.inferredPrivateContext(
        applicationID: "com.google.Chrome",
        applicationName: "Google Chrome",
        windowTitle: "Acme - Incognito"
      )
    )
    XCTAssertTrue(
      RecordingPrivacyPreferences.inferredPrivateContext(
        applicationID: "us.zoom.xos",
        applicationName: "zoom.us",
        windowTitle: "Zoom Meeting - Product review"
      ) == false,
      "A non-browser meeting app is handled by the explicit title policy, not the browser private-context signal."
    )
    XCTAssertTrue(
      RecordingPrivacyPreferences.inferredDRMContent(
        applicationID: "com.google.Chrome",
        applicationName: "Google Chrome",
        windowTitle: "Protected content"
      )
    )

    let fragments = RecordingPrivacyPreferences.blockedWindowTitleFragments()
    XCTAssertTrue(fragments.contains("incognito"))
    XCTAssertTrue(fragments.contains("google meet"))
    XCTAssertTrue(fragments.contains("protected content"))
  }

  func testCaptureSourcePreferencesRoundTripWithStableLocalIdentity() throws {
    let suiteName = "DayflowTests.capture-source-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let notificationCenter = NotificationCenter()
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let source = RecordingCaptureSource(
      kind: .window,
      identifier: 42,
      bundleIdentifier: "com.example.editor",
      name: "Sprint notes"
    )
    RecordingCapturePreferences.save(
      source,
      defaults: defaults,
      notificationCenter: notificationCenter
    )

    XCTAssertEqual(RecordingCapturePreferences.selectedSource(defaults: defaults), source)
    XCTAssertEqual(source.id, "window:42")
    XCTAssertEqual(source.displayName, "Sprint notes")

    RecordingCapturePreferences.reset(
      defaults: defaults,
      notificationCenter: notificationCenter
    )
    XCTAssertEqual(
      RecordingCapturePreferences.selectedSource(defaults: defaults),
      .activeDisplay
    )
  }

  func testSelectedCaptureSignalsCarrySourcePrivacyContext() throws {
    let suiteName = "DayflowTests.capture-signals-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    RecordingPrivacyPreferences.saveBlockedApplicationIdentifiers(
      ["com.example.secret"],
      defaults: defaults
    )

    let blocked = RecordingPrivacyPreferences.captureSignals(
      applicationID: "com.example.secret",
      applicationName: "Secret app",
      windowTitle: "Password reset",
      defaults: defaults
    )
    XCTAssertEqual(blocked.blockedApplication?.bundleIdentifier, "com.example.secret")

    let privateBrowser = RecordingPrivacyPreferences.captureSignals(
      applicationID: "com.google.Chrome",
      applicationName: "Google Chrome",
      windowTitle: "Incognito - Work",
      defaults: defaults
    )
    XCTAssertTrue(privateBrowser.privateContext)
  }

  func testJournalPayloadUsesRustTaggedEventShape() throws {
    let payload = try DayflowEventPayloadEncoder.journalPayload(
      entry: JournalEntry(
        day: "2026-08-01",
        intentions: "Ship the next slice",
        notes: "Keep raw media local",
        goals: nil,
        reflections: "The replay is deterministic",
        summary: nil,
        status: "complete"
      )
    )

    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    XCTAssertEqual(json["kind"] as? String, "JournalUpsert")
    let value = try XCTUnwrap(json["value"] as? [String: Any])
    XCTAssertEqual(value["id"] as? String, "mac:v1:journal:2026-08-01")
    XCTAssertEqual(value["day"] as? String, "2026-08-01")
    XCTAssertTrue(value["body"] is String)
  }

  func testTimelinePayloadCarriesLocalCaptureProvenance() throws {
    let payload = try DayflowEventPayloadEncoder.timelineCardPayload(
      card: TimelineCardWithTimestamps(
        id: 42,
        startTimestamp: "10:00 AM",
        endTimestamp: "10:05 AM",
        startTs: 1,
        endTs: 2,
        category: "focus",
        subcategory: "engineering",
        title: "Build",
        summary: "Shared core",
        detailedSummary: "Derived on the Mac",
        day: "2026-08-01",
        distractions: nil,
        videoSummaryURL: "/Users/example/Dayflow/private-capture/video.mp4"
      )
    )

    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let value = try XCTUnwrap(json["value"] as? [String: Any])
    XCTAssertEqual(value["source"] as? String, "mac_screen_capture")
    XCTAssertEqual(value["derivation_mode"] as? String, "local_ai_derived")
    XCTAssertNil(value["video_summary_url"])
    XCTAssertFalse(String(data: payload, encoding: .utf8)?.contains("private-capture") == true)
  }

  func testTimelinePayloadAcceptsCanonicalSharedLogicalDay() throws {
    let payload = try DayflowEventPayloadEncoder.timelineCardPayload(
      card: TimelineCardWithTimestamps(
        id: 43,
        startTimestamp: "3:59 AM",
        endTimestamp: "4:05 AM",
        startTs: 1,
        endTs: 2,
        category: "focus",
        subcategory: "engineering",
        title: "Boundary",
        summary: "Shared day boundary",
        detailedSummary: "Derived locally",
        day: "2026-08-01",
        distractions: nil,
        videoSummaryURL: nil
      ),
      logicalDay: "2026-07-31"
    )

    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let value = try XCTUnwrap(json["value"] as? [String: Any])
    XCTAssertEqual(value["day"] as? String, "2026-07-31")
  }

  func testMacRustLogicalDayBridgeUsesFourAMBoundary() throws {
    let beforeBoundary = try DayflowCoreBridge.shared.logicalDayKey(
      timestampUnix: 14_399,
      timezoneOffsetMinutes: 0
    )
    let atBoundary = try DayflowCoreBridge.shared.logicalDayKey(
      timestampUnix: 14_400,
      timezoneOffsetMinutes: 0
    )

    XCTAssertNotEqual(beforeBoundary, atBoundary)
  }

  func testPriorityAndReflectionPayloadsUseStableProjectionIDs() throws {
    let priority = try DayflowEventPayloadEncoder.priorityPayload(
      id: "dayflow:v1:priority:task-1",
      day: "2026-08-01",
      rank: 0,
      text: "Finish the native sync slice"
    )
    let reflection = try DayflowEventPayloadEncoder.reflectionPayload(
      day: "2026-08-01",
      body: "The local projection is now visible."
    )

    let priorityJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: priority) as? [String: Any])
    let priorityValue = try XCTUnwrap(priorityJSON["value"] as? [String: Any])
    XCTAssertEqual(priorityJSON["kind"] as? String, "PriorityUpsert")
    XCTAssertEqual(priorityValue["id"] as? String, "dayflow:v1:priority:task-1")
    XCTAssertEqual(priorityValue["rank"] as? Int, 0)
    XCTAssertEqual(priorityValue["status"] as? String, "open")

    let reflectionJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: reflection) as? [String: Any])
    let reflectionValue = try XCTUnwrap(reflectionJSON["value"] as? [String: Any])
    XCTAssertEqual(reflectionJSON["kind"] as? String, "ReflectionUpsert")
    XCTAssertEqual(reflectionValue["id"] as? String, "mac:v1:reflection:2026-08-01")
    XCTAssertEqual(reflectionValue["body"] as? String, "The local projection is now visible.")
  }

  func testSettingPayloadUsesSharedProjectionKey() throws {
    let payload = try DayflowEventPayloadEncoder.settingPayload(
      key: "dayflow.theme",
      value: "dark"
    )
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let value = try XCTUnwrap(json["value"] as? [String: Any])
    XCTAssertEqual(json["kind"] as? String, "SettingUpsert")
    XCTAssertEqual(value["key"] as? String, "dayflow.theme")
    XCTAssertEqual(value["value"] as? String, "dark")
  }

  func testMacSharedSettingWriterNormalizesAndRejectsUnsafeValues() {
    let normalized = DayflowMacEventWriter.normalizedSharedSetting(
      key: "  dayflow.theme  ",
      value: "  dark  "
    )
    XCTAssertEqual(normalized?.key, "dayflow.theme")
    XCTAssertEqual(normalized?.value, "dark")

    XCTAssertNil(
      DayflowMacEventWriter.normalizedSharedSetting(
        key: "dayflow.capture.paused",
        value: "maybe"
      )
    )
    XCTAssertNil(
      DayflowMacEventWriter.normalizedSharedSetting(
        key: "dayflow.provider.api_key",
        value: "secret"
      )
    )
    XCTAssertNotNil(
      DayflowMacEventWriter.normalizedSharedSetting(
        key: "day_goal:2026-02-28",
        value: "{}"
      )
    )
    XCTAssertNil(
      DayflowMacEventWriter.normalizedSharedSetting(
        key: "day_goal:2026-02-29",
        value: "{}"
      )
    )
    XCTAssertNil(
      DayflowMacEventWriter.normalizedSharedSetting(
        key: "daily_standup:not-a-date",
        value: "{}"
      )
    )
  }

  func testDailyStandupSnapshotUsesContentProjectionSettingKey() throws {
    let payload = try DayflowEventPayloadEncoder.settingPayload(
      key: "daily_standup:2026-08-01",
      value: "{\"tasks\":[]}"
    )
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let value = try XCTUnwrap(json["value"] as? [String: Any])
    XCTAssertEqual(json["kind"] as? String, "SettingUpsert")
    XCTAssertEqual(value["key"] as? String, "daily_standup:2026-08-01")
    XCTAssertEqual(value["value"] as? String, "{\"tasks\":[]}")
  }

  func testDayGoalSnapshotUsesCrossDeviceSettingKey() throws {
    let plan = DayGoalPlan(
      day: "2026-08-01",
      focusTargetMinutes: 120,
      distractionLimitMinutes: 30,
      focusCategories: [
        DayGoalCategorySnapshot(
          categoryID: "focus-1",
          name: "Build",
          colorHex: "#123456",
          sortOrder: 0
        )
      ],
      distractionCategories: [],
      isSkipped: false,
      createdAt: 10,
      updatedAt: 20
    )

    let payload = try DayflowEventPayloadEncoder.settingPayload(
      key: "day_goal:2026-08-01",
      value: DayflowEventPayloadEncoder.dayGoalValue(plan)
    )
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let value = try XCTUnwrap(json["value"] as? [String: Any])
    let snapshot = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data((value["value"] as! String).utf8)) as? [String: Any]
    )

    XCTAssertEqual(json["kind"] as? String, "SettingUpsert")
    XCTAssertEqual(value["key"] as? String, "day_goal:2026-08-01")
    XCTAssertEqual(snapshot["focus_target_minutes"] as? Int, 120)
    XCTAssertEqual((snapshot["focus_categories"] as? [[String: Any]])?.first?["name"] as? String, "Build")
  }

  func testTombstonePayloadUsesStableAggregateID() throws {
    let payload = try DayflowEventPayloadEncoder.tombstonePayload(
      targetID: "mac:v1:timeline_card:42"
    )
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    XCTAssertEqual(json["kind"] as? String, "Tombstone")
    let value = try XCTUnwrap(json["value"] as? [String: Any])
    XCTAssertEqual(value["target_id"] as? String, "mac:v1:timeline_card:42")
  }

  func testSealedJournalReplaysIntoTheLocalRustProjection() throws {
    let rootKey = Data(repeating: 7, count: 32)
    let payload = try DayflowEventPayloadEncoder.journalPayload(
      entry: JournalEntry(
        day: "2026-08-01",
        intentions: "Ship the next slice",
        notes: "",
        goals: nil,
        reflections: "",
        summary: nil,
        status: "complete"
      )
    )
    let envelope = try DayflowCoreBridge.shared.seal(
      payload: payload,
      eventID: "mac:v1:journal:2026-08-01",
      deviceID: "mac-test",
      logicalClock: 1,
      accountRootKey: rootKey
    )

    let projection = try DayflowCoreBridge.shared.project(
      envelopes: [envelope],
      accountRootKey: rootKey
    )
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: projection) as? [String: Any])
    let journalEntries = try XCTUnwrap(json["journal_entries"] as? [String: Any])
    XCTAssertNotNil(journalEntries["mac:v1:journal:2026-08-01"])
  }

  func testMacCoreRekeysLocalWorkspaceEnvelopeWithoutChangingProjection() throws {
    let sourceKeyRing = try DayflowAccountKeyRing(rootKey: Data(repeating: 7, count: 32))
    let destinationKeyRing = try DayflowAccountKeyRing(rootKey: Data(repeating: 8, count: 32))
    let payload = try DayflowEventPayloadEncoder.journalPayload(
      entry: JournalEntry(
        day: "2026-08-01",
        intentions: "Keep local work available before sign-in",
        notes: "",
        goals: nil,
        reflections: "",
        summary: nil,
        status: "complete"
      )
    )
    let sourceEnvelope = try DayflowCoreBridge.shared.seal(
      payload: payload,
      eventID: "local-workspace-event-1",
      deviceID: "mac-test",
      logicalClock: 1,
      keyVersion: sourceKeyRing.activeKeyVersion,
      accountRootKey: sourceKeyRing.keyData(for: sourceKeyRing.activeKeyVersion)!
    )

    let rekeyed = try DayflowCoreBridge.shared.rekey(
      envelopes: [sourceEnvelope],
      sourceKeyRing: sourceKeyRing,
      destinationKeyRing: destinationKeyRing
    )
    let destinationEnvelope = try XCTUnwrap(rekeyed.first)
    XCTAssertEqual(destinationEnvelope.eventID, sourceEnvelope.eventID)
    XCTAssertEqual(destinationEnvelope.deviceID, sourceEnvelope.deviceID)
    XCTAssertEqual(destinationEnvelope.logicalClock, sourceEnvelope.logicalClock)
    XCTAssertNotEqual(destinationEnvelope.ciphertext, sourceEnvelope.ciphertext)

    let sourceProjection = try DayflowCoreBridge.shared.project(
      envelopes: [sourceEnvelope],
      keyRing: sourceKeyRing
    )
    let destinationProjection = try DayflowCoreBridge.shared.project(
      envelopes: [destinationEnvelope],
      keyRing: destinationKeyRing
    )
    XCTAssertEqual(sourceProjection, destinationProjection)
  }

  func testVersionedKeyRingRecoveryRoundTripsThroughPackagedRustCore() throws {
    let keyRing = try DayflowAccountKeyRing(
      activeKeyVersion: 2,
      keyData: [
        1: Data(repeating: 7, count: 32),
        2: Data(repeating: 8, count: 32),
      ]
    )
    let kit = try DayflowCoreBridge.shared.exportRecoveryKit(
      keyRing: keyRing,
      passphrase: "correct horse battery staple"
    )
    let restored = try DayflowCoreBridge.shared.restoreRecoveryKeyRing(
      kit: kit,
      passphrase: "correct horse battery staple"
    )
    XCTAssertEqual(restored, keyRing)
  }

  #if DEBUG
  func testRustProjectionReplaysIntoACopiedMacReadModel() throws {
    let rootKey = Data(repeating: 9, count: 32)
    let day = "2026-08-01"
    let events: [(String, Data)] = [
      (
        "mac:v1:timeline_card:42",
        try DayflowEventPayloadEncoder.timelineCardPayload(
          card: TimelineCardWithTimestamps(
            id: 42,
            startTimestamp: "10:00 AM",
            endTimestamp: "10:05 AM",
            startTs: 1,
            endTs: 2,
            category: "focus",
            subcategory: "engineering",
            title: "Build",
            summary: "Shared core",
            detailedSummary: "Replayed locally",
            day: day,
            distractions: nil,
            videoSummaryURL: nil
          )
        )
      ),
      (
        "mac:v1:journal:" + day,
        try DayflowEventPayloadEncoder.journalPayload(
          entry: JournalEntry(
            day: day,
            intentions: "Ship the native slice",
            notes: "Replay this locally",
            goals: nil,
            reflections: "The read model stayed coherent",
            summary: "Unified platform",
            status: "complete"
          )
        )
      ),
      (
        "dayflow:v1:priority:task-1",
        try DayflowEventPayloadEncoder.priorityPayload(
          id: "dayflow:v1:priority:task-1",
          day: day,
          rank: 0,
          text: "Verify the Mac projection"
        )
      ),
      (
        "mac:v1:reflection:" + day,
        try DayflowEventPayloadEncoder.reflectionPayload(
          day: day,
          body: "The imported read model matches the local projection."
        )
      ),
      (
        "dayflow.theme",
        try DayflowEventPayloadEncoder.settingPayload(key: "dayflow.theme", value: "dark")
      ),
      (
        "daily_standup:" + day,
        try DayflowEventPayloadEncoder.settingPayload(
          key: "daily_standup:" + day,
          value: "{\"tasks\":[{\"text\":\"Finish the replay check\"}]}"
        )
      ),
    ]
    let envelopes = try events.enumerated().map { index, event in
      try DayflowCoreBridge.shared.seal(
        payload: event.1,
        eventID: "mac-test-event-" + String(index),
        deviceID: "mac-test",
        logicalClock: UInt64(index + 1),
        accountRootKey: rootKey
      )
    }
    let projectionData = try DayflowCoreBridge.shared.project(
      envelopes: envelopes,
      accountRootKey: rootKey
    )
    let projectionJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: projectionData) as? [String: Any]
    )
    let chatContext = try XCTUnwrap(projectionJSON["chat_context"] as? [[String: Any]])
    XCTAssertEqual(chatContext.count, 4)
    let timelineProjection = try XCTUnwrap(
      (projectionJSON["timeline_cards"] as? [String: [String: Any]])?["mac:v1:timeline_card:42"]
    )
    XCTAssertEqual(timelineProjection["source"] as? String, "mac_screen_capture")
    XCTAssertEqual(timelineProjection["derivation_mode"] as? String, "local_ai_derived")

    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DayflowProjectionReplay-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let sourceDatabase = try DatabaseQueue(
      path: temporaryDirectory.appendingPathComponent("source.sqlite").path
    )
    let copiedDatabase = try DatabaseQueue(
      path: temporaryDirectory.appendingPathComponent("copied.sqlite").path
    )
    try sourceDatabase.write { db in
      try db.execute(sql: """
        CREATE TABLE timeline_cards(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          batch_id INTEGER,
          start TEXT NOT NULL,
          end TEXT NOT NULL,
          start_ts INTEGER,
          end_ts INTEGER,
          day TEXT NOT NULL,
          title TEXT NOT NULL,
          summary TEXT,
          category TEXT NOT NULL,
          subcategory TEXT,
          detailed_summary TEXT,
          metadata TEXT,
          video_summary_url TEXT,
          is_deleted INTEGER DEFAULT 0
        );
        CREATE TABLE journal_entries(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          day TEXT NOT NULL UNIQUE,
          intentions TEXT,
          notes TEXT,
          goals TEXT,
          reflections TEXT,
          summary TEXT,
          status TEXT,
          updated_at DATETIME
        );
        CREATE TABLE daily_standup_entries(
          standup_day TEXT NOT NULL PRIMARY KEY,
          payload_json TEXT NOT NULL,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
          updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE dayflow_sync_projection_records_v2(
          account_id TEXT NOT NULL,
          stable_id TEXT NOT NULL,
          record_kind TEXT NOT NULL,
          local_record_id INTEGER,
          updated_at INTEGER DEFAULT 0,
          PRIMARY KEY(account_id, stable_id)
        );
        CREATE TABLE dayflow_sync_priorities_v2(
          account_id TEXT NOT NULL,
          stable_id TEXT NOT NULL,
          day TEXT NOT NULL,
          rank INTEGER NOT NULL,
          text TEXT NOT NULL,
          status TEXT NOT NULL,
          updated_at INTEGER DEFAULT 0,
          PRIMARY KEY(account_id, stable_id)
        );
        CREATE TABLE dayflow_sync_settings_v2(
          account_id TEXT NOT NULL,
          key TEXT NOT NULL,
          value TEXT NOT NULL,
          updated_at INTEGER DEFAULT 0,
          PRIMARY KEY(account_id, key)
        );
        """)

      try db.execute(
        sql: """
          INSERT INTO timeline_cards(
            id, batch_id, start, end, start_ts, end_ts, day, title, summary, category,
            subcategory, detailed_summary, metadata, video_summary_url, is_deleted
          ) VALUES (42, NULL, '9:00 AM', '9:05 AM', 0, 1, ?, 'Legacy title',
                    'Legacy summary', 'other', NULL, NULL, NULL, NULL, 0)
          """,
        arguments: [day]
      )
      try db.execute(
        sql: """
          INSERT INTO journal_entries(
            day, intentions, notes, goals, reflections, summary, status, updated_at
          ) VALUES (?, 'Legacy intention', 'Legacy note', NULL, NULL, NULL, 'draft', CURRENT_TIMESTAMP)
          """,
        arguments: [day]
      )
      try db.execute(
        sql: """
          INSERT INTO daily_standup_entries(standup_day, payload_json)
          VALUES (?, '{"tasks":[{"text":"Legacy task"}]}')
          """,
        arguments: [day]
      )
    }

    // Use SQLite's online backup API rather than copying files directly so
    // this test exercises the same safe path used for a live WAL database.
    try sourceDatabase.backup(to: copiedDatabase)
    try sourceDatabase.read { db in
      XCTAssertEqual(
        try String.fetchOne(db, sql: "SELECT title FROM timeline_cards WHERE id = 42"),
        "Legacy title"
      )
      XCTAssertEqual(
        try String.fetchOne(db, sql: "SELECT notes FROM journal_entries WHERE day = ?", arguments: [day]),
        "Legacy note"
      )
      XCTAssertEqual(
        try String.fetchOne(db, sql: "SELECT payload_json FROM daily_standup_entries WHERE standup_day = ?", arguments: [day]),
        "{\"tasks\":[{\"text\":\"Legacy task\"}]}"
      )
    }

    let imported = try copiedDatabase.write { db in
      try StorageManager.applyMultiDeviceProjectionForTesting(
        projectionData,
        accountID: "test-account",
        in: db
      )
    }
    XCTAssertEqual(imported.timelineCardCount, 1)
    XCTAssertEqual(imported.journalEntryCount, 1)
    XCTAssertEqual(imported.priorityCount, 1)
    XCTAssertEqual(imported.reflectionCount, 1)
    XCTAssertEqual(imported.settingCount, 2)

    try copiedDatabase.read { db in
      XCTAssertEqual(
        try String.fetchOne(db, sql: "SELECT title FROM timeline_cards LIMIT 1"),
        "Build"
      )
      XCTAssertEqual(
        try String.fetchOne(db, sql: "SELECT notes FROM journal_entries WHERE day = ?", arguments: [day]),
        "Replay this locally"
      )
      XCTAssertEqual(
        try String.fetchOne(db, sql: "SELECT text FROM dayflow_sync_priorities_v2 LIMIT 1"),
        "Verify the Mac projection"
      )
      XCTAssertEqual(
        try String.fetchOne(db, sql: "SELECT reflections FROM journal_entries WHERE day = ?", arguments: [day]),
        "The imported read model matches the local projection."
      )
      XCTAssertEqual(
        try String.fetchOne(
          db,
          sql: "SELECT value FROM dayflow_sync_settings_v2 WHERE key = ?",
          arguments: ["dayflow.theme"]
        ),
        "dark"
      )
      XCTAssertEqual(
        try String.fetchOne(
          db,
          sql: "SELECT payload_json FROM daily_standup_entries WHERE standup_day = ?",
          arguments: [day]
        ),
        "{\"tasks\":[{\"text\":\"Finish the replay check\"}]}"
      )
    }

    // Replaying into the copied database must not mutate the source database.
    try sourceDatabase.read { db in
      XCTAssertEqual(
        try String.fetchOne(db, sql: "SELECT title FROM timeline_cards WHERE id = 42"),
        "Legacy title"
      )
      XCTAssertEqual(
        try String.fetchOne(db, sql: "SELECT notes FROM journal_entries WHERE day = ?", arguments: [day]),
        "Legacy note"
      )
      XCTAssertEqual(
        try String.fetchOne(db, sql: "SELECT payload_json FROM daily_standup_entries WHERE standup_day = ?", arguments: [day]),
        "{\"tasks\":[{\"text\":\"Legacy task\"}]}"
      )
    }
  }

  /// Runs only when explicitly requested with DAYFLOW_REAL_DB_CHECK=1.
  ///
  /// The source database is opened for an online SQLite backup and is never
  /// passed to StorageManager. Migration, projection, and retry behavior all
  /// run against the isolated copy, which makes this safe to execute against
  /// a real developer database while the app is closed or still running.
  func testOptInRepresentativeRealDatabaseMigrationIsSafeAndIdempotent() throws {
    guard ProcessInfo.processInfo.environment["DAYFLOW_REAL_DB_CHECK"] == "1" else {
      return
    }

    let fileManager = FileManager.default
    let appSupport = try XCTUnwrap(
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    )
    let liveDatabaseURL = appSupport
      .appendingPathComponent("Dayflow", isDirectory: true)
      .appendingPathComponent("chunks.sqlite")
    XCTAssertTrue(
      fileManager.fileExists(atPath: liveDatabaseURL.path),
      "The opt-in real database check requires the normal Dayflow database at \(liveDatabaseURL.path)."
    )

    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("DayflowRealDatabaseMigration-" + UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    let sourceDatabase = try DatabaseQueue(path: liveDatabaseURL.path)
    let sourceCounts = try sourceDatabase.read { db -> (timeline: Int, journal: Int, standup: Int, goals: Int) in
      (
        timeline: try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM timeline_cards WHERE is_deleted = 0"
        ) ?? 0,
        journal: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal_entries") ?? 0,
        standup: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_standup_entries") ?? 0,
        goals: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM day_goals") ?? 0
      )
    }

    // SQLite's online backup API takes a consistent snapshot, including any
    // committed WAL pages, without copying or modifying the live database.
    let copiedDatabaseURL = temporaryDirectory.appendingPathComponent("chunks.sqlite")
    do {
      let copiedDatabase = try DatabaseQueue(path: copiedDatabaseURL.path)
      try sourceDatabase.backup(to: copiedDatabase)
    }

    let defaults = UserDefaults.standard
    let accountKey = "dayflowMultiDeviceAccountID"
    let bindingKey = "dayflowLocalDataAccountBinding"
    let deviceKey = "dayflowMultiDeviceID"
    let previousAccountID = defaults.string(forKey: accountKey)
    let previousBinding = defaults.string(forKey: bindingKey)
    let previousDeviceID = defaults.string(forKey: deviceKey)
    defer {
      if let previousAccountID { defaults.set(previousAccountID, forKey: accountKey) }
      else { defaults.removeObject(forKey: accountKey) }
      if let previousBinding { defaults.set(previousBinding, forKey: bindingKey) }
      else { defaults.removeObject(forKey: bindingKey) }
      if let previousDeviceID { defaults.set(previousDeviceID, forKey: deviceKey) }
      else { defaults.removeObject(forKey: deviceKey) }
    }

    let accountID = "real-db-migration-check-" + UUID().uuidString.lowercased()
    defaults.set(accountID, forKey: accountKey)
    defaults.removeObject(forKey: bindingKey)
    defaults.set("real-db-migration-check-device", forKey: deviceKey)

    let storage = StorageManager(
      baseDirectory: temporaryDirectory,
      enableBackgroundMaintenance: false
    )
    let coordinator = DayflowMigrationCoordinator(storage: storage)
    let before = coordinator.preview()

    XCTAssertEqual(before.timelineCardCount, sourceCounts.timeline)
    XCTAssertEqual(before.journalEntryCount, sourceCounts.journal)
    XCTAssertEqual(before.dailyStandupCount, sourceCounts.standup)
    XCTAssertEqual(before.dayGoalCount, sourceCounts.goals)
    XCTAssertGreaterThan(
      before.totalRecordCount,
      0,
      "The opt-in real database check requires representative local history."
    )

    let rootKey = Data(repeating: 0x5A, count: 32)
    let firstResult = try coordinator.migrate(accountRootKey: rootKey)
    XCTAssertEqual(firstResult.migratedRecordCount, before.remainingRecordCount)
    XCTAssertEqual(firstResult.skippedRecordCount, 0)
    XCTAssertEqual(
      firstResult.pendingEventCount,
      before.pendingEventCount + firstResult.migratedRecordCount
    )

    let after = coordinator.preview()
    XCTAssertEqual(after.remainingRecordCount, 0)
    XCTAssertEqual(after.migratedRecordCount, after.totalRecordCount)
    XCTAssertEqual(
      storage.allMultiDeviceEvents(accountScope: DayflowMultiDeviceAccountScope.current).count,
      after.totalRecordCount
    )

    let retryResult = try coordinator.migrate(accountRootKey: rootKey)
    XCTAssertEqual(retryResult.migratedRecordCount, 0)
    XCTAssertEqual(retryResult.skippedRecordCount, after.totalRecordCount)
    XCTAssertEqual(retryResult.pendingEventCount, firstResult.pendingEventCount)

    // Re-read the source after the complete isolated migration. The source
    // database must retain its original content and row counts.
    let sourceCountsAfter = try sourceDatabase.read { db -> (timeline: Int, journal: Int, standup: Int, goals: Int) in
      (
        timeline: try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM timeline_cards WHERE is_deleted = 0"
        ) ?? 0,
        journal: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal_entries") ?? 0,
        standup: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_standup_entries") ?? 0,
        goals: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM day_goals") ?? 0
      )
    }
    XCTAssertEqual(sourceCountsAfter.timeline, sourceCounts.timeline)
    XCTAssertEqual(sourceCountsAfter.journal, sourceCounts.journal)
    XCTAssertEqual(sourceCountsAfter.standup, sourceCounts.standup)
    XCTAssertEqual(sourceCountsAfter.goals, sourceCounts.goals)

    print(
      "✅ Real database migration check: \(after.totalRecordCount) records migrated in an isolated copy; retry was idempotent; source row counts were unchanged."
    )
  }
  #endif

  #if DEBUG
  func testRelayURLAllowsLoopbackHTTPButRejectsRemoteHTTP() {
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: DayflowSyncRelayConfiguration.overrideKey)
    defer {
      if let previous {
        defaults.set(previous, forKey: DayflowSyncRelayConfiguration.overrideKey)
      } else {
        defaults.removeObject(forKey: DayflowSyncRelayConfiguration.overrideKey)
      }
    }

    defaults.set("http://127.0.0.1:8787", forKey: DayflowSyncRelayConfiguration.overrideKey)
    XCTAssertEqual(DayflowSyncRelayConfiguration.baseURL?.host, "127.0.0.1")

    defaults.set("http://sync.example.com", forKey: DayflowSyncRelayConfiguration.overrideKey)
    XCTAssertNil(DayflowSyncRelayConfiguration.baseURL)

    defaults.set("https://user:password@sync.example.com", forKey: DayflowSyncRelayConfiguration.overrideKey)
    XCTAssertNil(DayflowSyncRelayConfiguration.baseURL)

    defaults.set("https://sync.example.com?token=secret", forKey: DayflowSyncRelayConfiguration.overrideKey)
    XCTAssertNil(DayflowSyncRelayConfiguration.baseURL)
  }
  #endif

  func testCaptureSyncNeverSendsRawMediaToRelay() async throws {
    DayflowRecordingURLProtocol.reset()

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DayflowRecordingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let relay = DayflowSyncRelayClient(
      baseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
      session: session
    )

    let rawMediaMarker = "/Users/example/Dayflow/private-capture/raw-screen-recording.mp4"
    let payload = try DayflowEventPayloadEncoder.timelineCardPayload(
      card: TimelineCardWithTimestamps(
        id: 99,
        startTimestamp: "10:00 AM",
        endTimestamp: "10:05 AM",
        startTs: 1,
        endTs: 2,
        category: "focus",
        subcategory: "engineering",
        title: "Local capture",
        summary: "Derived locally",
        detailedSummary: "Only the derived card should sync.",
        day: "2026-08-01",
        distractions: nil,
        videoSummaryURL: rawMediaMarker
      )
    )
    XCTAssertFalse(String(data: payload, encoding: .utf8)?.contains(rawMediaMarker) == true)

    let envelope = try DayflowCoreBridge.shared.seal(
      payload: payload,
      eventID: "raw-media-network-test",
      deviceID: "mac-network-test",
      logicalClock: 1,
      accountRootKey: Data(repeating: 7, count: 32)
    )
    let signingKey = try DayflowCoreBridge.shared.generateDeviceSigningKeyMaterial()

    _ = try await relay.push(
      envelopes: [envelope],
      token: "test-token",
      deviceID: "mac-network-test",
      signingPrivateKey: signingKey.privateKey
    )

    let request = try XCTUnwrap(DayflowRecordingURLProtocol.lastRequest())
    let body = try XCTUnwrap(DayflowRecordingURLProtocol.lastBody())
    let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
    XCTAssertEqual(request.url?.path, "/v1/sync/events")
    XCTAssertTrue(bodyText.contains("\"ciphertext\""))
    XCTAssertFalse(bodyText.contains(rawMediaMarker))
    XCTAssertFalse(bodyText.contains("raw-screen-recording.mp4"))
    XCTAssertFalse(bodyText.contains("screenshot"))
  }

  func testGeneratedRustBridgeMatchesCanonicalRequestVector() throws {
    let request = try DayflowCoreBridge.shared.canonicalDeviceRequest(
      method: "post",
      pathWithQuery: "/v1/sync/events?cursor=abc",
      body: Data(#"{"hello":"opaque"}"#.utf8),
      timestamp: 1_723_456_789,
      nonce: "0123456789abcdef0123456789abcdef",
      deviceID: "mac-device"
    )

    XCTAssertEqual(
      request,
      "dayflow:v1:1723456789:POST:/v1/sync/events?cursor=abc:" +
        "b7e6d00fedcbdee445a53f6b804273eeb7a62879a6891f7bdc4f9b238675a4f4:" +
        "0123456789abcdef0123456789abcdef:mac-device"
    )
  }
}

private final class DayflowRecordingURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var requests: [URLRequest] = []
  private static var bodies: [Data] = []

  static func reset() {
    lock.lock()
    defer { lock.unlock() }
    requests.removeAll(keepingCapacity: true)
    bodies.removeAll(keepingCapacity: true)
  }

  static func lastRequest() -> URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return requests.last
  }

  static func lastBody() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return bodies.last
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let requestBody = Self.bodyData(for: request)
    Self.lock.lock()
    Self.requests.append(request)
    if let requestBody {
      Self.bodies.append(requestBody)
    }
    Self.lock.unlock()

    guard let client else { return }
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://relay.example.test")!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    let responseBody = Data("""
    {"accepted_event_ids":["raw-media-network-test"],"duplicate_event_ids":[],"cursor":"Y3Vyc29y","notification_count":1}
    """.utf8)
    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client.urlProtocol(self, didLoad: responseBody)
    client.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func bodyData(for request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    let bufferSize = 16 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var body = Data()
    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: bufferSize)
      guard count > 0 else { break }
      body.append(buffer, count: count)
    }
    return body
  }
}
