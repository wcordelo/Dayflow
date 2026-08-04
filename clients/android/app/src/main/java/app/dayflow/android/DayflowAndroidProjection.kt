package app.dayflow.android

import org.json.JSONObject

data class DayflowAndroidChatContextItem(
    val id: String,
    val kind: String,
    val day: String,
    val content: String,
)

data class DayflowAndroidTimelineCard(
    val id: String,
    val day: String,
    val startTimestamp: Long,
    val endTimestamp: Long,
    val title: String,
    val summary: String,
    val category: String,
    val subcategory: String,
    val detailedSummary: String,
    val source: String,
    val derivationMode: String,
)

data class DayflowAndroidJournalEntry(
    val id: String,
    val day: String,
    val body: String,
)

data class DayflowAndroidPriority(
    val id: String,
    val day: String,
    val rank: Int,
    val text: String,
    val status: String,
)

data class DayflowAndroidReflection(
    val id: String,
    val day: String,
    val body: String,
)

data class DayflowAndroidProjection(
    val timelineCards: Map<String, DayflowAndroidTimelineCard> = emptyMap(),
    val journalEntries: Map<String, DayflowAndroidJournalEntry> = emptyMap(),
    val priorities: Map<String, DayflowAndroidPriority> = emptyMap(),
    val reflections: Map<String, DayflowAndroidReflection> = emptyMap(),
    val settings: Map<String, String> = emptyMap(),
    val chatContext: List<DayflowAndroidChatContextItem> = emptyList(),
) {
    val timelineCardCount: Int get() = timelineCards.size
    val journalEntryCount: Int get() = journalEntries.size
    val priorityCount: Int get() = priorities.size
    val reflectionCount: Int get() = reflections.size

    companion object {
        fun fromJson(value: String): DayflowAndroidProjection {
            val json = JSONObject(value)
            val timelineCards = json.optJSONObject("timeline_cards").timelineCards()
            val journalEntries = json.optJSONObject("journal_entries").journalEntries()
            val priorities = json.optJSONObject("priorities").priorities()
            val reflections = json.optJSONObject("reflections").reflections()
            val settings = json.optJSONObject("settings").stringMap()
            val context = json.optJSONArray("chat_context")
            val items = buildList {
                if (context != null) {
                    for (index in 0 until context.length()) {
                        val item = context.optJSONObject(index) ?: continue
                        add(
                            DayflowAndroidChatContextItem(
                                id = item.optString("id"),
                                kind = item.optString("kind"),
                                day = item.optString("day"),
                                content = item.optString("content"),
                            ),
                        )
                    }
                }
            }
            return DayflowAndroidProjection(
                timelineCards = timelineCards,
                journalEntries = journalEntries,
                priorities = priorities,
                reflections = reflections,
                settings = settings,
                chatContext = items,
            )
        }
    }
}

private fun JSONObject?.stringMap(): Map<String, String> {
    if (this == null) return emptyMap()
    val result = mutableMapOf<String, String>()
    val keys = keys()
    while (keys.hasNext()) {
        val key = keys.next()
        result[key] = optString(key)
    }
    return result
}

private fun JSONObject?.timelineCards(): Map<String, DayflowAndroidTimelineCard> {
    if (this == null) return emptyMap()
    val result = mutableMapOf<String, DayflowAndroidTimelineCard>()
    val keys = keys()
    while (keys.hasNext()) {
        val key = keys.next()
        val item = optJSONObject(key) ?: continue
        result[key] = DayflowAndroidTimelineCard(
            id = item.optString("id", key),
            day = item.optString("day"),
            startTimestamp = item.optLong("start_timestamp"),
            endTimestamp = item.optLong("end_timestamp"),
            title = item.optString("title"),
            summary = item.optString("summary"),
            category = item.optString("category"),
            subcategory = item.optString("subcategory"),
            detailedSummary = item.optString("detailed_summary"),
            source = item.optString("source"),
            derivationMode = item.optString("derivation_mode"),
        )
    }
    return result
}

private fun JSONObject?.journalEntries(): Map<String, DayflowAndroidJournalEntry> {
    if (this == null) return emptyMap()
    val result = mutableMapOf<String, DayflowAndroidJournalEntry>()
    val keys = keys()
    while (keys.hasNext()) {
        val key = keys.next()
        val item = optJSONObject(key) ?: continue
        result[key] = DayflowAndroidJournalEntry(
            id = item.optString("id", key),
            day = item.optString("day"),
            body = item.optString("body"),
        )
    }
    return result
}

private fun JSONObject?.priorities(): Map<String, DayflowAndroidPriority> {
    if (this == null) return emptyMap()
    val result = mutableMapOf<String, DayflowAndroidPriority>()
    val keys = keys()
    while (keys.hasNext()) {
        val key = keys.next()
        val item = optJSONObject(key) ?: continue
        result[key] = DayflowAndroidPriority(
            id = item.optString("id", key),
            day = item.optString("day"),
            rank = item.optInt("rank"),
            text = item.optString("text"),
            status = item.optString("status"),
        )
    }
    return result
}

private fun JSONObject?.reflections(): Map<String, DayflowAndroidReflection> {
    if (this == null) return emptyMap()
    val result = mutableMapOf<String, DayflowAndroidReflection>()
    val keys = keys()
    while (keys.hasNext()) {
        val key = keys.next()
        val item = optJSONObject(key) ?: continue
        result[key] = DayflowAndroidReflection(
            id = item.optString("id", key),
            day = item.optString("day"),
            body = item.optString("body"),
        )
    }
    return result
}
