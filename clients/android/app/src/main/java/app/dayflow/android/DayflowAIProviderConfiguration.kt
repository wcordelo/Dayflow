package app.dayflow.android

import android.net.Uri
import org.json.JSONObject
import java.net.URL

internal object DayflowAndroidEndpointPolicy {
    fun isAllowed(value: String): Boolean {
        val normalized = value.trim()
        if (normalized.isBlank()) return false
        val parsed = runCatching { URL(normalized) }.getOrNull() ?: return false
        val uri = Uri.parse(normalized)
        val scheme = parsed.protocol.lowercase()
        val host = uri.host?.lowercase() ?: return false
        val authority = uri.encodedAuthority ?: return false
        if (authority.contains('@') || uri.encodedQuery != null || uri.encodedFragment != null) return false
        return when (scheme) {
            "https" -> true
            "http" -> host == "localhost" || host == "127.0.0.1" || host == "::1"
            else -> false
        }
    }
}

object DayflowAIProviderIds {
    const val LOCAL = "local"
    const val GEMINI = "gemini"
    const val OPENAI_COMPATIBLE = "openai_compatible"
    const val CODEX = "chatgpt"
    const val CLAUDE = "claude"
}

data class DayflowAIProviderConfiguration(
    val providerId: String,
    val endpoint: String,
    val modelId: String,
) {
    val requiresApiKey: Boolean
        get() = providerId == DayflowAIProviderIds.GEMINI || providerId == DayflowAIProviderIds.OPENAI_COMPATIBLE

    val isConfigured: Boolean
        get() = providerId.isNotBlank() && modelId.isNotBlank() &&
            (providerId == DayflowAIProviderIds.CODEX || providerId == DayflowAIProviderIds.CLAUDE ||
                isSafeEndpoint(endpoint))

    private fun isSafeEndpoint(value: String): Boolean {
        return DayflowAndroidEndpointPolicy.isAllowed(value)
    }

    fun toJson(): String = JSONObject()
        .put("provider_id", providerId)
        .put("endpoint", endpoint)
        .put("model_id", modelId)
        .toString()

    companion object {
        fun fromJson(value: String): DayflowAIProviderConfiguration {
            val json = JSONObject(value)
            return DayflowAIProviderConfiguration(
                providerId = json.getString("provider_id"),
                endpoint = json.optString("endpoint", ""),
                modelId = json.getString("model_id"),
            )
        }
    }
}

/** DPAPI/Keystore equivalent for the on-device AI routing and API secret. */
class DayflowAIProviderStore(private val keyStore: DayflowAndroidKeyStore) {
    private val configurationName = "ai-provider-config-v1"
    private val apiKeyName = "ai-provider-api-key-v1"

    fun load(accountId: String): DayflowAIProviderConfiguration? =
        keyStore.loadText(accountId, configurationName)?.let { value ->
            runCatching { DayflowAIProviderConfiguration.fromJson(value) }.getOrNull()
        }

    fun loadApiKey(accountId: String): String? = keyStore.loadText(accountId, apiKeyName)

    fun save(accountId: String, configuration: DayflowAIProviderConfiguration, apiKey: String?) {
        require(configuration.isConfigured) { "The AI provider configuration is incomplete" }
        require(!configuration.requiresApiKey || !apiKey.isNullOrBlank()) { "This AI provider requires an API key" }
        keyStore.storeText(accountId, configurationName, configuration.toJson())
        if (apiKey.isNullOrBlank()) keyStore.delete(accountId, apiKeyName)
        else keyStore.storeText(accountId, apiKeyName, apiKey.trim())
    }

    fun clear(accountId: String) {
        keyStore.delete(accountId, configurationName)
        keyStore.delete(accountId, apiKeyName)
    }
}
