using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Dayflow.Windows.Core;

public sealed record DayflowWindowsAuthResult(string AccountId, string Email, string Token);

/// <summary>Native email-code client for the canonical Dayflow account service.</summary>
public sealed class DayflowWindowsAuthClient
{
    private readonly HttpClient _httpClient;

    public DayflowWindowsAuthClient(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient(new HttpClientHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
        }) { Timeout = TimeSpan.FromSeconds(20) };
    }

    public async Task RequestCodeAsync(string email, string endpoint, CancellationToken cancellationToken = default)
    {
        var normalized = ValidateEmail(email);
        _ = await SendAsync<DayflowAuthStartResponse>(endpoint, "/v1/auth/code/start", new { email = normalized }, cancellationToken);
    }

    public async Task<DayflowWindowsAuthResult> VerifyCodeAsync(
        string email,
        string code,
        string deviceName,
        string endpoint,
        CancellationToken cancellationToken = default)
    {
        var normalized = ValidateEmail(email);
        var digits = new string(code.Where(char.IsDigit).ToArray());
        if (digits.Length != 6) throw new InvalidOperationException("Enter the six-digit sign-in code.");
        var response = await SendAsync<DayflowAuthVerifyResponse>(
            endpoint,
            "/v1/auth/code/verify",
            new { email = normalized, code = digits, device_name = deviceName },
            cancellationToken);
        return new DayflowWindowsAuthResult(response.User.Id, response.User.Email, response.SessionToken);
    }

    private async Task<T> SendAsync<T>(string endpoint, string path, object body, CancellationToken cancellationToken)
    {
        if (!Uri.TryCreate(endpoint.TrimEnd('/'), UriKind.Absolute, out var baseUri)
            || !DayflowWindowsEndpointPolicy.IsAllowed(baseUri))
            throw new InvalidOperationException("The Dayflow account service must use HTTPS, or loopback HTTP for local development.");
        using var response = await _httpClient.PostAsJsonAsync(new Uri(baseUri, path), body, cancellationToken);
        var payload = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var message = "The Dayflow account service could not complete sign-in.";
            try
            {
                using var error = JsonDocument.Parse(payload);
                message = error.RootElement.TryGetProperty("message", out var value)
                    ? value.GetString() ?? message
                    : error.RootElement.TryGetProperty("detail", out var detail) ? detail.GetString() ?? message : message;
            }
            catch (JsonException) { }
            throw new HttpRequestException($"Dayflow sign-in error ({(int)response.StatusCode}): {message}");
        }
        return JsonSerializer.Deserialize<T>(payload)
            ?? throw new InvalidOperationException("The Dayflow account service returned an invalid response.");
    }

    private static string ValidateEmail(string value)
    {
        var normalized = value.Trim().ToLowerInvariant();
        if (!normalized.Contains('@') || !normalized.Contains('.') || normalized.Contains(' '))
            throw new InvalidOperationException("Enter a valid email address.");
        return normalized;
    }

    private sealed record DayflowAuthStartResponse([property: JsonPropertyName("ok")] bool Ok);
    private sealed record DayflowAuthVerifyResponse(
        [property: JsonPropertyName("session_token")] string SessionToken,
        [property: JsonPropertyName("user")] DayflowAuthUser User);
    private sealed record DayflowAuthUser(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("email")] string Email);
}
