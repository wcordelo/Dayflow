using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Dayflow.Windows.Capture;

/// <summary>
/// Reads only the foreground window identity needed by the shared privacy
/// policy. It deliberately does not read window pixels or text content.
/// </summary>
internal static class WindowsForegroundContext
{
    public sealed record Snapshot(string? ApplicationId, string? WindowTitle);

    public static Snapshot Read()
    {
        var window = GetForegroundWindow();
        if (window == IntPtr.Zero)
        {
            return new(null, null);
        }

        var titleBuffer = new StringBuilder(512);
        var titleLength = GetWindowText(window, titleBuffer, titleBuffer.Capacity);
        var title = titleLength > 0 ? titleBuffer.ToString() : null;

        GetWindowThreadProcessId(window, out var processID);
        string? applicationID = null;
        if (processID != 0)
        {
            try
            {
                var processName = Process.GetProcessById((int)processID).ProcessName;
                if (!string.IsNullOrWhiteSpace(processName))
                {
                    applicationID = $"windows:process:{processName}".ToLowerInvariant();
                }
            }
            catch (Exception) when (processID != 0)
            {
                // Process identity can disappear between the Win32 calls. A
                // missing optional context must not make capture fail open or
                // crash the capture callback.
            }
        }

        return new(applicationID, title);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int maxCount);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
}
