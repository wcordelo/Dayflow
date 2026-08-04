import Foundation

struct DayflowMigrationPreview: Equatable, Sendable {
  let dayCount: Int
  let timelineCardCount: Int
  let journalEntryCount: Int
  let dailyStandupCount: Int
  let priorityCount: Int
  let dayGoalCount: Int
  let migratedRecordCount: Int
  let pendingEventCount: Int

  var totalRecordCount: Int {
    timelineCardCount + journalEntryCount + dailyStandupCount + priorityCount + dayGoalCount
  }

  var remainingRecordCount: Int {
    max(0, totalRecordCount - migratedRecordCount)
  }
}

private struct DayflowMigrationPriority: Sendable {
  let id: UUID
  let rank: Int
  let text: String
}

struct DayflowMigrationResult: Equatable, Sendable {
  let migratedRecordCount: Int
  let skippedRecordCount: Int
  let pendingEventCount: Int
}

enum DayflowMigrationError: LocalizedError, Equatable {
  case missingAccount
  case missingRootKey
  case localDataBoundToAnotherAccount
  case recordHasNoStableID(String)
  case markerWriteFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingAccount:
      return "Sign in to Dayflow before migrating data for encrypted sync."
    case .missingRootKey:
      return "Create the local encryption key before migrating Dayflow data."
    case .localDataBoundToAnotherAccount:
      return "This Mac's existing local history is bound to another Dayflow account. Export or reset the local database before changing accounts."
    case .recordHasNoStableID(let day):
      return "A timeline record on \(day) does not have a stable local ID yet."
    case .markerWriteFailed(let stableID):
      return "Dayflow could not record the migration marker for \(stableID)."
    }
  }
}

/// Imports the existing Mac projections into encrypted event envelopes.
///
/// This is intentionally an adapter, not a second database model: existing
/// GRDB tables remain readable by the current UI while each imported aggregate
/// gets one stable event ID and one idempotent migration marker.
final class DayflowMigrationCoordinator: Sendable {
  static let migrationVersion = 1

  private let storage: StorageManager
  private let core: DayflowCoreBridge

  init(storage: StorageManager = .shared, core: DayflowCoreBridge = .shared) {
    self.storage = storage
    self.core = core
  }

  func preview() -> DayflowMigrationPreview {
    let days = migrationDays()
    var timelineCardCount = 0
    var journalEntryCount = 0
    var dailyStandupCount = 0
    var priorityCount = 0
    var dayGoalCount = 0
    var migratedRecordCount = 0

    for day in days {
      let cards = storage.fetchTimelineCards(forDay: day)
      timelineCardCount += cards.count
      journalEntryCount += storage.fetchJournalEntry(forDay: day) == nil ? 0 : 1

      if storage.fetchDayGoalPlan(forDay: day) != nil {
        dayGoalCount += 1
        if storage.hasMultiDeviceMigrationRecord(
          stableID: Self.dayGoalStableID(day),
          version: Self.migrationVersion
        ) {
          migratedRecordCount += 1
        }
      }

      if let standup = storage.fetchDailyStandup(forDay: day) {
        dailyStandupCount += 1
        let priorities = priorityItems(from: standup.payloadJSON)
        priorityCount += priorities.count
        if storage.hasMultiDeviceMigrationRecord(
          stableID: Self.dailyStandupStableID(day),
          version: Self.migrationVersion
        ) {
          migratedRecordCount += 1
        }
        for item in priorities where storage.hasMultiDeviceMigrationRecord(
          stableID: Self.priorityStableID(item.id),
          version: Self.migrationVersion
        ) {
          migratedRecordCount += 1
        }
      }

      for card in cards {
        guard let recordID = card.recordId else { continue }
        if storage.hasMultiDeviceMigrationRecord(
          stableID: Self.timelineStableID(recordID),
          version: Self.migrationVersion
        ) {
          migratedRecordCount += 1
        }
      }
      if storage.fetchJournalEntry(forDay: day) != nil,
        storage.hasMultiDeviceMigrationRecord(
          stableID: Self.journalStableID(day),
          version: Self.migrationVersion
        )
      {
        migratedRecordCount += 1
      }
    }

    return DayflowMigrationPreview(
      dayCount: days.count,
      timelineCardCount: timelineCardCount,
      journalEntryCount: journalEntryCount,
      dailyStandupCount: dailyStandupCount,
      priorityCount: priorityCount,
      dayGoalCount: dayGoalCount,
      migratedRecordCount: migratedRecordCount,
      pendingEventCount: storage.multiDeviceSyncStatus().pendingCount
    )
  }

