package app.dayflow.android

import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class DayflowAndroidAIChatClient(
    private val configuration: DayflowAIProviderConfiguration,
    private val apiKey: String?,
) {
    suspend fun answer(
        question: String,
        context: List<DayflowAndroidChatContextItem>,
    ): String = withContext(Dispatchers.IO) {
        val normalizedQuestion = question.trim()
        require(normalizedQuestion.isNotBlank()) { "Enter a question for Dayflow." }
        require(configuration.isConfigured) { "Complete the on-device AI provider settings before asking Dayflow." }
        require(configuration.providerId != DayflowAIProviderIds.CODEX && configuration.providerId != DayflowAIProviderIds.CLAUDE) {
            "The ${configuration.providerId} CLI provider is available on the Mac client, but is not available in this Android client."
        }
        require(!configuration.requiresApiKey || !apiKey.isNullOrBlank()) {
            "This AI provider requires an API key."
        }

        val endpoint = endpoint()
        val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            instanceFollowRedirects = false
            useCaches = false
            connectTimeout = 30_000
            readTimeout = 90_000
            doInput = true
            doOutput = true
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Cookie", "")
        }
        if (configuration.providerId == DayflowAIProviderIds.OPENAI_COMPATIBLE) {
            connection.setRequestProperty("Authorization", "Bearer ${apiKey.orEmpty().trim()}")
        } else if (configuration.providerId == DayflowAIProviderIds.GEMINI) {
            // Keep the Gemini secret out of URL diagnostics and proxy/access
            // logs. Google documents this header form for REST requests.
            connection.setRequestProperty("x-goog-api-key", apiKey.orEmpty().trim())
        }
        val body = requestBody(prompt(normalizedQuestion, context))
        connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
        val status = connection.responseCode
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
        val response = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
        connection.disconnect()
        if (status !in 200..299) {
            val message = runCatching { errorMessage(JSONObject(response)) }.getOrNull()
                ?: "The selected AI provider could not complete the request."
            error("AI provider error ($status): $message")
        }
        val answer = parseAnswer(JSONObject(response)).orEmpty().trim()
        require(answer.isNotBlank()) { "The selected AI provider returned an unreadable response." }
        answer
    }

    companion object {
        fun prompt(
            question: String,
            context: List<DayflowAndroidChatContextItem>,
        ): String {
            val lines = mutableListOf(
                "You are Dayflow, a calm private productivity assistant. Use only the local context below. Do not invent activity, feelings, or commitments. If the context is insufficient, say so.",
                "",
                "Local Dayflow context:",
            )
            var budget = 12_000
            context.take(32).forEach { item ->
                val line = "- [${item.day}] ${item.kind}: ${item.content}"
                if (line.length <= budget) {
                    lines += line
                    budget -= line.length
                }
            }
            lines += ""
            lines += "User question: ${question.trim()}"
            return lines.joinToString("\n")
        }
    }

    private fun endpoint(): String {
        val base = configuration.endpoint.trimEnd('/')
        val uri = Uri.parse(base)
        require(uri.host != null) { "The AI provider endpoint is invalid." }
        val path = uri.path.orEmpty().lowercase()
        if (path.contains("chat/completions") || path.endsWith("/api/chat") || path.contains(":generatecontent")) {
            return base
        }
        return when (configuration.providerId) {
            DayflowAIProviderIds.LOCAL -> "$base/api/chat"
            DayflowAIProviderIds.GEMINI -> "$base/v1beta/models/${configuration.modelId}:generateContent"
            else -> if (path.endsWith("/v1")) "$base/chat/completions" else "$base/v1/chat/completions"
        }
    }

    private fun requestBody(prompt: String): JSONObject = when (configuration.providerId) {
        DayflowAIProviderIds.GEMINI -> JSONObject()
            .put("contents", JSONArray().put(
                JSONObject()
                    .put("role", "user")
                    .put("parts", JSONArray().put(JSONObject().put("text", prompt))),
            ))
            .put("generationConfig", JSONObject().put("temperature", 0.2))
        DayflowAIProviderIds.LOCAL -> JSONObject()
            .put("model", configuration.modelId)
            .put("messages", openAIMessages(prompt))
            .put("stream", false)
            .put("options", JSONObject().put("temperature", 0.2))
        else -> JSONObject()
            .put("model", configuration.modelId)
            .put("messages", openAIMessages(prompt))
            .put("temperature", 0.2)
    }

    private fun openAIMessages(prompt: String) = JSONArray()
        .put(JSONObject().put("role", "system").put("content", "Answer briefly and practically."))
        .put(JSONObject().put("role", "user").put("content", prompt))

    private fun parseAnswer(json: JSONObject): String? {
        if (configuration.providerId == DayflowAIProviderIds.GEMINI) {
            return json.optJSONArray("candidates")?.optJSONObject(0)
                ?.optJSONObject("content")?.optJSONArray("parts")?.optJSONObject(0)
                ?.optString("text")?.takeIf { it.isNotBlank() }
        }
        if (configuration.providerId == DayflowAIProviderIds.LOCAL) {
            json.optJSONObject("message")?.optString("content")?.takeIf { it.isNotBlank() }?.let { return it }
        }
        return json.optJSONArray("choices")?.optJSONObject(0)
            ?.optJSONObject("message")?.optString("content")?.takeIf { it.isNotBlank() }
    }

    private fun errorMessage(json: JSONObject): String? =
        json.optString("message").takeIf { it.isNotBlank() }
            ?: json.optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() }
            ?: json.optString("detail").takeIf { it.isNotBlank() }
}
