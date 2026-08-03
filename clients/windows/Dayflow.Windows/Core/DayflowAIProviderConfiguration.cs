using System.Text.Json;
using System.Text.Json.Serialization;

namespace Dayflow.Windows.Core;

/// <summary>Provider identifiers shared by native clients without sharing API secrets.</summary>
public static class DayflowAIProviderIds
{
    public const string Local = "local";
    public const string Gemini = "gemini";
    public const string OpenAICompatible = "openai_compatible";
    public const string Codex = "chatgpt";
    public const string Claude = "claude";
}

internal static class DayflowWindowsEndpointPolicy
{
    public static bool IsAllowed(Uri endpoint)
    {
        if (string.IsNullOrWhiteSpace(endpoint.Host)
            || !string.IsNullOrEmpty(endpoint.UserInfo)
            || !string.IsNullOrEmpty(endpoint.Query)
            || !string.IsNullOrEmpty(endpoint.Fragment)) return false;

        if (string.Equals(endpoint.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)) return true;
        return string.Equals(endpoint.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
            && endpoint.IsLoopback;
    }
}

public sealed record DayflowAIProviderConfiguration(
    [property: JsonPropertyName("provider_id")] string ProviderId,
    [property: JsonPropertyName("endpoint")] string Endpoint,
    [property: JsonPropertyName("model_id")] string ModelId)
{
    public bool RequiresApiKey => ProviderId is DayflowAIProviderIds.Gemini or DayflowAIProviderIds.OpenAICompatible;

    public bool IsConfigured => !string.IsNullOrWhiteSpace(ProviderId)
        && !string.IsNullOrWhiteSpace(ModelId)
        && (ProviderId is DayflowAIProviderIds.Codex or DayflowAIProviderIds.Claude
            || Uri.TryCreate(Endpoint, UriKind.Absolute, out var endpoint)
                && IsSafeEndpoint(endpoint));

    public static bool IsSafeEndpoint(Uri endpoint) => DayflowWindowsEndpointPolicy.IsAllowed(endpoint);
}

/// <summary>
/// Stores non-secret provider routing separately from the API secret. Both are
/// protected by the Windows DPAPI-backed local key store; neither is synced.
/// </summary>
public sealed class DayflowAIProviderStore
{
    private const string ConfigurationName = "ai-provider-config-v1";
    private const string ApiKeyName = "ai-provider-api-key-v1";
    private readonly DayflowWindowsKeyStore _keyStore;

    public DayflowAIProviderStore(DayflowWindowsKeyStore? keyStore = null)
    {
        _keyStore = keyStore ?? new DayflowWindowsKeyStore();
    }

    public DayflowAIProviderConfiguration? Load(string accountId)
    {
        var value = _keyStore.LoadText(accountId, ConfigurationName);
        if (string.IsNullOrWhiteSpace(value)) return null;
        try
        {
            return JsonSerializer.Deserialize<DayflowAIProviderConfiguration>(value);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public string? LoadApiKey(string accountId) => _keyStore.LoadText(accountId, ApiKeyName);

    public void Save(string accountId, DayflowAIProviderConfiguration configuration, string? apiKey)
    {
        if (!configuration.IsConfigured) throw new ArgumentException("The AI provider configuration is incomplete.", nameof(configuration));
        if (configuration.RequiresApiKey && string.IsNullOrWhiteSpace(apiKey)) throw new ArgumentException("This AI provider requires an API key.", nameof(apiKey));
        var json = JsonSerializer.Serialize(configuration);
        _keyStore.StoreText(accountId, ConfigurationName, json);
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            _keyStore.Delete(accountId, ApiKeyName);
        }
        else
        {
            _keyStore.StoreText(accountId, ApiKeyName, apiKey.Trim());
        }
    }

    public void Clear(string accountId)
    {
        _keyStore.Delete(accountId, ConfigurationName);
        _keyStore.Delete(accountId, ApiKeyName);
    }
}