  func migrate(accountRootKey: Data) throws -> DayflowMigrationResult {
    let keyRing = try DayflowAccountKeyRing(rootKey: accountRootKey)
    return try migrate(keyRing: keyRing)
  }

  func migrate(keyRing: DayflowAccountKeyRing) throws -> DayflowMigrationResult {
    guard let accountID = DayflowAccountIdentity.currentID else {
      throw DayflowMigrationError.missingAccount
    }
    try DayflowLocalDataAccountBinding.bindIfNeeded(to: accountID)
    guard keyRing.keyData(for: keyRing.activeKeyVersion) != nil else {
      throw DayflowMigrationError.missingRootKey
    }

    var migrated = 0
    var skipped = 0

    for day in migrationDays().sorted() {
      let cards = storage.fetchTimelineCards(forDay: day)
      for card in cards {
        guard let recordID = card.recordId else {
          throw DayflowMigrationError.recordHasNoStableID(day)
        }
        let stableID = Self.timelineStableID(recordID)
        guard storage.hasMultiDeviceMigrationRecord(
          stableID: stableID,
          version: Self.migrationVersion
        ) == false else {
          skipped += 1
          continue
        }

        guard let cardWithTimestamps = storage.fetchTimelineCard(byId: recordID) else {
          throw DayflowMigrationError.recordHasNoStableID(day)
        }
        let logicalDay = try core.logicalDayKey(
          forUnixTimestamp: Int64(cardWithTimestamps.startTs)
        )
        let payload = try DayflowEventPayloadEncoder.timelineCardPayload(
          card: cardWithTimestamps,
          logicalDay: logicalDay
        )
        try sealAndPersist(
          payload: payload,
          stableID: stableID,
          eventID: Self.timelineEventID(recordID),
          sourceKind: "timeline_card",
          sourceDay: logicalDay,
          sourceRecordID: String(recordID),
          keyRing: keyRing
        )
        migrated += 1
      }

      if let journal = storage.fetchJournalEntry(forDay: day) {
        let stableID = Self.journalStableID(day)
        if storage.hasMultiDeviceMigrationRecord(
          stableID: stableID,
          version: Self.migrationVersion
        ) {
          skipped += 1
        } else {
          let payload = try DayflowEventPayloadEncoder.journalPayload(entry: journal)
          try sealAndPersist(
            payload: payload,
            stableID: stableID,
            eventID: Self.journalEventID(day),
            sourceKind: "journal",
            sourceDay: day,
            sourceRecordID: journal.id.map(String.init),
            keyRing: keyRing
          )
          migrated += 1
        }
      }

      if let dayGoal = storage.fetchDayGoalPlan(forDay: day) {
        let stableID = Self.dayGoalStableID(day)
        if storage.hasMultiDeviceMigrationRecord(
          stableID: stableID,
          version: Self.migrationVersion
        ) {
          skipped += 1
        } else {
          let payload = try DayflowEventPayloadEncoder.settingPayload(
            key: Self.dayGoalSettingKey(day),
            value: DayflowEventPayloadEncoder.dayGoalValue(dayGoal)
          )
          try sealAndPersist(
            payload: payload,
            stableID: stableID,
            eventID: Self.dayGoalEventID(day),
            sourceKind: "day_goal",
            sourceDay: day,
            sourceRecordID: day,
            keyRing: keyRing
          )
          migrated += 1
        }
      }

      guard let standup = storage.fetchDailyStandup(forDay: day) else { continue }

      let standupStableID = Self.dailyStandupStableID(day)
      if storage.hasMultiDeviceMigrationRecord(
        stableID: standupStableID,
        version: Self.migrationVersion
      ) {
        skipped += 1
      } else {
        let payload = try DayflowEventPayloadEncoder.settingPayload(
          key: Self.dailyStandupSettingKey(day),
          value: standup.payloadJSON
        )
        try sealAndPersist(
          payload: payload,
          stableID: standupStableID,
          eventID: Self.dailyStandupEventID(day),
          sourceKind: "daily_standup",
          sourceDay: day,
          sourceRecordID: nil,
          keyRing: keyRing
        )
        migrated += 1
      }

      for item in priorityItems(from: standup.payloadJSON) {
        let stableID = Self.priorityStableID(item.id)
        guard storage.hasMultiDeviceMigrationRecord(
          stableID: stableID,
          version: Self.migrationVersion
        ) == false else {
          skipped += 1
          continue
        }

        let payload = try DayflowEventPayloadEncoder.priorityPayload(
          id: stableID,
          day: day,
          rank: item.rank,
          text: item.text
        )
        try sealAndPersist(
          payload: payload,
          stableID: stableID,
          eventID: Self.priorityEventID(item.id),
          sourceKind: "priority",
          sourceDay: day,
          sourceRecordID: item.id.uuidString.lowercased(),
          keyRing: keyRing
        )
        migrated += 1
      }
    }

    return DayflowMigrationResult(
      migratedRecordCount: migrated,
      skippedRecordCount: skipped,
      pendingEventCount: storage.multiDeviceSyncStatus().pendingCount
    )
  }

