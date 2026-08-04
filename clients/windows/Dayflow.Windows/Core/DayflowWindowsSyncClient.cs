using System.Globalization;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Dayflow.Windows.Core;

public sealed record DayflowWindowsRelayDevice(
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("public_key")] string PublicKey,
    [property: JsonPropertyName("signing_public_key")] string SigningPublicKey,
    [property: JsonPropertyName("display_name")] string DisplayName,
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("created_at")] long CreatedAt,
    [property: JsonPropertyName("last_seen_at")] long LastSeenAt,
    [property: JsonPropertyName("key_bootstrap_required")] bool KeyBootstrapRequired = false);

public sealed record DayflowWindowsWrappedKey(
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("key_version")] uint KeyVersion,
    [property: JsonPropertyName("wrapped_account_key")] string WrappedAccountKey,
    [property: JsonPropertyName("wrapped_by_device_id")] string WrappedByDeviceId,
    [property: JsonPropertyName("created_at")] long CreatedAt);

public sealed record DayflowWindowsPushResponse(
    [property: JsonPropertyName("accepted_event_ids")] string[] AcceptedEventIds,
    [property: JsonPropertyName("duplicate_event_ids")] string[] DuplicateEventIds,
    [property: JsonPropertyName("cursor")] string Cursor,
    [property: JsonPropertyName("notification_count")] int NotificationCount);

public sealed record DayflowWindowsPulledEvent(
    [property: JsonPropertyName("sequence")] long Sequence,
    [property: JsonPropertyName("envelope")] DayflowEventEnvelope Envelope);

public sealed record DayflowWindowsPullResponse(
    [property: JsonPropertyName("cursor")] string Cursor,
    [property: JsonPropertyName("events")] DayflowWindowsPulledEvent[] Events);

public sealed record DayflowWindowsNotificationHint(
    [property: JsonPropertyName("sequence")] long Sequence,
    [property: JsonPropertyName("kind")] string Kind);

public sealed record DayflowWindowsNotificationHintsResponse(
    [property: JsonPropertyName("cursor")] string Cursor,
    [property: JsonPropertyName("hints")] DayflowWindowsNotificationHint[] Hints);

public sealed record DayflowWindowsPushRegistrationResult(
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("registered")] bool Registered);

public sealed class DayflowWindowsRelayException : HttpRequestException
{
    public DayflowWindowsRelayException(int statusCode, string message)
        : base($"Sync relay error ({statusCode}): {message}")
    {
        RelayStatusCode = statusCode;
    }

    public int RelayStatusCode { get; }
}

/// <summary>HTTP transport for the opaque relay with proof-of-key headers.</summary>
public sealed class DayflowWindowsSyncClient
{
    private readonly HttpClient _httpClient;
    private readonly string _baseUrl;

