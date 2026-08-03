using System.Globalization;

namespace Dayflow.Windows.Core;

public static class DayflowWindowsSharedSettingContract
{
    public static bool IsAllowedKey(string key)
    {
        return key == "dayflow.theme"
            || key == "dayflow.capture.paused"
            || key == "dayflow.logical_day_boundary_hour"
            || IsValidDatedKey(key, "day_goal:")
            || IsValidDatedKey(key, "daily_standup:");
    }

    private static bool IsValidDatedKey(string key, string prefix)
    {
        if (!key.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var day = key[prefix.Length..];
        if (day.Length != 10
            || day[4] != '-'
            || day[7] != '-'
            || day.Any(character => !char.IsAsciiDigit(character)))
            return false;

        return DateOnly.TryParseExact(
                day,
                "yyyy-MM-dd",
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out var parsed)
            && parsed.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) == day;
    }
}
