package app.dayflow.android

import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

data class DayflowAndroidAuthResult(val accountId: String, val email: String, val token: String)

/** Native email-code client for the canonical Dayflow account service. */
class DayflowAndroidAuthClient(private val baseUrl: String) {
    suspend fun requestCode(email: String) = withContext(Dispatchers.IO) {
        val normalized = validateEmail(email)
        request("/v1/auth/code/start", JSONObject().put("email", normalized).toString())
    }

    suspend fun verifyCode(email: String, code: String, deviceName: String): DayflowAndroidAuthResult = withContext(Dispatchers.IO) {
        val normalized = validateEmail(email)
        val digits = code.filter(Char::isDigit)
        require(digits.length == 6) { "Enter the six-digit sign-in code." }
        val response = JSONObject(
            request(
                "/v1/auth/code/verify",
                JSONObject()
                    .put("email", normalized)
                    .put("code", digits)
                    .put("device_name", deviceName)
                    .toString(),
            ),
        )
        val user = response.getJSONObject("user")
        DayflowAndroidAuthResult(
            accountId = user.getString("id"),
            email = user.getString("email"),
            token = response.getString("session_token"),
        )
    }

    private fun request(path: String, body: String): String {
        require(DayflowAndroidEndpointPolicy.isAllowed(baseUrl)) {
            "The Dayflow account service must use HTTPS, or loopback HTTP for local development."
        }
        val endpoint = Uri.parse(baseUrl.trim().trimEnd('/') + path)
        val connection = (URL(endpoint.toString()).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            instanceFollowRedirects = false
            useCaches = false
            connectTimeout = 20_000
            readTimeout = 20_000
            doInput = true
            doOutput = true
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Cookie", "")
        }
        connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        val status = connection.responseCode
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
        val response = stream?.bufferedReader()?.use { it.readText() } ?: ""
        connection.disconnect()
        if (status !in 200..299) {
            val message = runCatching { JSONObject(response).optString("message").ifBlank { JSONObject(response).optString("detail") } }
                .getOrNull()
                .takeUnless { it.isNullOrBlank() }
                ?: "The Dayflow account service could not complete sign-in."
            error("Dayflow sign-in error ($status): $message")
        }
        return response
    }

    private fun validateEmail(value: String): String {
        val normalized = value.trim().lowercase()
        require(normalized.contains('@') && normalized.contains('.') && !normalized.contains(' ')) { "Enter a valid email address." }
        return normalized
    }
}
