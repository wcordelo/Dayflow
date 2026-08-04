package app.dayflow.android

import app.dayflow.core.*
import org.json.JSONArray
import org.json.JSONObject

/**
 * Kotlin-facing seam for the generated UniFFI bindings. The Android shell
 * owns lifecycle and secure storage; the Rust core owns encryption, event
 * validation, and deterministic projections.
 */
interface DayflowCoreBridge {
    fun version(): String
    fun generateAccountRootKey(): ByteArray
    fun exportRecoveryKit(accountRootKey: ByteArray, passphrase: String): String
    fun exportRecoveryKit(keyRing: DayflowAndroidAccountKeyRing, passphrase: String): String
    fun restoreRecoveryKey(kitJson: String, passphrase: String): ByteArray
    fun restoreRecoveryKeyRing(kitJson: String, passphrase: String): DayflowAndroidAccountKeyRing
    fun generateDeviceKeyMaterial(): DeviceKeyMaterial
    fun generateDeviceSigningKeyMaterial(): DeviceKeyMaterial
    fun canonicalDeviceRequest(
        method: String,
        pathWithQuery: String,
        body: ByteArray,
        timestamp: Long,
        nonce: String,
        deviceId: String,
    ): String
    fun signRequest(message: String, privateKey: ByteArray): ByteArray
    fun logicalDayKey(timestampUnix: Long, timezoneOffsetMinutes: Int, boundaryHour: UByte): String
    fun captureAllowed(
        permissionGranted: Boolean,
        userPaused: Boolean,
        deviceLocked: Boolean,
        sleeping: Boolean,
        privateContext: Boolean,
        drmContent: Boolean,
    ): Boolean
    fun captureDecision(contextJson: String, policyJson: String): DayflowCaptureDecision
    fun project(envelopes: List<DayflowEventEnvelope>, accountRootKey: ByteArray): String
    fun project(envelopes: List<DayflowEventEnvelope>, keyRing: DayflowAndroidAccountKeyRing): String
    fun rekey(
        envelopes: List<DayflowEventEnvelope>,
        sourceKeyRing: DayflowAndroidAccountKeyRing,
        destinationKeyRing: DayflowAndroidAccountKeyRing,
    ): List<DayflowEventEnvelope>
    fun seal(
        payloadJson: String,
        eventId: String,
        deviceId: String,
        logicalClock: ULong,
        accountRootKey: ByteArray,
    ): DayflowEventEnvelope
    fun seal(
        payloadJson: String,
        eventId: String,
        deviceId: String,
        logicalClock: ULong,
        keyVersion: UInt,
        accountRootKey: ByteArray,
    ): DayflowEventEnvelope
    fun wrapAccountKey(
        accountRootKey: ByteArray,
        recipientDeviceId: String,
        recipientPublicKey: ByteArray,
    ): String
    fun wrapAccountKey(
        accountRootKey: ByteArray,
        keyVersion: UInt,
        recipientDeviceId: String,
        recipientPublicKey: ByteArray,
    ): String
    fun unwrapAccountKey(wrappedKeyJson: String, privateKey: ByteArray): ByteArray
}

data class DeviceKeyMaterial(val privateKey: ByteArray, val publicKey: ByteArray)

data class DayflowCaptureDecision(val allowed: Boolean, val reason: String)

object UniFFIDayflowCoreBridge : DayflowCoreBridge {
    override fun version(): String = app.dayflow.core.coreVersion()

    override fun generateAccountRootKey(): ByteArray = app.dayflow.core.generateAccountRootKey()

    override fun exportRecoveryKit(accountRootKey: ByteArray, passphrase: String): String =
        app.dayflow.core.exportRecoveryKitJson(accountRootKey, passphrase)

    override fun exportRecoveryKit(keyRing: DayflowAndroidAccountKeyRing, passphrase: String): String =
        app.dayflow.core.exportRecoveryKitKeyringJson(keyRing.toJson(), passphrase)

    override fun restoreRecoveryKey(kitJson: String, passphrase: String): ByteArray =
        app.dayflow.core.restoreRecoveryKey(kitJson, passphrase)

    override fun restoreRecoveryKeyRing(kitJson: String, passphrase: String): DayflowAndroidAccountKeyRing =
        DayflowAndroidAccountKeyRing.fromJson(
            app.dayflow.core.restoreRecoveryKeyringJson(kitJson, passphrase),
        )

    override fun generateDeviceKeyMaterial(): DeviceKeyMaterial {
        val privateKey = app.dayflow.core.generateDevicePrivateKey()
        return DeviceKeyMaterial(privateKey, app.dayflow.core.devicePublicKey(privateKey))
    }

    override fun generateDeviceSigningKeyMaterial(): DeviceKeyMaterial {
        val privateKey = app.dayflow.core.generateDeviceSigningPrivateKey()
        return DeviceKeyMaterial(privateKey, app.dayflow.core.deviceSigningPublicKey(privateKey))
    }

    override fun canonicalDeviceRequest(
        method: String,
        pathWithQuery: String,
        body: ByteArray,
        timestamp: Long,
        nonce: String,
        deviceId: String,
    ): String = app.dayflow.core.canonicalDeviceRequest(
        method,
        pathWithQuery,
        body,
        timestamp,
        nonce,
        deviceId,
    )