    public DayflowWindowsSyncClient(string baseUrl, HttpClient? httpClient = null)
    {
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var parsed)
            || !IsAllowedRelayUri(parsed))
        {
            throw new ArgumentException(
                "Use an HTTPS Dayflow sync relay URL. HTTP is allowed only for localhost development.",
                nameof(baseUrl));
        }

        _baseUrl = parsed.ToString().TrimEnd('/');
        _httpClient = httpClient ?? CreateHttpClient(TimeSpan.FromSeconds(30));
    }

    private static bool IsAllowedRelayUri(Uri uri)
    {
        return DayflowWindowsEndpointPolicy.IsAllowed(uri);
    }

    private static HttpClient CreateHttpClient(TimeSpan timeout) => new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
    }) { Timeout = timeout };

    public Task<DayflowWindowsRelayDevice> RegisterAsync(
        string deviceId,
        byte[] publicKey,
        byte[] signingPublicKey,
        string displayName,
        string token,
        bool recoveryMode,
        CancellationToken cancellationToken = default) => SendAsync<DayflowWindowsRelayDevice>(
            "/v1/sync/devices",
            HttpMethod.Post,
            token,
            null,
            null,
            new
            {
                device_id = deviceId,
                public_key = Convert.ToBase64String(publicKey),
                signing_public_key = Convert.ToBase64String(signingPublicKey),
                display_name = displayName,
                platform = "windows",
                recovery_mode = recoveryMode,
            },
            cancellationToken);

    public Task<DayflowWindowsRelayDevice[]> ListAsync(
        string token,
        CancellationToken cancellationToken = default) => SendAsync<DayflowWindowsRelayDevice[]>(
            "/v1/sync/devices",
            HttpMethod.Get,
            token,
            null,
            null,
            null,
            cancellationToken);

    public Task<DayflowWindowsRelayDevice> ApproveAsync(
        string targetDeviceId,
        string token,
        string approverDeviceId,
        byte[] signingPrivateKey,
        uint keyVersion,
        string wrappedAccountKeyJson,
        CancellationToken cancellationToken = default) => SendAsync<DayflowWindowsRelayDevice>(
            $"/v1/sync/devices/{Uri.EscapeDataString(targetDeviceId)}/approve",
            HttpMethod.Post,
            token,
            approverDeviceId,
            signingPrivateKey,
            new
            {
                key_version = keyVersion,
                wrapped_account_key = Convert.ToBase64String(Encoding.UTF8.GetBytes(wrappedAccountKeyJson)),
                wrapped_by_device_id = approverDeviceId,
            },
            cancellationToken);

    public Task<DayflowWindowsRelayDevice> RevokeAsync(
        string targetDeviceId,
        string token,
        string actorDeviceId,
        byte[] signingPrivateKey,
        CancellationToken cancellationToken = default) => SendAsync<DayflowWindowsRelayDevice>(
            $"/v1/sync/devices/{Uri.EscapeDataString(targetDeviceId)}/revoke",
            HttpMethod.Post,
            token,
            actorDeviceId,
            signingPrivateKey,
            null,
            cancellationToken);

    public Task<DayflowWindowsWrappedKey?> WrappedKeyAsync(
        string deviceId,
        string token,
        byte[] signingPrivateKey,
        CancellationToken cancellationToken = default) => SendNullableAsync<DayflowWindowsWrappedKey>(
            $"/v1/sync/devices/{Uri.EscapeDataString(deviceId)}/wrapped-key",
            HttpMethod.Get,
            token,
            deviceId,
            signingPrivateKey,
            null,
            cancellationToken);

    public Task<DayflowWindowsWrappedKey[]> WrappedKeysAsync(
        string deviceId,
        string token,
        byte[] signingPrivateKey,
        CancellationToken cancellationToken = default) => WrappedKeysWithFallbackAsync(
            deviceId,
            token,
            signingPrivateKey,
            cancellationToken);

    private async Task<DayflowWindowsWrappedKey[]> WrappedKeysWithFallbackAsync(
        string deviceId,
        string token,
        byte[] signingPrivateKey,
        CancellationToken cancellationToken)
    {
        try
        {
            return await SendAsync<DayflowWindowsWrappedKey[]>(
                $"/v1/sync/devices/{Uri.EscapeDataString(deviceId)}/wrapped-keys",
                HttpMethod.Get,
                token,
                deviceId,
                signingPrivateKey,
                null,
                cancellationToken);
        }
        catch (DayflowWindowsRelayException error) when (error.RelayStatusCode == 404)
        {
            var legacy = await WrappedKeyAsync(deviceId, token, signingPrivateKey, cancellationToken);
            return legacy is null ? Array.Empty<DayflowWindowsWrappedKey>() : [legacy];
        }
    }

    public Task<DayflowWindowsPushResponse> PushAsync(
        string deviceId,
        string token,
        byte[] signingPrivateKey,
        IReadOnlyList<DayflowEventEnvelope> envelopes,
        CancellationToken cancellationToken = default) => SendAsync<DayflowWindowsPushResponse>(
            "/v1/sync/events",
            HttpMethod.Post,
            token,
            deviceId,
            signingPrivateKey,
            new { envelopes },
            cancellationToken);

    public Task<DayflowWindowsPullResponse> PullAsync(
        string deviceId,
        string token,
        byte[] signingPrivateKey,
        string? cursor,
        CancellationToken cancellationToken = default)
    {
        var path = "/v1/sync/events?limit=100";
        if (!string.IsNullOrWhiteSpace(cursor)) path += $"&cursor={Uri.EscapeDataString(cursor)}";
        return SendAsync<DayflowWindowsPullResponse>(path, HttpMethod.Get, token, deviceId, signingPrivateKey, null, cancellationToken);
    }

    public async Task<DayflowWindowsNotificationHintsResponse> PullNotificationHintsAsync(
        string deviceId,
        string token,
        byte[] signingPrivateKey,
        string? cursor,
        CancellationToken cancellationToken = default)
    {
        var path = "/v1/sync/notifications?limit=100";
        if (!string.IsNullOrWhiteSpace(cursor)) path += $"&cursor={Uri.EscapeDataString(cursor)}";
        var response = await SendAsync<DayflowWindowsNotificationHintsResponse>(
            path,
            HttpMethod.Get,
            token,
            deviceId,
            signingPrivateKey,
            null,
            cancellationToken);
        if (response.Hints.Any(hint => hint.Sequence <= 0 || !string.Equals(hint.Kind, "sync_available", StringComparison.Ordinal)))
            throw new InvalidOperationException("The sync relay returned an invalid notification hint.");
        return response;
    }

    public Task<DayflowWindowsPushRegistrationResult> RegisterPushTokenAsync(
        string deviceId,
        string token,
        byte[] signingPrivateKey,
        string pushToken,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(pushToken)) throw new ArgumentException("A non-empty push token is required.", nameof(pushToken));
        return SendAsync<DayflowWindowsPushRegistrationResult>(
            "/v1/sync/notifications",
            HttpMethod.Put,
            token,
            deviceId,
            signingPrivateKey,
            new { token = pushToken },
            cancellationToken);
    }

    public Task<DayflowWindowsPushRegistrationResult> UnregisterPushTokenAsync(
        string deviceId,
        string token,
        byte[] signingPrivateKey,
        CancellationToken cancellationToken = default) => SendAsync<DayflowWindowsPushRegistrationResult>(
            "/v1/sync/notifications",
            HttpMethod.Delete,
            token,
            deviceId,
            signingPrivateKey,
            null,
            cancellationToken);

    private async Task<T> SendAsync<T>(
        string path,
        HttpMethod method,
        string token,
        string? deviceId,
        byte[]? signingPrivateKey,
        object? body,
        CancellationToken cancellationToken)
    {
        var responseBody = await SendRawAsync(path, method, token, deviceId, signingPrivateKey, body, cancellationToken);
        return JsonSerializer.Deserialize<T>(responseBody)
            ?? throw new InvalidOperationException("The sync relay returned an empty response.");
    }

    private async Task<T?> SendNullableAsync<T>(
        string path,
        HttpMethod method,
        string token,
        string? deviceId,
        byte[]? signingPrivateKey,
        object? body,
        CancellationToken cancellationToken)
    {
        var responseBody = await SendRawAsync(path, method, token, deviceId, signingPrivateKey, body, cancellationToken);
        return string.Equals(responseBody.Trim(), "null", StringComparison.OrdinalIgnoreCase)
            ? default
            : JsonSerializer.Deserialize<T>(responseBody);
    }

    private async Task<string> SendRawAsync(
        string path,
        HttpMethod method,
        string token,
        string? deviceId,
        byte[]? signingPrivateKey,
        object? body,
        CancellationToken cancellationToken)
    {
        var bodyBytes = body is null ? Array.Empty<byte>() : JsonSerializer.SerializeToUtf8Bytes(body);
        using var request = new HttpRequestMessage(method, _baseUrl + path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (body is not null) request.Content = new ByteArrayContent(bodyBytes);
        if (deviceId is not null)
        {
            if (signingPrivateKey is not { Length: 32 }) throw new InvalidOperationException("Device signing key is unavailable.");
            var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var timestampText = timestamp.ToString(CultureInfo.InvariantCulture);
            var nonceBytes = RandomNumberGenerator.GetBytes(24);
            var nonce = Convert.ToBase64String(nonceBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            var message = DayflowCoreInterop.CanonicalDeviceRequest(
                method.Method,
                path,
                bodyBytes,
                timestamp,
                nonce,
                deviceId);
            var signatureJson = DayflowCoreInterop.SignRequest(message, signingPrivateKey);
            using var signatureDocument = JsonDocument.Parse(signatureJson);
            var signature = Convert.FromBase64String(signatureDocument.RootElement.GetProperty("signature").GetString()!);
            request.Headers.Add("X-Dayflow-Device-ID", deviceId);
            request.Headers.Add("X-Dayflow-Device-Timestamp", timestampText);
            request.Headers.Add("X-Dayflow-Device-Nonce", nonce);
            request.Headers.Add("X-Dayflow-Device-Signature", Convert.ToBase64String(signature));
        }

        using var response = await _httpClient.SendAsync(request, cancellationToken);
        var responseText = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var message = "The sync relay could not complete the request.";
            try { message = JsonDocument.Parse(responseText).RootElement.GetProperty("message").GetString() ?? message; }
            catch (JsonException) { }
            throw new DayflowWindowsRelayException((int)response.StatusCode, message);
        }
        return responseText;
    }
}
