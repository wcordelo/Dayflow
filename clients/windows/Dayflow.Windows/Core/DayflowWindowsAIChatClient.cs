using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Dayflow.Windows.Core;

/// <summary>
/// Runs chat directly against the provider configured on this Windows device.
/// The sync relay is deliberately not involved in inference.
/// </summary>
public sealed class DayflowWindowsAIChatClient
{
    private readonly HttpClient _httpClient;

    public DayflowWindowsAIChatClient(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient(new HttpClientHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
        }) { Timeout = TimeSpan.FromSeconds(90) };
    }

    public async Task<string> AnswerAsync(
        DayflowAIProviderConfiguration configuration,
        string? apiKey,
        string question,
        IReadOnlyList<DayflowWindowsChatContextItem> context,
        CancellationToken cancellationToken = default)
    {
        var normalizedQuestion = question.Trim();
        if (normalizedQuestion.Length == 0) throw new ArgumentException("Enter a question for Dayflow.", nameof(question));
        if (!configuration.IsConfigured) throw new InvalidOperationException("Complete the on-device AI provider settings before asking Dayflow.");
        if (configuration.ProviderId is DayflowAIProviderIds.Codex or DayflowAIProviderIds.Claude)
            throw new InvalidOperationException($"The {configuration.ProviderId} CLI provider is available on the Mac client, but is not available in this Windows client.");
        if (configuration.RequiresApiKey && string.IsNullOrWhiteSpace(apiKey))
            throw new InvalidOperationException("This AI provider requires an API key.");

        var endpoint = Endpoint(configuration);
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (configuration.ProviderId == DayflowAIProviderIds.OpenAICompatible)
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey!.Trim());
        else if (configuration.ProviderId == DayflowAIProviderIds.Gemini)
            request.Headers.Add("x-goog-api-key", apiKey!.Trim());
        request.Content = new StringContent(
            JsonSerializer.Serialize(RequestBody(configuration, Prompt(normalizedQuestion, context))),
            Encoding.UTF8,
            "application/json");

        using var response = await _httpClient.SendAsync(request, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"AI provider error ({(int)response.StatusCode}): {ErrorMessage(responseBody) ?? "The selected AI provider could not complete the request."}");
        }

        var answer = ParseAnswer(responseBody, configuration.ProviderId)?.Trim();
        if (string.IsNullOrWhiteSpace(answer)) throw new InvalidOperationException("The selected AI provider returned an unreadable response.");
        return answer;
    }

    public static string Prompt(string question, IReadOnlyList<DayflowWindowsChatContextItem> context)
    {
        var builder = new StringBuilder();
        builder.AppendLine("You are Dayflow, a calm private productivity assistant. Use only the local context below. Do not invent activity, feelings, or commitments. If the context is insufficient, say so.");
        builder.AppendLine();
        builder.AppendLine("Local Dayflow context:");
        var budget = 12_000;
        foreach (var item in context.Take(32))
        {
            var line = $"- [{item.Day}] {item.Kind}: {item.Content}";
            if (line.Length > budget) break;
            builder.AppendLine(line);
            budget -= line.Length;
        }
        builder.AppendLine();
        builder.Append("User question: ").Append(question.Trim());
        return builder.ToString();
    }

    private static Uri Endpoint(DayflowAIProviderConfiguration configuration)
    {
        if (!Uri.TryCreate(configuration.Endpoint.Trim(), UriKind.Absolute, out var baseUri)
            || !DayflowWindowsEndpointPolicy.IsAllowed(baseUri))
            throw new InvalidOperationException("The AI provider endpoint is invalid.");
        var path = baseUri.AbsolutePath.ToLowerInvariant();
        if (path.Contains("chat/completions") || path.EndsWith("/api/chat", StringComparison.Ordinal) || path.Contains(":generatecontent", StringComparison.Ordinal))
            return baseUri;

        var suffix = configuration.ProviderId switch
        {
            DayflowAIProviderIds.Local => "api/chat",
            DayflowAIProviderIds.Gemini => $"v1beta/models/{Uri.EscapeDataString(configuration.ModelId)}:generateContent",
            _ => path.EndsWith("/v1", StringComparison.Ordinal) ? "chat/completions" : "v1/chat/completions",
        };
        var builder = new UriBuilder(baseUri)
        {
            Path = $"{baseUri.AbsolutePath.TrimEnd('/')}/{suffix}",
        };
        return builder.Uri;
    }

    private static object RequestBody(DayflowAIProviderConfiguration configuration, string prompt) =>
        configuration.ProviderId switch
        {
            DayflowAIProviderIds.Gemini => new
            {
                contents = new[] { new { role = "user", parts = new[] { new { text = prompt } } } },
                generationConfig = new { temperature = 0.2 },
            },
            DayflowAIProviderIds.Local => new
            {
                model = configuration.ModelId,
                messages = OpenAIMessages(prompt),
                stream = false,
                options = new { temperature = 0.2 },
            },
            _ => new
            {
                model = configuration.ModelId,
                messages = OpenAIMessages(prompt),
                temperature = 0.2,
            },
        };

    private static object[] OpenAIMessages(string prompt) =>
    [
        new { role = "system", content = "Answer briefly and practically." },
        new { role = "user", content = prompt },
    ];

    private static string? ParseAnswer(string value, string providerId)
    {
        using var document = JsonDocument.Parse(value);
        var root = document.RootElement;
        if (providerId == DayflowAIProviderIds.Gemini
            && root.TryGetProperty("candidates", out var candidates)
            && candidates.GetArrayLength() > 0
            && candidates[0].TryGetProperty("content", out var content)
            && content.TryGetProperty("parts", out var parts)
            && parts.GetArrayLength() > 0
            && parts[0].TryGetProperty("text", out var geminiText))
            return geminiText.GetString();
        if (providerId == DayflowAIProviderIds.Local
            && root.TryGetProperty("message", out var message)
            && message.TryGetProperty("content", out var localText))
            return localText.GetString();
        if (root.TryGetProperty("choices", out var choices)
            && choices.GetArrayLength() > 0
            && choices[0].TryGetProperty("message", out var openAIMessage)
            && openAIMessage.TryGetProperty("content", out var openAIText))
            return openAIText.GetString();
        return null;
    }

    private static string? ErrorMessage(string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            var root = document.RootElement;
            if (root.TryGetProperty("message", out var message)) return message.GetString();
            if (root.TryGetProperty("error", out var error) && error.TryGetProperty("message", out var errorMessage)) return errorMessage.GetString();
            if (root.TryGetProperty("detail", out var detail)) return detail.GetString();
        }
        catch (JsonException) { }
        return null;
    }
}
