using System.Text.Json;

namespace Dayflow.Windows.Core;

public sealed record DayflowWindowsChatContextItem(
    string Id,
    string Kind,
    string Day,
    string Content);

public sealed record DayflowWindowsTimelineCard(
    string Id,
    string Day,
    long StartTimestamp,
    long EndTimestamp,
    string Title,
    string Summary,
    string Category,
    string Subcategory,
    string DetailedSummary,
    string Source,
    string DerivationMode);

public sealed record DayflowWindowsJournalEntry(
    string Id,
    string Day,
    string Body);

public sealed record DayflowWindowsPriority(
    string Id,
    string Day,
    int Rank,
    string Text,
    string Status);

public sealed record DayflowWindowsReflection(
    string Id,
    string Day,
    string Body);

public sealed record DayflowWindowsProjection(
    IReadOnlyDictionary<string, DayflowWindowsTimelineCard> TimelineCards,
    IReadOnlyDictionary<string, DayflowWindowsJournalEntry> JournalEntries,
    IReadOnlyDictionary<string, DayflowWindowsPriority> Priorities,
    IReadOnlyDictionary<string, DayflowWindowsReflection> Reflections,
    IReadOnlyDictionary<string, string> Settings,
    IReadOnlyList<DayflowWindowsChatContextItem> ChatContext)
{
    public int TimelineCardCount => TimelineCards.Count;
    public int JournalEntryCount => JournalEntries.Count;
    public int PriorityCount => Priorities.Count;
    public int ReflectionCount => Reflections.Count;

    public static DayflowWindowsProjection Empty { get; } = new(
        new Dictionary<string, DayflowWindowsTimelineCard>(),
        new Dictionary<string, DayflowWindowsJournalEntry>(),
        new Dictionary<string, DayflowWindowsPriority>(),
        new Dictionary<string, DayflowWindowsReflection>(),
        new Dictionary<string, string>(),
        Array.Empty<DayflowWindowsChatContextItem>());

    public static DayflowWindowsProjection FromJson(string value)
    {
        using var document = JsonDocument.Parse(value);
        var root = document.RootElement;
        var timelineCards = ParseObject(root, "timeline_cards", static (key, item) =>
            new DayflowWindowsTimelineCard(
                StringProperty(item, "id", key),
                StringProperty(item, "day"),
                LongProperty(item, "start_timestamp"),
                LongProperty(item, "end_timestamp"),
                StringProperty(item, "title"),
                StringProperty(item, "summary"),
                StringProperty(item, "category"),
                StringProperty(item, "subcategory"),
                StringProperty(item, "detailed_summary"),
                StringProperty(item, "source"),
                StringProperty(item, "derivation_mode")));
        var journalEntries = ParseObject(root, "journal_entries", static (key, item) =>
            new DayflowWindowsJournalEntry(
                StringProperty(item, "id", key),
                StringProperty(item, "day"),
                StringProperty(item, "body")));
        var priorityRecords = ParseObject(root, "priorities", static (key, item) =>
            new DayflowWindowsPriority(
                StringProperty(item, "id", key),
                StringProperty(item, "day"),
                IntProperty(item, "rank"),
                StringProperty(item, "text"),
                StringProperty(item, "status")));
        var reflectionRecords = ParseObject(root, "reflections", static (key, item) =>
            new DayflowWindowsReflection(
                StringProperty(item, "id", key),
                StringProperty(item, "day"),
                StringProperty(item, "body")));
        var settings = new Dictionary<string, string>();
        if (root.TryGetProperty("settings", out var settingsValue)
            && settingsValue.ValueKind == JsonValueKind.Object)
        {
            foreach (var item in settingsValue.EnumerateObject())
                settings[item.Name] = item.Value.GetString() ?? "";
        }
        var context = new List<DayflowWindowsChatContextItem>();
        if (root.TryGetProperty("chat_context", out var contextValue)
            && contextValue.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in contextValue.EnumerateArray())
            {
                context.Add(new DayflowWindowsChatContextItem(
                    item.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "",
                    item.TryGetProperty("kind", out var kind) ? kind.GetString() ?? "" : "",
                    item.TryGetProperty("day", out var day) ? day.GetString() ?? "" : "",
                    item.TryGetProperty("content", out var content) ? content.GetString() ?? "" : ""));
            }
        }
        return new(timelineCards, journalEntries, priorityRecords, reflectionRecords, settings, context);
    }

    private static Dictionary<string, T> ParseObject<T>(
        JsonElement root,
        string property,
        Func<string, JsonElement, T> parse)
    {
        var result = new Dictionary<string, T>();
        if (!root.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.Object)
            return result;
        foreach (var item in value.EnumerateObject())
            result[item.Name] = parse(item.Name, item.Value);
        return result;
    }

    private static string StringProperty(JsonElement value, string property, string fallback = "") =>
        value.TryGetProperty(property, out var item) && item.ValueKind == JsonValueKind.String
            ? item.GetString() ?? fallback
            : fallback;

    private static long LongProperty(JsonElement value, string property) =>
        value.TryGetProperty(property, out var item) && item.TryGetInt64(out var result) ? result : 0L;

    private static int IntProperty(JsonElement value, string property) =>
        value.TryGetProperty(property, out var item) && item.TryGetInt32(out var result) ? result : 0;
}
