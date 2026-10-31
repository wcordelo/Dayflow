using System.Text.Json;

namespace Dayflow.Windows.Core;

/// <summary>
/// Local capture exclusions. These settings never enter the encrypted event
/// log or relay; they only decide whether the next frame may be derived.
/// </summary>
public sealed record DayflowWindowsPrivacyPreferences(
    IReadOnlyList<string> BlockedApplicationIds,
    IReadOnlyList<string> BlockedWindowTitleFragments)
{
    public static DayflowWindowsPrivacyPreferences Empty { get; } = new(
        Array.Empty<string>(),
        Array.Empty<string>());

    public static DayflowWindowsPrivacyPreferences Load()
    {
        try
        {
            if (!File.Exists(DayflowWindowsStorage.PrivacyPreferencesPath))
                return Empty;
            var json = File.ReadAllText(DayflowWindowsStorage.PrivacyPreferencesPath);
            return JsonSerializer.Deserialize<DayflowWindowsPrivacyPreferences>(json) ?? Empty;
        }
        catch (Exception)
        {
            // Privacy settings fail closed at the capture decision boundary.
            // A corrupt preferences file should not make the app unusable.
            return Empty;
        }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(DayflowWindowsStorage.PrivacyPreferencesPath)!);
        var tempPath = $"{DayflowWindowsStorage.PrivacyPreferencesPath}.{Guid.NewGuid():N}.tmp";
        File.WriteAllText(
            tempPath,
            JsonSerializer.Serialize(
                this,
                new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tempPath, DayflowWindowsStorage.PrivacyPreferencesPath, overwrite: true);
    }
}
