namespace Dayflow.Windows.Core;

/// <summary>
/// Platform-neutral capture policy helpers shared by the WinUI adapter and
/// the C-ABI smoke-test project. The adapter remains responsible for system
/// permissions and frame lifecycle; this parser is deliberately testable
/// without a window or GPU.
/// </summary>
public static class DayflowWindowsCapturePolicy
{
    public const string LocalDerivationMode = "privacy_gated_local_context_v1";

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

    public static bool IsPrivateContext(string? applicationId, string? windowTitle)
    {
        var value = $"{applicationId} {windowTitle}".ToLowerInvariant();
        return ContainsAny(value, "incognito", "inprivate", "private browsing", "password", "credential");
    }

    public static bool IsDrmContent(string? applicationId, string? windowTitle)
    {
        var value = $"{applicationId} {windowTitle}".ToLowerInvariant();
        return ContainsAny(value, "protected content", "drm", "widevine", "playready", "netflix");
    }

    public static (string Title, string Summary, string Category, string DerivationMode) DeriveCard(
        string? applicationId,
        string? windowTitle = null)
    {
        var normalizedApplication = NormalizeApplicationId(applicationId);
        var value = $"{normalizedApplication} {windowTitle}".ToLowerInvariant();
        var category = value switch
        {
            var text when ContainsAny(text, "code", "devenv", "studio", "rider", "idea", "terminal", "powershell")
                => "focus",
            var text when ContainsAny(text, "slack", "teams", "zoom", "meet", "discord", "mail", "outlook")
                => "communication",
            var text when ContainsAny(text, "chrome", "edge", "firefox", "browser", "brave")
                => "research",
            var text when ContainsAny(text, "spotify", "vlc", "youtube", "music", "video")
                => "media",
            _ => "activity",
        };
        var title = category switch
        {
            "focus" => "Focused work session",
            "communication" => "Communication session",
            "research" => "Research session",
            "media" => "Media session",
            _ => "Activity session",
        };
        return (
            title,
            $"Local derivation classified a privacy-approved {category} activity. Window titles and raw pixels were released before event creation.",
            category,
            LocalDerivationMode);
    }

    public static IReadOnlyList<string> ParseList(string? value) =>
        (value ?? "")
            .Split(new[] { '\r', '\n', ',', ';' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(item => item.Trim())
            .Where(item => item.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(64)
            .ToArray();

    private static string? NormalizeApplicationId(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var normalized = string.Concat(value.Where(character => !char.IsControl(character))).Trim();
        return normalized.Length == 0 ? null : normalized[..Math.Min(normalized.Length, 160)];
    }

    private static bool ContainsAny(string value, params string[] fragments) =>
        fragments.Any(value.Contains);
}
