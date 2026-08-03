package app.dayflow.android

import java.util.Base64

data class DayflowEventEnvelope(
    val eventId: String,
    val deviceId: String,
    val logicalClock: ULong,
    val schemaVersion: UShort,
    val keyVersion: UInt,
    val nonce: String,
    val ciphertext: String,
) {
    companion object {
        const val CURRENT_SCHEMA_VERSION = 1
        const val MAX_LOGICAL_CLOCK = 9_007_199_254_740_991L
    }
}

/**
 * The Rust core and relay accept padded/unpadded standard or URL-safe base64.
 * Keep the native persistence boundary just as strict: a valid XChaCha20
 * nonce is 24 bytes and the ciphertext must include its 16-byte auth tag.
 */
internal object DayflowWireEnvelopeValidation {
    private const val EVENT_NONCE_BYTES = 24
    private const val EVENT_AUTH_TAG_BYTES = 16

    fun hasValidEncryptedFieldShape(nonce: String, ciphertext: String): Boolean =
        decode(nonce)?.size == EVENT_NONCE_BYTES &&
            decode(ciphertext)?.size?.let { it >= EVENT_AUTH_TAG_BYTES } == true

    fun decode(value: String): ByteArray? {
        if (value.isEmpty() || value.any { it !in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-" }) {
            return null
        }

        val firstPadding = value.indexOf('=')
        if (firstPadding >= 0) {
            if (value.length % 4 != 0 || firstPadding < value.length - 2 ||
                value.substring(firstPadding).any { it != '=' }
            ) {
                return null
            }
        }

        val unpadded = value.substringBefore('=').replace('-', '+').replace('_', '/')
        if (unpadded.length % 4 == 1) return null
        val padded = unpadded + "=".repeat((4 - unpadded.length % 4) % 4)
        return runCatching { Base64.getDecoder().decode(padded) }.getOrNull()
    }
}
