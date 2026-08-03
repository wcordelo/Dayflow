using System.Text.Json.Serialization;

namespace Dayflow.Windows.Core;

public sealed record DayflowEventEnvelope(
    [property: JsonPropertyName("event_id")] string EventId,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("logical_clock")] ulong LogicalClock,
    [property: JsonPropertyName("schema_version")] ushort SchemaVersion,
    [property: JsonPropertyName("key_version")] uint KeyVersion,
    [property: JsonPropertyName("nonce")] string Nonce,
    [property: JsonPropertyName("ciphertext")] string Ciphertext)
{
    public const ushort CurrentSchemaVersion = 1;
    public const ulong MaxLogicalClock = 9_007_199_254_740_991;

    public static bool HasValidEncryptedFieldShape(string nonce, string ciphertext)
    {
        return TryDecodeWireBase64(nonce, out var nonceBytes)
            && TryDecodeWireBase64(ciphertext, out var ciphertextBytes)
            && nonceBytes.Length == 24
            && ciphertextBytes.Length >= 16;
    }

    private static bool TryDecodeWireBase64(string value, out byte[] bytes)
    {
        bytes = Array.Empty<byte>();
        if (string.IsNullOrEmpty(value)) return false;

        foreach (var character in value)
        {
            if (!((character >= 'A' && character <= 'Z')
                || (character >= 'a' && character <= 'z')
                || (character >= '0' && character <= '9')
                || character is '+' or '/' or '-' or '_' or '='))
            {
                return false;
            }
        }

        var firstPadding = value.IndexOf('=');
        if (firstPadding >= 0)
        {
            if (value.Length % 4 != 0 || firstPadding < value.Length - 2) return false;
            for (var index = firstPadding; index < value.Length; index++)
            {
                if (value[index] != '=') return false;
            }
        }

        var unpadded = firstPadding >= 0 ? value[..firstPadding] : value;
        if (unpadded.Length % 4 == 1) return false;
        var normalized = unpadded.Replace('-', '+').Replace('_', '/');
        normalized += new string('=', (4 - normalized.Length % 4) % 4);
        try
        {
            bytes = Convert.FromBase64String(normalized);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