    override fun signRequest(message: String, privateKey: ByteArray): ByteArray =
        app.dayflow.core.signRequest(message, privateKey)

    override fun logicalDayKey(timestampUnix: Long, timezoneOffsetMinutes: Int, boundaryHour: UByte): String =
        app.dayflow.core.logicalDayKeyFfi(timestampUnix, timezoneOffsetMinutes, boundaryHour)

    override fun captureAllowed(
        permissionGranted: Boolean,
        userPaused: Boolean,
        deviceLocked: Boolean,
        sleeping: Boolean,
        privateContext: Boolean,
        drmContent: Boolean,
    ): Boolean = app.dayflow.core.captureAllowed(
        permissionGranted,
        userPaused,
        deviceLocked,
        sleeping,
        privateContext,
        drmContent,
    )

    override fun captureDecision(contextJson: String, policyJson: String): DayflowCaptureDecision {
        val value = JSONObject(app.dayflow.core.captureDecisionJson(contextJson, policyJson))
        return DayflowCaptureDecision(
            allowed = value.optBoolean("allowed", false),
            reason = value.optString("reason", "privacy_decision_unavailable"),
        )
    }

    override fun project(envelopes: List<DayflowEventEnvelope>, accountRootKey: ByteArray): String {
        require(accountRootKey.size == 32) { "The account root key must be 32 bytes" }
        val json = JSONArray().apply {
            envelopes.forEach { envelope ->
                put(
                    JSONObject()
                        .put("event_id", envelope.eventId)
                        .put("device_id", envelope.deviceId)
                        .put("logical_clock", envelope.logicalClock.toString().toLong())
                        .put("schema_version", envelope.schemaVersion.toInt())
                        .put("key_version", envelope.keyVersion.toLong())
                        .put("nonce", envelope.nonce)
                        .put("ciphertext", envelope.ciphertext),
                )
            }
        }
        return projectJson(json.toString(), accountRootKey)
    }

    override fun project(envelopes: List<DayflowEventEnvelope>, keyRing: DayflowAndroidAccountKeyRing): String {
        val json = JSONArray().apply {
            envelopes.forEach { envelope ->
                put(
                    JSONObject()
                        .put("event_id", envelope.eventId)
                        .put("device_id", envelope.deviceId)
                        .put("logical_clock", envelope.logicalClock.toString().toLong())
                        .put("schema_version", envelope.schemaVersion.toInt())
                        .put("key_version", envelope.keyVersion.toLong())
                        .put("nonce", envelope.nonce)
                        .put("ciphertext", envelope.ciphertext),
                )
            }
        }
        return projectKeyringJson(json.toString(), keyRing.toJson())
    }

    override fun rekey(
        envelopes: List<DayflowEventEnvelope>,
        sourceKeyRing: DayflowAndroidAccountKeyRing,
        destinationKeyRing: DayflowAndroidAccountKeyRing,
    ): List<DayflowEventEnvelope> {
        val json = JSONArray().apply {
            envelopes.forEach { envelope ->
                put(
                    JSONObject()
                        .put("event_id", envelope.eventId)
                        .put("device_id", envelope.deviceId)
                        .put("logical_clock", envelope.logicalClock.toString().toLong())
                        .put("schema_version", envelope.schemaVersion.toInt())
                        .put("key_version", envelope.keyVersion.toLong())
                        .put("nonce", envelope.nonce)
                        .put("ciphertext", envelope.ciphertext),
                )
            }
        }
        val value = JSONArray(
            rekeyEnvelopesJson(json.toString(), sourceKeyRing.toJson(), destinationKeyRing.toJson()),
        )
        return buildList {
            for (index in 0 until value.length()) {
                val envelope = value.getJSONObject(index)
                add(
                    DayflowEventEnvelope(
                        eventId = envelope.getString("event_id"),
                        deviceId = envelope.getString("device_id"),
                        logicalClock = envelope.getLong("logical_clock").toULong(),
                        schemaVersion = envelope.getInt("schema_version").toUShort(),
                        keyVersion = envelope.getLong("key_version").toUInt(),
                        nonce = envelope.getString("nonce"),
                        ciphertext = envelope.getString("ciphertext"),
                    ),
                )
            }
        }
    }

    override fun seal(
        payloadJson: String,
        eventId: String,
        deviceId: String,
        logicalClock: ULong,
        accountRootKey: ByteArray,
    ): DayflowEventEnvelope {
        require(accountRootKey.size == 32) { "The account root key must be 32 bytes" }
        val value = JSONObject(
            sealJson(payloadJson, eventId, deviceId, logicalClock, accountRootKey),
        )
        return DayflowEventEnvelope(
            eventId = value.getString("event_id"),
            deviceId = value.getString("device_id"),
            logicalClock = value.getLong("logical_clock").toULong(),
            schemaVersion = value.getInt("schema_version").toUShort(),
            keyVersion = value.getLong("key_version").toUInt(),
            nonce = value.getString("nonce"),
            ciphertext = value.getString("ciphertext"),
        )
    }