  private func sealAndPersist(
    payload: Data,
    stableID: String,
    eventID: String,
    sourceKind: String,
    sourceDay: String,
    sourceRecordID: String?,
    keyRing: DayflowAccountKeyRing
  ) throws {
    // A crash can occur after the immutable envelope is durable but before the
    // migration marker is written. Reuse that envelope on retry; allocating a
    // new clock and resealing the same event ID would correctly be rejected as
    // an immutable-event conflict and would leave migration stuck forever.
    if try storage.throwingMultiDeviceEvent(eventID: eventID) != nil {
      guard storage.recordMultiDeviceMigration(
        stableID: stableID,
        eventID: eventID,
        sourceKind: sourceKind,
        sourceDay: sourceDay,
        sourceRecordID: sourceRecordID,
        version: Self.migrationVersion
      ) else {
        throw DayflowMigrationError.markerWriteFailed(stableID)
      }
      return
    }

    guard let logicalClock = storage.nextMultiDeviceLogicalClock() else {
      throw DayflowMigrationError.markerWriteFailed(stableID)
    }
    let envelope = try core.seal(
      payload: payload,
      eventID: eventID,
      deviceID: DayflowDeviceIdentity.currentID,
      logicalClock: logicalClock,
      keyVersion: keyRing.activeKeyVersion,
      accountRootKey: keyRing.keyData(for: keyRing.activeKeyVersion)!
    )
    guard storage.enqueueMultiDeviceEvent(envelope) else {
      throw DayflowMigrationError.markerWriteFailed(stableID)
    }
    guard storage.recordMultiDeviceMigration(
      stableID: stableID,
      eventID: eventID,
      sourceKind: sourceKind,
      sourceDay: sourceDay,
      sourceRecordID: sourceRecordID,
      version: Self.migrationVersion
    ) else {
      throw DayflowMigrationError.markerWriteFailed(stableID)
    }
  }

  private func migrationDays() -> [String] {
    Set(
      storage.multiDeviceTimelineDays()
        + storage.fetchJournalDays(limit: 100_000)
        + storage.fetchDayGoalDays(limit: 100_000)
        + storage.fetchAllDailyStandups().map(\.standupDay)
    ).sorted(by: >)
  }

  private func priorityItems(from payloadJSON: String) -> [DayflowMigrationPriority] {
    guard
      let data = payloadJSON.data(using: .utf8),
      let draft = try? JSONDecoder().decode(DailyStandupDraft.self, from: data)
    else {
      return []
    }

    var seen = Set<UUID>()
    return draft.tasks.enumerated().compactMap { rank, item in
      let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.isEmpty == false, seen.insert(item.id).inserted else { return nil }
      return DayflowMigrationPriority(id: item.id, rank: rank, text: text)
    }
  }

  private static func timelineStableID(_ recordID: Int64) -> String {
    "mac:v1:timeline_card:\(recordID)"
  }

  private static func journalStableID(_ day: String) -> String {
    "mac:v1:journal:\(day)"
  }

  private static func timelineEventID(_ recordID: Int64) -> String {
    "mac-migration-v1-timeline-\(recordID)"
  }

  private static func journalEventID(_ day: String) -> String {
    "mac-migration-v1-journal-\(day)"
  }

  private static func dailyStandupStableID(_ day: String) -> String {
    "mac:v1:daily_standup:\(day)"
  }

  private static func dailyStandupSettingKey(_ day: String) -> String {
    "daily_standup:\(day)"
  }

  private static func dailyStandupEventID(_ day: String) -> String {
    "mac-migration-v1-daily-standup-\(day)"
  }

  private static func dayGoalStableID(_ day: String) -> String {
    "mac:v1:day_goal:\(day)"
  }

  private static func dayGoalSettingKey(_ day: String) -> String {
    "day_goal:\(day)"
  }

  private static func dayGoalEventID(_ day: String) -> String {
    "mac-migration-v1-day-goal-\(day)"
  }

  private static func priorityStableID(_ itemID: UUID) -> String {
    "dayflow:v1:priority:\(itemID.uuidString.lowercased())"
  }

  private static func priorityEventID(_ itemID: UUID) -> String {
    "mac-migration-v1-priority-\(itemID.uuidString.lowercased())"
  }

}
