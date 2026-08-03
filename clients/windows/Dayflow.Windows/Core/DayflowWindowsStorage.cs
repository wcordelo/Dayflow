namespace Dayflow.Windows.Core;

/// <summary>
/// Per-user storage paths for the unpackaged WinUI 3 client. ApplicationData
/// is package-identity scoped and is not available to this delivery shape.
/// </summary>
internal static class DayflowWindowsStorage
{
    private static readonly string Root = ResolveRoot();

    public static string KeysDirectory => Path.Combine(Root, "Keys");

    public static string SyncDirectory => Path.Combine(Root, "Sync");

    private static string ResolveRoot()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
            throw new InvalidOperationException("Windows Local AppData is unavailable.");
        return Path.Combine(localAppData, "Dayflow");
    }
}
