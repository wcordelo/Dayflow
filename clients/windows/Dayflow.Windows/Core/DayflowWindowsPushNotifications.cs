using System.Text.Json;
using Windows.Networking.PushNotifications;

namespace Dayflow.Windows.Core;

/// <summary>
/// Windows push-channel adapter. The channel is only a wake address; the
/// notification body is validated as a one-field sync signal before the
/// account model is asked to pull encrypted events.
/// </summary>
public sealed class DayflowWindowsPushNotifications
{
    private readonly Func<Task> _syncWakeHandler;
    private PushNotificationChannel? _channel;

    public DayflowWindowsPushNotifications(Func<Task> syncWakeHandler)
    {
        _syncWakeHandler = syncWakeHandler ?? throw new ArgumentNullException(nameof(syncWakeHandler));
    }

    public bool HasChannel => _channel is not null;

    public async Task<string> RequestChannelUriAsync()
    {
        var channel = await PushNotificationChannelManager
            .CreatePushNotificationChannelForApplicationAsync();

        if (string.IsNullOrWhiteSpace(channel.Uri))
            throw new InvalidOperationException("Windows did not return a push channel URI.");

        if (_channel is not null)
            _channel.PushNotificationReceived -= OnPushNotificationReceived;

        _channel = channel;
        _channel.PushNotificationReceived += OnPushNotificationReceived;
        return channel.Uri;
    }

    public void Close()
    {
        if (_channel is null) return;
        _channel.PushNotificationReceived -= OnPushNotificationReceived;
        _channel.Close();
        _channel = null;
    }

    /// <summary>
    /// Accept only {"kind":"sync_available"}. No event, journal, capture,
    /// or arbitrary provider fields may be interpreted as a wake instruction.
    /// </summary>
    public static bool AcceptsSyncAvailablePayload(string? payload)
    {
        if (string.IsNullOrWhiteSpace(payload)) return false;

        try
        {
            using var document = JsonDocument.Parse(payload);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return false;

            var properties = root.EnumerateObject().ToArray();
            return properties.Length == 1
                && root.TryGetProperty("kind", out var kind)
                && kind.ValueKind == JsonValueKind.String
                && string.Equals(kind.GetString(), "sync_available", StringComparison.Ordinal);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private async void OnPushNotificationReceived(
        PushNotificationChannel sender,
        PushNotificationReceivedEventArgs args)
    {
        var payload = args.RawNotification?.Content;
        if (!AcceptsSyncAvailablePayload(payload)) return;

        try
        {
            await _syncWakeHandler();
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"[DayflowWindows] Push wake sync failed: {error.Message}");
        }
    }
}
