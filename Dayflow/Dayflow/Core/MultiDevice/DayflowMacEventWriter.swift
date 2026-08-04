import Foundation

/// Appends user edits to the local encrypted outbox after the legacy GRDB
/// write succeeds. No root key or plaintext payload leaves this process.
enum DayflowMacEventWriter {
  static func appendJournal(day: String, storage: StorageManager = .shared) {
    guard let entry = storage.fetchJournalEntry(forDay: day) else { return }
    guard let payload = try? DayflowEventPayloadEncoder.journalPayload(entry: entry) else { return }
    append(
      payload: payload,
      aggregateID: "mac:v1:journal:\(day)",
      storage: storage
    )
    appendReflection(day: day, body: entry.reflections ?? "", storage: storage)
  }

  static func appendReflection(day: String, body: String, storage: StorageManager = .shared) {
    let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let aggregateID = "mac:v1:reflection:\(day)"
    guard normalized.isEmpty == false else {
      appendTombstone(targetID: aggregateID, storage: storage)
      return
    }
    guard let payload = try? DayflowEventPayloadEncoder.reflectionPayload(day: day, body: normalized) else {
      return
    }
    append(payload: payload, aggregateID: aggregateID, storage: storage)
  }

  static func appendPriorities(
    day: String,
    previousPayloadJSON: String?,
    payloadJSON: String,
    storage: StorageManager = .shared
  ) {
    let previousIDs = priorityIDs(day: day, payloadJSON: previousPayloadJSON)
    guard let draft = try? JSONDecoder().decode(
      DailyStandupDraft.self,
      from: Data(payloadJSON.utf8)
    ) else {
      return
    }

    let items = draft.tasks.enumerated().compactMap { rank, item -> (String, String, Int)? in
      let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.isEmpty == false else { return nil }
      // Priority identity is device-independent. The logical day remains a
      // field on the record; it must not be part of the aggregate ID or a
      // later edit from Android, Windows, or iOS will create a second row.
      let id = "dayflow:v1:priority:\(item.id.uuidString.lowercased())"
      return (id, text, rank)
    }
    let currentIDs = Set(items.map(\.0))
    for removedID in previousIDs.subtracting(currentIDs) {
      appendTombstone(targetID: removedID, storage: storage)
    }
    for (id, text, rank) in items {
      guard let payload = try? DayflowEventPayloadEncoder.priorityPayload(
        id: id,
        day: day,
        rank: rank,
        text: text
      ) else { continue }
      append(payload: payload, aggregateID: id, storage: storage)
    }
  }

  static func appendTimelineCard(recordID: Int64, storage: StorageManager = .shared) {
    guard let card = storage.fetchTimelineCard(byId: recordID) else { return }
    guard let logicalDay = try? DayflowCoreBridge.shared.logicalDayKey(
      forUnixTimestamp: Int64(card.startTs)
    ) else {
      return
    }
    guard let payload = try? DayflowEventPayloadEncoder.timelineCardPayload(
      card: card,
      logicalDay: logicalDay
    ) else { return }
    append(
      payload: payload,
      aggregateID: "mac:v1:timeline_card:\(recordID)",
      storage: storage
    )
  }

  static func appendTombstone(targetID: String, storage: StorageManager = .shared) {
    guard targetID.isEmpty == false else { return }
    guard let payload = try? DayflowEventPayloadEncoder.tombstonePayload(targetID: targetID) else {
      return
    }
    append(payload: payload, aggregateID: targetID, storage: storage)
  }

  @discardableResult
  static func appendSetting(key: String, value: String, storage: StorageManager = .shared) -> Bool {
    guard let setting = normalizedSharedSetting(key: key, value: value) else { return false }
    guard let payload = try? DayflowEventPayloadEncoder.settingPayload(
      key: setting.key,
      value: setting.value
    ) else {
      return false
    }
    return append(payload: payload, aggregateID: setting.key, storage: storage)
  }

