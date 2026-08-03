namespace Dayflow.Windows.Core;

/// <summary>
/// Platform-neutral capture policy helpers shared by the WinUI adapter and
/// the C-ABI smoke-test project. The adapter remains responsible for system
/// permissions and frame lifecycle; this parser is deliberately testable
/// without a window or GPU.
/// </summary>
public static class DayflowWindowsCapturePolicy
{
    public static bool SharedCapturePauseEnabled(string? value)
    {
        if (value is null) return false;

        return value.Trim().ToLowerInvariant() switch
        {
            "false" => false,
            "true" => true,
            _ => true,
        };
    }

    /// <summary>
    /// Builds the safe fallback card used when the frame pipeline has not run a
    /// local visual model. Window titles are intentionally not accepted here:
    /// they commonly contain document names, meeting subjects, or message
    /// previews and should not become synced metadata by accident.
    /// </summary>
    public static (string Title, string Summary) MetadataOnlyDescription(string? applicationId)
    {
        var application = NormalizeApplicationId(applicationId);
        if (application is null)
        {
            return (
                "Activity observed locally",
                "Dayflow recorded a privacy-approved local activity sample. Raw pixels were released before event creation.");
        }

        return (
            $"Activity in {application}",
            $"Dayflow recorded a privacy-approved local activity sample from {application}. Raw pixels were released before event creation.");
    }

    private static string? NormalizeApplicationId(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var normalized = string.Concat(value.Where(character => !char.IsControl(character))).Trim();
        return normalized.Length == 0 ? null : normalized[..Math.Min(normalized.Length, 160)];
    }
}
