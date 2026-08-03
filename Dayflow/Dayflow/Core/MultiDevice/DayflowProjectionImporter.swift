import Foundation
import GRDB

enum DayflowSharedCapturePause {
  static let settingKey = "dayflow.capture.paused"

  static func isPaused(_ value: String?) -> Bool {
    guard let value else { return false }
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "false": return false
    case "true": return true
    default: return true
    }
  }
}

struct DayflowProjectionApplyResult: Equatable, Sendable {
  let timelineCardCount: Int
  let journalEntryCount: Int
  let priorityCount: Int
  let reflectionCount: Int
  let settingCount: Int
  let tombstoneCount: Int

  static let empty = DayflowProjectionApplyResult(
    timelineCardCount: 0,
    journalEntryCount: 0,
    priorityCount: 0,
    reflectionCount: 0,
    settingCount: 0,
    tombstoneCount: 0
  )
}

enum DayflowProjectionImportError: LocalizedError, Equatable {
  case missingAccount
  case invalidProjection

  var errorDescription: String? {
    switch self {
    case .missingAccount:
      return "Dayflow cannot apply synced records until an account is connected."
    case .invalidProjection:
      return "Dayflow received an invalid local projection from the shared core."
    }
  }
}

private struct DayflowRustProjection: Decodable {
  let timelineCards: [String: DayflowRustTimelineCard]
  let journalEntries: [String: DayflowRustJournalEntry]
  let priorities: [String: DayflowRustPriority]
  let reflections: [String: DayflowRustReflection]
  let settings: [String: String]
  let tombstones: [String]

  enum CodingKeys: String, CodingKey {
    case timelineCards = "timeline_cards"
    case journalEntries = "journal_entries"
    case priorities
    case reflections
    case settings
    case tombstones
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    timelineCards = try container.decodeIfPresent(
      [String: DayflowRustTimelineCard].self,
      forKey: .timelineCards
    ) ?? [:]
    journalEntries = try container.decodeIfPresent(
      [String: DayflowRustJournalEntry].self,
      forKey: .journalEntries
    ) ?? [:]
    priorities = try container.decodeIfPresent(
      [String: DayflowRustPriority].self,
      forKey: .priorities
    ) ?? [:]
    reflections = try container.decodeIfPresent(
      [String: DayflowRustReflection].self,
      forKey: .reflections
    ) ?? [:]
    settings = try container.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
    tombstones = try container.decodeIfPresent([String].self, forKey: .tombstones) ?? []
  }
}

private struct DayflowRustTimelineCard: Decodable {
  let id: String
  let day: String
  let startTimestamp: Int64
  let endTimestamp: Int64
  let title: String
  let summary: String
  let category: String
  let subcategory: String
  let detailedSummary: String
  let source: String
  let derivationMode: String

  enum CodingKeys: String, CodingKey {
    case id
    case day
    case startTimestamp = "start_timestamp"
    case endTimestamp = "end_timestamp"
    case title
    case summary
    case category
    case subcategory
    case detailedSummary = "detailed_summary"
    case source
    case derivationMode = "derivation_mode"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    day = try container.decode(String.self, forKey: .day)
    startTimestamp = try container.decode(Int64.self, forKey: .startTimestamp)
    endTimestamp = try container.decode(Int64.self, forKey: .endTimestamp)
    title = try container.decode(String.self, forKey: .title)
    summary = try container.decode(String.self, forKey: .summary)
    category = try container.decode(String.self, forKey: .category)
    subcategory = try container.decodeIfPresent(String.self, forKey: .subcategory) ?? ""
    detailedSummary = try container.decodeIfPresent(String.self, forKey: .detailedSummary) ?? ""
    source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
    derivationMode = try container.decodeIfPresent(String.self, forKey: .derivationMode) ?? ""
  }
}

private struct DayflowRustJournalEntry: Decodable {
  let id: String
  let day: String
  let body: String
}

private struct DayflowRustPriority: Decodable {
  let id: String
  let day: String
  let rank: Int
  let text: String
  let status: String
}

private struct DayflowRustReflection: Decodable {
  let id: String
  let day: String
  let body: String
}

private struct DayflowJournalSnapshot: Decodable {
  let intentions: String?
  let notes: String?
  let goals: String?
  let reflections: String?
  let summary: String?
  let status: String
  let updatedAt: TimeInterval?

  enum CodingKeys: String, CodingKey {
    case intentions
    case notes
    case goals
    case reflections
    case summary
    case status
    case updatedAt = "updated_at"
  }
}

