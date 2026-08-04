import Foundation

public enum DayflowMobileAIChatError: LocalizedError, Equatable, Sendable {
    case invalidQuestion
    case invalidConfiguration
    case unsupportedProvider(String)
    case server(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidQuestion:
            return "Enter a question for Dayflow."
        case .invalidConfiguration:
            return "Complete the on-device AI provider settings before asking Dayflow."
        case .unsupportedProvider(let provider):
            return "The \(provider) CLI provider is available on the Mac client, but is not available in this mobile client."
        case .server(let status, let message):
            return "AI provider error (\(status)): \(message)"
        case .invalidResponse:
            return "The selected AI provider returned an unreadable response."
        }
    }
}

/// Executes chat against the provider selected by the user. The projection is
/// assembled locally and sent only to that selected provider; Dayflow's relay
/// is never used for inference.
public struct DayflowMobileAIChatClient: Sendable {
    public let configuration: DayflowAIProviderConfiguration
    private let session: URLSession

    public init(
        configuration: DayflowAIProviderConfiguration,
        session: URLSession = DayflowMobileHTTP.noRedirectSession
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func answer(
        question: String,
        context: [DayflowMobileChatContextItem],
        apiKey: String?
    ) async throws -> String {
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuestion.isEmpty == false else {
            throw DayflowMobileAIChatError.invalidQuestion
        }
        guard configuration.isConfigured else {
            throw DayflowMobileAIChatError.invalidConfiguration
        }
        guard configuration.providerID != DayflowAIProviderIds.codex,
              configuration.providerID != DayflowAIProviderIds.claude
        else {
            throw DayflowMobileAIChatError.unsupportedProvider(configuration.providerID)
        }
        if configuration.requiresAPIKey && apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw DayflowMobileAIChatError.invalidConfiguration
        }

        let prompt = Self.prompt(question: normalizedQuestion, context: context)
        let endpoint = try endpointURL()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any]
        switch configuration.providerID {
        case DayflowAIProviderIds.gemini:
            body = [
                "contents": [[
                    "role": "user",
                    "parts": [["text": prompt]],
                ]],
                "generationConfig": ["temperature": 0.2],
            ]
            if let apiKey {
                request.setValue(
                    apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    forHTTPHeaderField: "x-goog-api-key"
                )
            }
        case DayflowAIProviderIds.local:
            body = [
                "model": configuration.modelID,
                "messages": Self.openAIMessages(prompt: prompt),
                "stream": false,
                "options": ["temperature": 0.2],
            ]
        case DayflowAIProviderIds.openAICompatible:
            body = [
                "model": configuration.modelID,
                "messages": Self.openAIMessages(prompt: prompt),
                "temperature": 0.2,
            ]
            if let apiKey {
                request.setValue(
                    "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                    forHTTPHeaderField: "Authorization"
                )
            }
        default:
            throw DayflowMobileAIChatError.unsupportedProvider(configuration.providerID)
        }

        guard JSONSerialization.isValidJSONObject(body) else {
            throw DayflowMobileAIChatError.invalidConfiguration
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DayflowMobileAIChatError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data) ?? "The selected AI provider could not complete the request."
            throw DayflowMobileAIChatError.server(status: httpResponse.statusCode, message: message)
        }
        guard let answer = Self.answer(from: data, providerID: configuration.providerID),
              answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw DayflowMobileAIChatError.invalidResponse
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps prompts deterministic and bounded even when a device has a long
    /// local history. The text is context, not an instruction from the record.
    public static func prompt(
        question: String,
        context: [DayflowMobileChatContextItem]
    ) -> String {
        let header = "You are Dayflow, a calm private productivity assistant. Use only the local context below. Do not invent activity, feelings, or commitments. If the context is insufficient, say so."
        var lines = [header, "", "Local Dayflow context:"]
        var characterBudget = 12_000
        for item in context.prefix(32) {
            let line = "- [\(item.day)] \(item.kind): \(item.content)"
            guard line.count <= characterBudget else { break }
            lines.append(line)
            characterBudget -= line.count
        }
        lines.append("")
        lines.append("User question: \(question)")
        return lines.joined(separator: "\n")
    }

    private func endpointURL() throws -> URL {
        guard let base = URL(string: configuration.endpoint),
              DayflowMobileHTTP.isAllowedEndpoint(base)
        else {
            throw DayflowMobileAIChatError.invalidConfiguration
        }

        let path = base.path.lowercased()
        if path.contains("chat/completions") || path.hasSuffix("/api/chat") || path.contains(":generatecontent") {
            return base
        }
        let suffix: String
        switch configuration.providerID {
        case DayflowAIProviderIds.local:
            suffix = "/api/chat"
        case DayflowAIProviderIds.gemini:
            suffix = "/v1beta/models/\(configuration.modelID):generateContent"
        default:
            suffix = path.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions"
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let basePath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = basePath.isEmpty ? suffix : "/\(basePath)\(suffix)"
        guard let url = components?.url else {
            throw DayflowMobileAIChatError.invalidConfiguration
        }
        return url
    }

    private static func openAIMessages(prompt: String) -> [[String: String]] {
        [
            ["role": "system", "content": "Answer briefly and practically."],
            ["role": "user", "content": prompt],
        ]
    }

    private static func answer(from data: Data, providerID: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if providerID == DayflowAIProviderIds.gemini {
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first,
                  let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]]
            else { return nil }
            return parts.first?["text"] as? String
        }
        if providerID == DayflowAIProviderIds.local {
            if let message = object["message"] as? [String: Any], let content = message["content"] as? String {
                return content
            }
        }
        return ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return object["detail"] as? String
    }
}