  /// Shared settings are user-editable projection inputs, so every native
  /// shell applies the same normalization and fail-closed validation before
  /// an event is sealed. In particular, a malformed capture-pause value must
  /// never be interpreted as permission to resume capture.
  static func normalizedSharedSetting(key: String, value: String) -> (key: String, value: String)? {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedKey.isEmpty == false,
      isAllowedSharedSettingKey(normalizedKey)
    else { return nil }
    if normalizedKey == "dayflow.capture.paused",
      normalizedValue != "true",
      normalizedValue != "false"
    {
      return nil
    }
    return (normalizedKey, normalizedValue)
  }

  @discardableResult
  private static func append(
    payload: Data,
    aggregateID: String,
    storage: StorageManager
  ) -> Bool {
    // The Mac is local-first even before account setup. Signed-out and
    // partially admitted edits use the device-local workspace; once an
    // account key is admitted, new edits go directly to that account outbox.
    let keyStore = DayflowMultiDeviceKeyStore.shared
    let accountScope: String
    let keyRing: DayflowAccountKeyRing
    if DayflowAccountIdentity.currentID != nil, keyStore.hasAccountKeyAdmission {
      // Account identity and its derived scope can change during sign-out.
      // An account key-ring is not enough to authorize account writes: a
      // legacy/restored key becomes account-scoped only after relay admission.
      // If an admitted ring disappears during sign-out, fail closed rather
      // than attributing the edit to the local workspace.
      guard let currentAccountScope = DayflowMultiDeviceAccountScope.current,
        let accountKeyRing = keyStore.loadAccountKeyRing()
      else { return false }
      accountScope = currentAccountScope
      keyRing = accountKeyRing
    } else {
      // Local-first edits remain available while a signed-in device is
      // waiting for approval or has not completed key admission.
      guard let localKeyRing = try? keyStore.ensureLocalWorkspaceKeyRing() else { return false }
      accountScope = DayflowMultiDeviceAccountScope.localWorkspace
      keyRing = localKeyRing
    }

    guard let logicalClock = storage.nextMultiDeviceLogicalClock(accountScope: accountScope),
      let rootKey = keyRing.keyData(for: keyRing.activeKeyVersion)
    else { return false }

    do {
      let envelope = try DayflowCoreBridge.shared.seal(
        payload: payload,
        eventID: "mac-edit-v1-\(UUID().uuidString.lowercased())",
        deviceID: DayflowDeviceIdentity.currentID,
        logicalClock: logicalClock,
        keyVersion: keyRing.activeKeyVersion,
        accountRootKey: rootKey
      )
      guard storage.enqueueMultiDeviceEvent(envelope, accountScope: accountScope) else {
        print("⚠️ [MultiDevice] Unable to queue local edit event")
        return false
      }

      _ = aggregateID // Stable aggregate IDs live inside the sealed payload.
      return true
    } catch {
      print("⚠️ [MultiDevice] Unable to seal local edit event: \(error.localizedDescription)")
      return false
    }
  }

  private static func priorityIDs(day: String, payloadJSON: String?) -> Set<String> {
    guard let payloadJSON,
      let draft = try? JSONDecoder().decode(
        DailyStandupDraft.self,
        from: Data(payloadJSON.utf8)
      )
    else { return [] }
    return Set(draft.tasks.flatMap { item in
      let uuid = item.id.uuidString.lowercased()
      // Include the pre-contract ID while reading an older local payload so
      // the next save can tombstone the legacy projection and write the
      // canonical cross-device aggregate.
      return [
        "dayflow:v1:priority:\(uuid)",
        "mac:v1:priority:\(day):\(uuid)",
      ]
    })
  }

  private static func isAllowedSharedSettingKey(_ key: String) -> Bool {
    key == "dayflow.theme"
      || key == "dayflow.capture.paused"
      || key == "dayflow.logical_day_boundary_hour"
      || isValidDatedSharedSettingKey(key, prefix: "day_goal:")
      || isValidDatedSharedSettingKey(key, prefix: "daily_standup:")
  }

  private static func isValidDatedSharedSettingKey(_ key: String, prefix: String) -> Bool {
    guard key.hasPrefix(prefix) else { return false }
    let day = String(key.dropFirst(prefix.count))
    guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
      return false
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: day) else { return false }
    return formatter.string(from: date) == day
  }
}
