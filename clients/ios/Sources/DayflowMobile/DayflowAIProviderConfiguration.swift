import Foundation

public enum DayflowAIProviderIds {
    public static let local = "local"
    public static let gemini = "gemini"
    public static let openAICompatible = "openai_compatible"
    public static let codex = "chatgpt"
    public static let claude = "claude"
}

public struct DayflowAIProviderConfiguration: Codable, Equatable, Sendable {
    public let providerID: String
    public let endpoint: String
    public let modelID: String

    public init(providerID: String, endpoint: String, modelID: String) {
        self.providerID = providerID
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var requiresAPIKey: Bool {
        providerID == DayflowAIProviderIds.gemini || providerID == DayflowAIProviderIds.openAICompatible
    }

    public var isConfigured: Bool {
        guard providerID.isEmpty == false, modelID.isEmpty == false else { return false }
        if providerID == DayflowAIProviderIds.codex || providerID == DayflowAIProviderIds.claude { return true }
        return Self.isSafeEndpoint(endpoint)
    }

    static func isSafeEndpoint(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return DayflowMobileHTTP.isAllowedEndpoint(url)
    }

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case endpoint
        case modelID = "model_id"
    }
}

/// Keychain-backed storage for the non-secret route and its separate API key.
public final class DayflowAIProviderStore: @unchecked Sendable {
    private let keyStore: DayflowMobileKeyStore
    private let configurationName = "ai-provider-config-v1"
    private let apiKeyName = "ai-provider-api-key-v1"

    public init(keyStore: DayflowMobileKeyStore = .init()) {
        self.keyStore = keyStore
    }

    public func load(accountID: String) -> DayflowAIProviderConfiguration? {
        guard let data = keyStore.secret(accountID: accountID, name: configurationName) else { return nil }
        return try? JSONDecoder().decode(DayflowAIProviderConfiguration.self, from: data)
    }

    public func loadAPIKey(accountID: String) -> String? {
        guard let data = keyStore.secret(accountID: accountID, name: apiKeyName) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(
        accountID: String,
        configuration: DayflowAIProviderConfiguration,
        apiKey: String?
    ) throws {
        guard configuration.isConfigured else { throw DayflowMobileKeyStoreError.invalidKey }
        if configuration.requiresAPIKey && apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        try keyStore.storeSecret(
            JSONEncoder().encode(configuration),
            accountID: accountID,
            name: configurationName
        )
        if let apiKey, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            try keyStore.storeSecret(
                Data(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
                accountID: accountID,
                name: apiKeyName
            )
        } else {
            keyStore.deleteSecret(accountID: accountID, name: apiKeyName)
        }
    }

    public func clear(accountID: String) {
        keyStore.deleteSecret(accountID: accountID, name: configurationName)
        keyStore.deleteSecret(accountID: accountID, name: apiKeyName)
    }
}
