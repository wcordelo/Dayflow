using System.Text.Json;

namespace Dayflow.Windows.Core;

/// <summary>
/// DPAPI-protected local representation of every account key version needed to
/// replay encrypted events after rotation. The JSON wire shape matches the
/// Rust core and contains no relay metadata.
/// </summary>
public sealed class DayflowWindowsAccountKeyRing
{
    private readonly Dictionary<uint, byte[]> _keys;

    private DayflowWindowsAccountKeyRing(uint activeKeyVersion, Dictionary<uint, byte[]> keys)
    {
        if (activeKeyVersion == 0 || keys.Count == 0 || !keys.ContainsKey(activeKeyVersion)
            || keys.Keys.Any(version => version == 0)
            || keys.Values.Any(key => key.Length != 32))
        {
            throw new ArgumentException("The account key-ring is invalid.");
        }

        ActiveKeyVersion = activeKeyVersion;
        _keys = keys.ToDictionary(entry => entry.Key, entry => entry.Value.ToArray());
    }

    public uint ActiveKeyVersion { get; }

    public static DayflowWindowsAccountKeyRing FromRootKey(ReadOnlySpan<byte> rootKey) =>
        FromSingleVersion(1, rootKey);

    public static DayflowWindowsAccountKeyRing FromSingleVersion(uint version, ReadOnlySpan<byte> key)
    {
        if (key.Length != 32 || version == 0) throw new ArgumentException("A versioned account key must be 32 bytes.");
        return new(version, new Dictionary<uint, byte[]> { [version] = key.ToArray() });
    }

    public static DayflowWindowsAccountKeyRing FromJson(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var active = root.GetProperty("active_key_version").GetUInt32();
        var keysElement = root.GetProperty("keys");
        var keys = new Dictionary<uint, byte[]>();
        foreach (var property in keysElement.EnumerateObject())
        {
            keys[uint.Parse(property.Name)] = Convert.FromBase64String(property.Value.GetString()!);
        }
        return new(active, keys);
    }

    public byte[]? KeyData(uint version) =>
        _keys.TryGetValue(version, out var key) ? key.ToArray() : null;

    public IReadOnlyList<uint> Versions() => _keys.Keys.OrderBy(version => version).ToArray();

    public DayflowWindowsAccountKeyRing Add(byte[] key, uint version, bool active = false)
    {
        if (key.Length != 32 || version == 0) throw new ArgumentException("A versioned account key must be 32 bytes.");
        var keys = _keys.ToDictionary(entry => entry.Key, entry => entry.Value.ToArray());
        keys[version] = key.ToArray();
        return new(active ? version : ActiveKeyVersion, keys);
    }

    public string ToJson()
    {
        var keys = _keys.ToDictionary(
            entry => entry.Key.ToString(),
            entry => Convert.ToBase64String(entry.Value));
        return JsonSerializer.Serialize(new
        {
            active_key_version = ActiveKeyVersion,
            keys,
        });
    }
}