/// Applies the Rust projection to the legacy GRDB read model after a successful
/// local decrypt/replay. It never calls the public StorageManager write helpers,
/// so importing another device cannot create a sync echo loop.
extension StorageManager {
  @discardableResult
  func applyMultiDeviceProjection(
    _ data: Data,
    accountScope: String? = nil
  ) throws -> DayflowProjectionApplyResult {
    let accountID: String
    if let accountScope {
      accountID = accountScope
    } else if let currentAccountScope = DayflowMultiDeviceAccountScope.current {
      accountID = currentAccountScope
    } else {
      throw DayflowProjectionImportError.missingAccount
    }
    guard let projection = try? JSONDecoder().decode(DayflowRustProjection.self, from: data) else {
      throw DayflowProjectionImportError.invalidProjection
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "h:mm a"

    let result = try timedWrite("apply_multi_device_projection") { db in
      try Self.applyProjection(
        projection,
        accountID: accountID,
        formatter: formatter,
        db: db
      )
    }
    NotificationCenter.default.post(
      name: .dayflowSharedCapturePauseChanged,
      object: nil,
      userInfo: ["paused": DayflowSharedCapturePause.isPaused(projection.settings[DayflowSharedCapturePause.settingKey])]
    )
    return result
  }

  func multiDeviceSharedSettingValue(for key: String) -> String? {
    let accountID = DayflowMultiDeviceAccountScope.current
    let localWorkspace = DayflowMultiDeviceAccountScope.localWorkspace
    return (try? timedRead("read_multi_device_setting") { db in
      if let accountID,
        let accountValue = try String.fetchOne(
          db,
          sql: "SELECT value FROM dayflow_sync_settings_v2 WHERE account_id = ? AND key = ?",
          arguments: [accountID, key]
        )
      {
        return accountValue
      }
      return try String.fetchOne(
        db,
        sql: "SELECT value FROM dayflow_sync_settings_v2 WHERE account_id = ? AND key = ?",
        arguments: [localWorkspace, key]
      )
    }) ?? nil
  }

  #if DEBUG
  /// Applies the same importer to an injected database so unit tests can prove
  /// replay equivalence without opening or mutating the user's database.
  @discardableResult
  static func applyMultiDeviceProjectionForTesting(
    _ data: Data,
    accountID: String,
    in db: Database
  ) throws -> DayflowProjectionApplyResult {
    guard let projection = try? JSONDecoder().decode(DayflowRustProjection.self, from: data) else {
      throw DayflowProjectionImportError.invalidProjection
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "h:mm a"
    return try applyProjection(projection, accountID: accountID, formatter: formatter, db: db)
  }
  #endif

  private static func applyProjection(
    _ projection: DayflowRustProjection,
    accountID: String,
    formatter: DateFormatter,
    db: Database
  ) throws -> DayflowProjectionApplyResult {
      var timelineCount = 0
      var journalCount = 0

      for (stableID, card) in projection.timelineCards {
        let localID = try Self.upsertProjectedTimelineCard(
          card,
          stableID: stableID,
          accountID: accountID,
          formatter: formatter,
          db: db
        )
        try Self.recordProjectedMapping(
          stableID: stableID,
          accountID: accountID,
          recordKind: "timeline_card",
          localRecordID: localID,
          db: db
        )
        timelineCount += 1
      }

      for (stableID, entry) in projection.journalEntries {
        let localID = try Self.upsertProjectedJournalEntry(entry, db: db)
        try Self.recordProjectedMapping(
          stableID: stableID,
          accountID: accountID,
          recordKind: "journal",
          localRecordID: localID,
          db: db
        )
        journalCount += 1
      }

      for (stableID, priority) in projection.priorities {
        try db.execute(
          sql: """
            INSERT INTO dayflow_sync_priorities_v2(
              account_id, stable_id, day, rank, text, status
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, stable_id) DO UPDATE SET
              day = excluded.day,
              rank = excluded.rank,
              text = excluded.text,
              status = excluded.status,
              updated_at = strftime('%s', 'now')
            """,
          arguments: [
            accountID, stableID, priority.day, priority.rank, priority.text, priority.status,
          ]
        )
        try Self.recordProjectedMapping(
          stableID: stableID,
          accountID: accountID,
          recordKind: "priority",
          localRecordID: nil,
          db: db
        )
      }

      for (stableID, reflection) in projection.reflections {
        // Reflections are also represented in the Mac journal read model so
        // the existing Journal view immediately reflects a mobile edit.
        try db.execute(
          sql: """
            INSERT INTO journal_entries(day, reflections, status, updated_at)
            VALUES (?, ?, 'draft', CURRENT_TIMESTAMP)
            ON CONFLICT(day) DO UPDATE SET
              reflections = excluded.reflections,
              updated_at = CURRENT_TIMESTAMP
            """,
          arguments: [reflection.day, reflection.body]
        )
        try Self.recordProjectedMapping(
          stableID: stableID,
          accountID: accountID,
          recordKind: "reflection",
          localRecordID: nil,
          db: db
        )
      }

      for (key, value) in projection.settings {
        try db.execute(
          sql: """
            INSERT INTO dayflow_sync_settings_v2(account_id, key, value)
            VALUES (?, ?, ?)
            ON CONFLICT(account_id, key) DO UPDATE SET
              value = excluded.value,
              updated_at = strftime('%s', 'now')
            """,
          arguments: [accountID, key, value]
        )
        if let day = Self.dailyStandupDay(from: key) {
          try Self.upsertProjectedDailyStandup(day: day, payloadJSON: value, db: db)
        }
        try Self.recordProjectedMapping(
          stableID: key,
          accountID: accountID,
          recordKind: "setting",
          localRecordID: nil,
          db: db
        )
      }

      for targetID in projection.tombstones {
        try Self.applyProjectedTombstone(targetID: targetID, accountID: accountID, db: db)
      }

      return DayflowProjectionApplyResult(
        timelineCardCount: timelineCount,
        journalEntryCount: journalCount,
        priorityCount: projection.priorities.count,
        reflectionCount: projection.reflections.count,
        settingCount: projection.settings.count,
        tombstoneCount: projection.tombstones.count
      )
  }

  private static func upsertProjectedTimelineCard(
    _ card: DayflowRustTimelineCard,
    stableID: String,
    accountID: String,
    formatter: DateFormatter,
    db: Database
  ) throws -> Int64 {
    let mappedIDFromTable = try Int64.fetchOne(
      db,
      sql: """
        SELECT local_record_id
        FROM dayflow_sync_projection_records_v2
        WHERE account_id = ? AND stable_id = ?
        """,
      arguments: [accountID, stableID]
    )
    let mappedID: Int64?
    if let mappedIDFromTable {
      mappedID = mappedIDFromTable
    } else {
      mappedID = Self.legacyTimelineRecordID(from: stableID)
    }

    let start = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(card.startTimestamp)))
    let end = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(card.endTimestamp)))

    if let mappedID,
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM timeline_cards WHERE id = ?",
        arguments: [mappedID]
      ) == 1
    {
      try db.execute(
        sql: """
          UPDATE timeline_cards
          SET start = ?, end = ?, start_ts = ?, end_ts = ?, day = ?, title = ?,
              summary = ?, category = ?, subcategory = ?, detailed_summary = ?, is_deleted = 0
          WHERE id = ?
          """,
        arguments: [
          start, end, card.startTimestamp, card.endTimestamp, card.day, card.title,
          card.summary, card.category, card.subcategory, card.detailedSummary, mappedID,
        ]
      )
      return mappedID
    }

    try db.execute(
      sql: """
        INSERT INTO timeline_cards(
          batch_id, start, end, start_ts, end_ts, day, title, summary, category,
          subcategory, detailed_summary, metadata, is_deleted
        ) VALUES (NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0)
        """,
      arguments: [
        start, end, card.startTimestamp, card.endTimestamp, card.day, card.title,
        card.summary, card.category, card.subcategory, card.detailedSummary,
      ]
    )
    return db.lastInsertedRowID
  }

  private static func upsertProjectedJournalEntry(
    _ entry: DayflowRustJournalEntry,
    db: Database
  ) throws -> Int64? {
    let snapshot = try? JSONDecoder().decode(
      DayflowJournalSnapshot.self,
      from: Data(entry.body.utf8)
    )
    let fallbackNotes = snapshot == nil ? entry.body : nil
    let updatedAt = snapshot?.updatedAt.map { Date(timeIntervalSince1970: $0) }

    try db.execute(
      sql: """
        INSERT INTO journal_entries(
          day, intentions, notes, goals, reflections, summary, status, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(day) DO UPDATE SET
          intentions = excluded.intentions,
          notes = excluded.notes,
          goals = excluded.goals,
          reflections = excluded.reflections,
          summary = excluded.summary,
          status = excluded.status,
          updated_at = excluded.updated_at
        """,
      arguments: [
        entry.day,
        snapshot?.intentions,
        snapshot?.notes ?? fallbackNotes,
        snapshot?.goals,
        snapshot?.reflections,
        snapshot?.summary,
        snapshot?.status ?? "draft",
        updatedAt ?? Date(),
      ]
    )

    return try Int64.fetchOne(
      db,
      sql: "SELECT id FROM journal_entries WHERE day = ?",
      arguments: [entry.day]
    )
  }

  private static func recordProjectedMapping(
    stableID: String,
    accountID: String,
    recordKind: String,
    localRecordID: Int64?,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO dayflow_sync_projection_records_v2(account_id, stable_id, record_kind, local_record_id)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(account_id, stable_id) DO UPDATE SET
          record_kind = excluded.record_kind,
          local_record_id = excluded.local_record_id,
          updated_at = strftime('%s', 'now')
        """,
      arguments: [accountID, stableID, recordKind, localRecordID]
    )
  }

  private static func upsertProjectedDailyStandup(
    day: String,
    payloadJSON: String,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO daily_standup_entries(standup_day, payload_json, updated_at)
        VALUES (?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(standup_day) DO UPDATE SET
          payload_json = excluded.payload_json,
          updated_at = CURRENT_TIMESTAMP
        """,
      arguments: [day, payloadJSON]
    )
  }

  private static func deleteProjectedSetting(key: String, accountID: String, db: Database) throws {
    try db.execute(
      sql: "DELETE FROM dayflow_sync_settings_v2 WHERE account_id = ? AND key = ?",
      arguments: [accountID, key]
    )
    if let day = Self.dailyStandupDay(from: key) {
      try db.execute(
        sql: "DELETE FROM daily_standup_entries WHERE standup_day = ?",
        arguments: [day]
      )
    }
  }

  private static func applyProjectedTombstone(targetID: String, accountID: String, db: Database) throws {
    if let mapping = try Row.fetchOne(
      db,
      sql: """
        SELECT record_kind, local_record_id
        FROM dayflow_sync_projection_records_v2
        WHERE account_id = ? AND stable_id = ?
        """,
      arguments: [accountID, targetID]
    ) {
      let kind: String = mapping["record_kind"]
      let localID: Int64? = mapping["local_record_id"]
      if kind == "timeline_card", let localID {
        try db.execute(
          sql: "UPDATE timeline_cards SET is_deleted = 1 WHERE id = ?",
          arguments: [localID]
        )
      } else if kind == "journal", let localID {
        try db.execute(sql: "DELETE FROM journal_entries WHERE id = ?", arguments: [localID])
      } else if kind == "priority" {
        try db.execute(
          sql: "DELETE FROM dayflow_sync_priorities_v2 WHERE account_id = ? AND stable_id = ?",
          arguments: [accountID, targetID]
        )
      } else if kind == "reflection", targetID.hasPrefix("mac:v1:reflection:") {
        let day = String(targetID.dropFirst("mac:v1:reflection:".count))
        try db.execute(
          sql: "UPDATE journal_entries SET reflections = NULL, updated_at = CURRENT_TIMESTAMP WHERE day = ?",
          arguments: [day]
        )
      } else if kind == "setting" {
        try Self.deleteProjectedSetting(key: targetID, accountID: accountID, db: db)
      }
      return
    }

    if let recordID = Self.legacyTimelineRecordID(from: targetID) {
      try db.execute(
        sql: "UPDATE timeline_cards SET is_deleted = 1 WHERE id = ?",
        arguments: [recordID]
      )
    } else if targetID.hasPrefix("mac:v1:journal:") {
      let day = String(targetID.dropFirst("mac:v1:journal:".count))
      try db.execute(sql: "DELETE FROM journal_entries WHERE day = ?", arguments: [day])
    } else if targetID.hasPrefix("dayflow:v1:priority:") || targetID.hasPrefix("mac:v1:priority:") {
      try db.execute(
        sql: "DELETE FROM dayflow_sync_priorities_v2 WHERE account_id = ? AND stable_id = ?",
        arguments: [accountID, targetID]
      )
    } else if targetID.hasPrefix("mac:v1:reflection:") {
      let day = String(targetID.dropFirst("mac:v1:reflection:".count))
      try db.execute(
        sql: "UPDATE journal_entries SET reflections = NULL, updated_at = CURRENT_TIMESTAMP WHERE day = ?",
        arguments: [day]
      )
    } else {
      try Self.deleteProjectedSetting(key: targetID, accountID: accountID, db: db)
    }
  }

  private static func legacyTimelineRecordID(from stableID: String) -> Int64? {
    let prefix = "mac:v1:timeline_card:"
    guard stableID.hasPrefix(prefix) else { return nil }
    return Int64(stableID.dropFirst(prefix.count))
  }

  private static func dailyStandupDay(from key: String) -> String? {
    let prefix = "daily_standup:"
    guard key.hasPrefix(prefix) else { return nil }
    let day = String(key.dropFirst(prefix.count))
    return day.isEmpty ? nil : day
  }
}
