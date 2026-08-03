import Foundation

/// Encodes the portable event payloads shared by Mac migration and live local
/// edits. The resulting JSON is sealed by Rust before it enters GRDB.
enum DayflowEventPayloadEncoder {
  static func timelineCardPayload(
    card: TimelineCardWithTimestamps,
    logicalDay: String? = nil
  ) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "kind": "TimelineCardUpsert",
        "value": [
          "id": "mac:v1:timeline_card:\(card.id)",
          "day": logicalDay ?? card.day,
          "start_timestamp": card.startTs,
          "end_timestamp": card.endTs,
          "title": card.title,
          "summary": card.summary,
          "category": card.category,
          "subcategory": card.subcategory,
          "detailed_summary": card.detailedSummary,
          "source": "mac_screen_capture",
          "derivation_mode": "local_ai_derived",
        ],
      ],
      options: [.sortedKeys]
    )
  }

  static func journalPayload(entry: JournalEntry) throws -> Data {
    let body = try JSONSerialization.data(
      withJSONObject: [
        "day": entry.day,
        "intentions": entry.intentions as Any? ?? NSNull(),
        "notes": entry.notes as Any? ?? NSNull(),
        "goals": entry.goals as Any? ?? NSNull(),
        "reflections": entry.reflections as Any? ?? NSNull(),
        "summary": entry.summary as Any? ?? NSNull(),
        "status": entry.status,
        "updated_at": entry.updatedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
      ],
      options: [.sortedKeys]
    )
    guard let bodyString = String(data: body, encoding: .utf8) else {
      throw DayflowCoreBridgeError.coreFailure("journal snapshot is not UTF-8")
    }

    return try JSONSerialization.data(
      withJSONObject: [
        "kind": "JournalUpsert",
        "value": [
          "id": "mac:v1:journal:\(entry.day)",
          "day": entry.day,
          "body": bodyString,
        ],
      ],
      options: [.sortedKeys]
    )
  }

  static func reflectionPayload(day: String, body: String) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "kind": "ReflectionUpsert",
        "value": [
          "id": "mac:v1:reflection:\(day)",
          "day": day,
          "body": body,
        ],
      ],
      options: [.sortedKeys]
    )
  }

  static func priorityPayload(
    id: String,
    day: String,
    rank: Int,
    text: String,
    status: String = "open"
  ) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "kind": "PriorityUpsert",
        "value": [
          "id": id,
          "day": day,
          "rank": rank,
          "text": text,
          "status": status,
        ],
      ],
      options: [.sortedKeys]
    )
  }

  static func settingPayload(key: String, value: String) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "kind": "SettingUpsert",
        "value": ["key": key, "value": value],
      ],
      options: [.sortedKeys]
    )
  }

  static func dayGoalValue(_ plan: DayGoalPlan) throws -> String {
    let object: [String: Any] = [
      "day": plan.day,
      "focus_target_minutes": plan.focusTargetMinutes,
      "distraction_limit_minutes": plan.distractionLimitMinutes,
      "is_skipped": plan.isSkipped,
      "created_at": plan.createdAt,
      "updated_at": plan.updatedAt,
      "focus_categories": plan.focusCategories.map { snapshot in
        [
          "category_id": snapshot.categoryID,
          "name": snapshot.name,
          "color_hex": snapshot.colorHex,
          "sort_order": snapshot.sortOrder,
        ]
      },
      "distraction_categories": plan.distractionCategories.map { snapshot in
        [
          "category_id": snapshot.categoryID,
          "name": snapshot.name,
          "color_hex": snapshot.colorHex,
          "sort_order": snapshot.sortOrder,
        ]
      },
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let value = String(data: data, encoding: .utf8) else {
      throw DayflowCoreBridgeError.coreFailure("day goal snapshot is not UTF-8")
    }
    return value
  }

  static func tombstonePayload(targetID: String) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "kind": "Tombstone",
        "value": ["target_id": targetID],
      ],
      options: [.sortedKeys]
    )
  }
}
