using Microsoft.Data.Sqlite;
using System.Globalization;

namespace Dayflow.Windows.Core;

public enum DayflowWindowsSyncHealthState
{
    Unknown,
    Synced,
    WaitingForApproval,
    Failed,
}

public sealed record DayflowWindowsSyncHealth(
    DateTimeOffset? LastSyncAt,
    DateTimeOffset? LastSuccessfulSyncAt,
    DayflowWindowsSyncHealthState State,
    string? FailureCode)
{
    public static DayflowWindowsSyncHealth Initial => new(null, null, DayflowWindowsSyncHealthState.Unknown, null);

    public string Summary(int pendingEventCount, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        var parts = new List<string>();
        switch (State)
        {
            case DayflowWindowsSyncHealthState.Synced:
                var date = LastSuccessfulSyncAt ?? LastSyncAt;
                parts.Add(date is null ? "Synced locally" : $"Last synced {RelativeTime(date.Value, current)}");
                break;
            case DayflowWindowsSyncHealthState.WaitingForApproval:
                parts.Add("Waiting for device approval");
                break;
            case DayflowWindowsSyncHealthState.Failed:
                parts.Add("Last sync failed");
                break;
            default:
                parts.Add("Not synced yet");
                break;
        }
        if (pendingEventCount > 0)
            parts.Add($"{pendingEventCount} encrypted event{(pendingEventCount == 1 ? "" : "s")} queued");
        else if (State == DayflowWindowsSyncHealthState.Synced)
            parts.Add("No events queued");
        if (State == DayflowWindowsSyncHealthState.Failed && !string.IsNullOrWhiteSpace(FailureCode))
            parts.Add($"Reason: {FailureCode!.Replace('_', ' ')}");
        return string.Join(" · ", parts);
    }

    private static string RelativeTime(DateTimeOffset timestamp, DateTimeOffset now)
    {
        var seconds = Math.Max(0, (long)(now - timestamp).TotalSeconds);
        return seconds switch
        {
            < 60 => "just now",
            < 3_600 => $"{seconds / 60}m ago",
            < 86_400 => $"{seconds / 3_600}h ago",
            _ => $"{seconds / 86_400}d ago",
        };
    }
}

/// <summary>
/// SQLite-backed Windows outbox. Event payloads are already sealed by the Rust
/// core; this store persists only envelope metadata, opaque ciphertext, and
/// non-sensitive sync metadata. Projections are rebuilt in memory.
/// </summary>
public sealed class DayflowLocalSyncStore : IDisposable
{
    private readonly SqliteConnection _connection;

