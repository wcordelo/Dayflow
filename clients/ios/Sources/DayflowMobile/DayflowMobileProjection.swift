import Foundation

public struct DayflowMobileTimelineCard: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let startTimestamp: Int64
    public let endTimestamp: Int64
    public let title: String
    public let summary: String
    public let category: String
    public let subcategory: String
    public let detailedSummary: String
    public let source: String
    public let derivationMode: String

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

    public init(
        id: String,
        day: String,
        startTimestamp: Int64,
        endTimestamp: Int64,
        title: String,
        summary: String,
        category: String,
        subcategory: String = "",
        detailedSummary: String = "",
        source: String = "",
        derivationMode: String = ""
    ) {
        self.id = id
        self.day = day
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.title = title
        self.summary = summary
        self.category = category
        self.subcategory = subcategory
        self.detailedSummary = detailedSummary
        self.source = source
        self.derivationMode = derivationMode
    }

    public init(from decoder: Decoder) throws {
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

public struct DayflowMobileJournalEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let body: String
}

public struct DayflowMobilePriority: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let rank: Int
    public let text: String
    public let status: String
}

public struct DayflowMobileReflection: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let body: String
}

public struct DayflowMobileChatContextItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let day: String
    public let content: String
}

/// The local read model emitted by the Rust projection. It is deliberately
/// decoded only after local authentication; the relay never receives this
/// shape. Missing fields default to empty collections for forward compatibility.
public struct DayflowMobileProjection: Codable, Equatable, Sendable {
    public var timelineCards: [String: DayflowMobileTimelineCard]
    public var journalEntries: [String: DayflowMobileJournalEntry]
    public var priorities: [String: DayflowMobilePriority]
    public var reflections: [String: DayflowMobileReflection]
    public var settings: [String: String]
    public var chatContext: [DayflowMobileChatContextItem]

    public init(
        timelineCards: [String: DayflowMobileTimelineCard] = [:],
        journalEntries: [String: DayflowMobileJournalEntry] = [:],
        priorities: [String: DayflowMobilePriority] = [:],
        reflections: [String: DayflowMobileReflection] = [:],
        settings: [String: String] = [:],
        chatContext: [DayflowMobileChatContextItem] = []
    ) {
        self.timelineCards = timelineCards
        self.journalEntries = journalEntries
        self.priorities = priorities
        self.reflections = reflections
        self.settings = settings
        self.chatContext = chatContext
    }

    enum CodingKeys: String, CodingKey {
        case timelineCards = "timeline_cards"
        case journalEntries = "journal_entries"
        case priorities
        case reflections
        case settings
        case chatContext = "chat_context"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timelineCards = try container.decodeIfPresent([String: DayflowMobileTimelineCard].self, forKey: .timelineCards) ?? [:]
        journalEntries = try container.decodeIfPresent([String: DayflowMobileJournalEntry].self, forKey: .journalEntries) ?? [:]
        priorities = try container.decodeIfPresent([String: DayflowMobilePriority].self, forKey: .priorities) ?? [:]
        reflections = try container.decodeIfPresent([String: DayflowMobileReflection].self, forKey: .reflections) ?? [:]
        settings = try container.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
        chatContext = try container.decodeIfPresent([DayflowMobileChatContextItem].self, forKey: .chatContext) ?? []
    }
}