    override fun seal(
        payloadJson: String,
        eventId: String,
        deviceId: String,
        logicalClock: ULong,
        keyVersion: UInt,
        accountRootKey: ByteArray,
    ): DayflowEventEnvelope {
        require(accountRootKey.size == 32 && keyVersion > 0u) { "The account key and version are invalid" }
        val value = JSONObject(
            sealJsonWithKeyVersion(payloadJson, eventId, deviceId, logicalClock, keyVersion, accountRootKey),
        )
        return DayflowEventEnvelope(
            eventId = value.getString("event_id"),
            deviceId = value.getString("device_id"),
            logicalClock = value.getLong("logical_clock").toULong(),
            schemaVersion = value.getInt("schema_version").toUShort(),
            keyVersion = value.getLong("key_version").toUInt(),
            nonce = value.getString("nonce"),
            ciphertext = value.getString("ciphertext"),
        )
    }

    override fun wrapAccountKey(
        accountRootKey: ByteArray,
        recipientDeviceId: String,
        recipientPublicKey: ByteArray,
    ): String = wrapAccountKeyJson(accountRootKey, recipientDeviceId, recipientPublicKey)

    override fun wrapAccountKey(
        accountRootKey: ByteArray,
        keyVersion: UInt,
        recipientDeviceId: String,
        recipientPublicKey: ByteArray,
    ): String = wrapAccountKeyJsonWithVersion(
        accountRootKey,
        keyVersion,
        recipientDeviceId,
        recipientPublicKey,
    )

    override fun unwrapAccountKey(wrappedKeyJson: String, privateKey: ByteArray): ByteArray =
        unwrapAccountKeyJson(wrappedKeyJson, privateKey)

}

object UnavailableDayflowCoreBridge : DayflowCoreBridge {
    override fun version(): String = "unavailable"

    override fun generateAccountRootKey(): ByteArray =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun exportRecoveryKit(accountRootKey: ByteArray, passphrase: String): String =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun restoreRecoveryKey(kitJson: String, passphrase: String): ByteArray =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun generateDeviceKeyMaterial(): DeviceKeyMaterial =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun generateDeviceSigningKeyMaterial(): DeviceKeyMaterial =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun canonicalDeviceRequest(
        method: String,
        pathWithQuery: String,
        body: ByteArray,
        timestamp: Long,
        nonce: String,
        deviceId: String,
    ): String = error("Dayflow Rust bindings are not packaged for this build")

    override fun signRequest(message: String, privateKey: ByteArray): ByteArray =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun logicalDayKey(timestampUnix: Long, timezoneOffsetMinutes: Int, boundaryHour: UByte): String =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun captureAllowed(
        permissionGranted: Boolean,
        userPaused: Boolean,
        deviceLocked: Boolean,
        sleeping: Boolean,
        privateContext: Boolean,
        drmContent: Boolean,
    ): Boolean = false

    override fun captureDecision(contextJson: String, policyJson: String): DayflowCaptureDecision =
        DayflowCaptureDecision(false, "core_unavailable")

    override fun project(envelopes: List<DayflowEventEnvelope>, accountRootKey: ByteArray): String {
        error("Dayflow Rust bindings are not packaged for this build")
    }

    override fun rekey(
        envelopes: List<DayflowEventEnvelope>,
        sourceKeyRing: DayflowAndroidAccountKeyRing,
        destinationKeyRing: DayflowAndroidAccountKeyRing,
    ): List<DayflowEventEnvelope> = error("Dayflow Rust bindings are not packaged for this build")

    override fun seal(
        payloadJson: String,
        eventId: String,
        deviceId: String,
        logicalClock: ULong,
        accountRootKey: ByteArray,
    ): DayflowEventEnvelope = error("Dayflow Rust bindings are not packaged for this build")

    override fun wrapAccountKey(
        accountRootKey: ByteArray,
        recipientDeviceId: String,
        recipientPublicKey: ByteArray,
    ): String = error("Dayflow Rust bindings are not packaged for this build")

    override fun unwrapAccountKey(wrappedKeyJson: String, privateKey: ByteArray): ByteArray =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun exportRecoveryKit(keyRing: DayflowAndroidAccountKeyRing, passphrase: String): String =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun restoreRecoveryKeyRing(kitJson: String, passphrase: String): DayflowAndroidAccountKeyRing =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun project(envelopes: List<DayflowEventEnvelope>, keyRing: DayflowAndroidAccountKeyRing): String =
        error("Dayflow Rust bindings are not packaged for this build")

    override fun seal(
        payloadJson: String,
        eventId: String,
        deviceId: String,
        logicalClock: ULong,
        keyVersion: UInt,
        accountRootKey: ByteArray,
    ): DayflowEventEnvelope = error("Dayflow Rust bindings are not packaged for this build")

    override fun wrapAccountKey(
        accountRootKey: ByteArray,
        keyVersion: UInt,
        recipientDeviceId: String,
        recipientPublicKey: ByteArray,
    ): String = error("Dayflow Rust bindings are not packaged for this build")

}