    public DayflowLocalSyncStore(string databasePath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(databasePath) ?? throw new ArgumentException("Database path must have a directory."));
        _connection = new SqliteConnection($"Data Source={databasePath}");
        _connection.Open();
        Execute("""
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
            CREATE INDEX IF NOT EXISTS idx_event_state ON event_envelopes(state, logical_clock);
            CREATE TABLE IF NOT EXISTS sync_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
            """);
        Execute("DELETE FROM sync_metadata WHERE key = 'projection_json';");
    }

    public void Enqueue(DayflowEventEnvelope envelope)
    {
        Validate(envelope);
        // Keep the immutable-ID preflight and INSERT atomic for concurrent
        // capture, journal, and foreground-sync writers.
        using var transaction = _connection.BeginTransaction();
        RejectConflictingEnvelope(envelope, transaction);
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT OR IGNORE INTO event_envelopes
            (event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext, state)
            VALUES ($event_id, $device_id, $logical_clock, $schema_version, $key_version, $nonce, $ciphertext, 'pending');
            """;
        AddParameters(command, envelope);
        command.ExecuteNonQuery();
        transaction.Commit();
    }

    public IReadOnlyList<DayflowEventEnvelope> Pending(int limit = 100) => Query(
        "SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext FROM event_envelopes WHERE state = 'pending' ORDER BY logical_clock, device_id, event_id LIMIT $limit",
        ("$limit", Math.Clamp(limit, 1, 1000)));

    public int PendingCount()
    {
        using var command = _connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM event_envelopes WHERE state = 'pending'";
        return Convert.ToInt32(command.ExecuteScalar());
    }

    public int Acknowledge(IEnumerable<string> eventIds)
    {
        using var transaction = _connection.BeginTransaction();
        var count = 0;
        foreach (var eventId in eventIds)
        {
            using var command = _connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = "UPDATE event_envelopes SET state = 'acknowledged' WHERE event_id = $event_id";
            command.Parameters.AddWithValue("$event_id", eventId);
            count += command.ExecuteNonQuery();
        }
        transaction.Commit();
        return count;
    }

    public int Merge(IEnumerable<DayflowEventEnvelope> envelopes)
    {
        using var transaction = _connection.BeginTransaction();
        var count = 0;
        ulong maximumRemoteClock = 0;
        foreach (var envelope in envelopes)
        {
            Validate(envelope);
            RejectConflictingEnvelope(envelope, transaction);
            maximumRemoteClock = Math.Max(maximumRemoteClock, envelope.LogicalClock);
            using var command = _connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                INSERT OR IGNORE INTO event_envelopes
                (event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext, state)
                VALUES ($event_id, $device_id, $logical_clock, $schema_version, $key_version, $nonce, $ciphertext, 'acknowledged');
                """;
            AddParameters(command, envelope);
            count += command.ExecuteNonQuery();
        }
        // Advance the device-local Lamport clock in the same transaction as
        // the event merge. A failed/conflicting batch must not advance it.
        if (maximumRemoteClock > 0)
        {
            using var read = _connection.CreateCommand();
            read.Transaction = transaction;
            read.CommandText = "SELECT value FROM sync_metadata WHERE key = 'logical_clock'";
            var currentValue = read.ExecuteScalar();
            var current = currentValue is null || currentValue is DBNull ? 0L : Convert.ToInt64(currentValue);
            if (current < checked((long)maximumRemoteClock))
            {
                using var write = _connection.CreateCommand();
                write.Transaction = transaction;
                write.CommandText = "INSERT INTO sync_metadata(key, value) VALUES ('logical_clock', $value) ON CONFLICT(key) DO UPDATE SET value = excluded.value";
                write.Parameters.AddWithValue("$value", maximumRemoteClock.ToString());
                write.ExecuteNonQuery();
            }
        }
        transaction.Commit();
        return count;
    }

    public IReadOnlyList<DayflowEventEnvelope> All() => Query(
        "SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext FROM event_envelopes ORDER BY logical_clock, device_id, event_id");

    public DayflowEventEnvelope? Find(string eventId)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = "SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext FROM event_envelopes WHERE event_id = $event_id LIMIT 1";
        command.Parameters.AddWithValue("$event_id", eventId);
        using var reader = command.ExecuteReader();
        if (!reader.Read()) return null;
        return new DayflowEventEnvelope(
            reader.GetString(0),
            reader.GetString(1),
            checked((ulong)reader.GetInt64(2)),
            checked((ushort)reader.GetInt32(3)),
            checked((uint)reader.GetInt64(4)),
            reader.GetString(5),
            reader.GetString(6));
    }

    public string? Cursor() => Metadata("relay_cursor");

    public void SetCursor(string value) => SetMetadata("relay_cursor", value);

    /// Notification hints have a cursor separate from encrypted event replay.
    public string? NotificationCursor() => Metadata("notification_cursor");

    public void SetNotificationCursor(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) throw new ArgumentException("Notification cursor cannot be empty.", nameof(value));
        SetMetadata("notification_cursor", value);
    }

    public string? LinkedAccountId() => Metadata("linked_account_id");

    public void SetLinkedAccountId(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) throw new ArgumentException("Linked account ID cannot be empty.", nameof(value));
        SetMetadata("linked_account_id", value);
    }

    public DayflowWindowsSyncHealth SyncHealth() => new(
        ParseUnixSeconds(Metadata("last_sync_at")),
        ParseUnixSeconds(Metadata("last_successful_sync_at")),
        ParseState(Metadata("last_sync_state")),
        Metadata("last_sync_failure"));

    /// Persists only bounded sync metadata; event content and raw errors never
    /// enter this table.
    public void RecordSyncHealth(
        DayflowWindowsSyncHealthState state,
        string? failureCode = null,
        DateTimeOffset? at = null)
    {
        var timestamp = (at ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
        using var transaction = _connection.BeginTransaction();
        SetMetadata("last_sync_at", timestamp, transaction);
        SetMetadata("last_sync_state", RawState(state), transaction);
        if (state == DayflowWindowsSyncHealthState.Synced)
        {
            SetMetadata("last_successful_sync_at", timestamp, transaction);
            DeleteMetadata("last_sync_failure", transaction);
        }
        else if (state == DayflowWindowsSyncHealthState.Failed)
        {
            SetMetadata("last_sync_failure", BoundedFailureCode(failureCode), transaction);
        }
        transaction.Commit();
    }

    /// <summary>
    /// Seeds a destination workspace clock after local-workspace linking. The
    /// local and account databases share one physical device identity, so the
    /// destination must not allocate a value already used by the source.
    /// </summary>
    public void EnsureLogicalClockAtLeast(ulong value)
    {
        if (value > DayflowEventEnvelope.MaxLogicalClock) throw new ArgumentOutOfRangeException(nameof(value));
        using var transaction = _connection.BeginTransaction();
        using var read = _connection.CreateCommand();
        read.Transaction = transaction;
        read.CommandText = "SELECT value FROM sync_metadata WHERE key = 'logical_clock'";
        var currentValue = read.ExecuteScalar();
        var current = currentValue is null || currentValue is DBNull ? 0L : Convert.ToInt64(currentValue);
        if (current < (long)value)
        {
            using var write = _connection.CreateCommand();
            write.Transaction = transaction;
            write.CommandText = "INSERT INTO sync_metadata(key, value) VALUES ('logical_clock', $value) ON CONFLICT(key) DO UPDATE SET value = excluded.value";
            write.Parameters.AddWithValue("$value", value.ToString());
            write.ExecuteNonQuery();
        }
        transaction.Commit();
    }

    public ulong NextLogicalClock()
    {
        using var transaction = _connection.BeginTransaction();
        using var read = _connection.CreateCommand();
        read.Transaction = transaction;
        read.CommandText = "SELECT value FROM sync_metadata WHERE key = 'logical_clock'";
        var currentValue = read.ExecuteScalar();
        var current = currentValue is null || currentValue is DBNull ? 0L : Convert.ToInt64(currentValue);
        if (current >= (long)DayflowEventEnvelope.MaxLogicalClock) throw new InvalidOperationException("The local logical clock is exhausted.");
        var next = checked(current + 1);
        using var write = _connection.CreateCommand();
        write.Transaction = transaction;
        write.CommandText = "INSERT INTO sync_metadata(key, value) VALUES ('logical_clock', $value) ON CONFLICT(key) DO UPDATE SET value = excluded.value";
        write.Parameters.AddWithValue("$value", next.ToString());
        write.ExecuteNonQuery();
        transaction.Commit();
        return checked((ulong)next);
    }

    public void Dispose() => _connection.Dispose();

    private IReadOnlyList<DayflowEventEnvelope> Query(string sql, params (string Name, object Value)[] parameters)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = sql;
        foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
        using var reader = command.ExecuteReader();
        var result = new List<DayflowEventEnvelope>();
        while (reader.Read())
        {
            result.Add(new DayflowEventEnvelope(
                reader.GetString(0),
                reader.GetString(1),
                checked((ulong)reader.GetInt64(2)),
                checked((ushort)reader.GetInt32(3)),
                checked((uint)reader.GetInt64(4)),
                reader.GetString(5),
                reader.GetString(6)));
        }
        return result;
    }

    private string? Metadata(string key)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = "SELECT value FROM sync_metadata WHERE key = $key";
        command.Parameters.AddWithValue("$key", key);
        return command.ExecuteScalar() as string;
    }

    private void SetMetadata(string key, string value, SqliteTransaction? transaction = null)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "INSERT INTO sync_metadata(key, value) VALUES ($key, $value) ON CONFLICT(key) DO UPDATE SET value = excluded.value";
        command.Parameters.AddWithValue("$key", key);
        command.Parameters.AddWithValue("$value", value);
        command.ExecuteNonQuery();
    }

    private void DeleteMetadata(string key, SqliteTransaction? transaction = null)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "DELETE FROM sync_metadata WHERE key = $key";
        command.Parameters.AddWithValue("$key", key);
        command.ExecuteNonQuery();
    }

    private static DateTimeOffset? ParseUnixSeconds(string? value)
    {
        if (!long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds)) return null;
        try { return DateTimeOffset.FromUnixTimeSeconds(seconds); }
        catch (ArgumentOutOfRangeException) { return null; }
    }

    private static DayflowWindowsSyncHealthState ParseState(string? value) => value switch
    {
        "synced" => DayflowWindowsSyncHealthState.Synced,
        "waiting_for_approval" => DayflowWindowsSyncHealthState.WaitingForApproval,
        "failed" => DayflowWindowsSyncHealthState.Failed,
        _ => DayflowWindowsSyncHealthState.Unknown,
    };

    private static string RawState(DayflowWindowsSyncHealthState state) => state switch
    {
        DayflowWindowsSyncHealthState.Synced => "synced",
        DayflowWindowsSyncHealthState.WaitingForApproval => "waiting_for_approval",
        DayflowWindowsSyncHealthState.Failed => "failed",
        _ => "unknown",
    };

    private static string BoundedFailureCode(string? value)
    {
        var normalized = new string((value ?? "")
            .ToLowerInvariant()
            .Where(character => char.IsLetterOrDigit(character) || character is '_' or '-')
            .Take(48)
            .ToArray());
        return string.IsNullOrEmpty(normalized) ? "unknown" : normalized;
    }

    private static void AddParameters(SqliteCommand command, DayflowEventEnvelope envelope)
    {
        command.Parameters.AddWithValue("$event_id", envelope.EventId);
        command.Parameters.AddWithValue("$device_id", envelope.DeviceId);
        command.Parameters.AddWithValue("$logical_clock", checked((long)envelope.LogicalClock));
        command.Parameters.AddWithValue("$schema_version", envelope.SchemaVersion);
        command.Parameters.AddWithValue("$key_version", envelope.KeyVersion);
        command.Parameters.AddWithValue("$nonce", envelope.Nonce);
        command.Parameters.AddWithValue("$ciphertext", envelope.Ciphertext);
    }

    private static void Validate(DayflowEventEnvelope envelope)
    {
        if (string.IsNullOrWhiteSpace(envelope.EventId)
            || string.IsNullOrWhiteSpace(envelope.DeviceId)
            || envelope.LogicalClock == 0
            || envelope.SchemaVersion != DayflowEventEnvelope.CurrentSchemaVersion
            || !DayflowEventEnvelope.HasValidEncryptedFieldShape(envelope.Nonce, envelope.Ciphertext))
        {
            throw new ArgumentException("The event envelope is incomplete.", nameof(envelope));
        }
        if (envelope.LogicalClock > DayflowEventEnvelope.MaxLogicalClock)
            throw new ArgumentOutOfRangeException(nameof(envelope), "The logical clock exceeds the JSON relay's safe integer range.");
        if (envelope.KeyVersion == 0)
            throw new ArgumentOutOfRangeException(nameof(envelope), "The event key version must be positive.");
    }

    private void RejectConflictingEnvelope(DayflowEventEnvelope envelope, SqliteTransaction? transaction = null)
    {
        using var command = _connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT event_id, device_id, logical_clock, schema_version, key_version, nonce, ciphertext
            FROM event_envelopes WHERE event_id = $event_id
            """;
        command.Parameters.AddWithValue("$event_id", envelope.EventId);
        using var reader = command.ExecuteReader();
        if (!reader.Read()) return;

        var existing = new DayflowEventEnvelope(
            reader.GetString(0),
            reader.GetString(1),
            checked((ulong)reader.GetInt64(2)),
            checked((ushort)reader.GetInt32(3)),
            checked((uint)reader.GetInt64(4)),
            reader.GetString(5),
            reader.GetString(6));
        if (!existing.Equals(envelope))
        {
            throw new InvalidOperationException($"Event ID '{envelope.EventId}' already exists with a different envelope.");
        }
    }

    private void Execute(string sql)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }
}
