package app.dayflow.android

import android.content.Context
import android.database.sqlite.SQLiteException
import android.util.Base64
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.SecureRandom
import java.time.LocalDate
import java.time.format.DateTimeFormatter

data class DayflowAndroidRelayDevice(
    val deviceId: String,
    val publicKey: String,
    val signingPublicKey: String,
    val status: String,
    /** True only for a brand-new first device admitted by the relay. */
    val keyBootstrapRequired: Boolean = false,
)

data class DayflowAndroidSyncOutcome(
    val status: String,
    val pushed: Int,
    val pulled: Int,
    val notificationHints: Int = 0,
)

data class DayflowAndroidNotificationHints(
    val cursor: String,
    val count: Int,
)

class DayflowAndroidRelayException(
    val statusCode: Int,
    message: String,
) : IllegalStateException(message)

internal object DayflowAndroidSharedSettingContract {
    private val datedKeyPattern = Regex(
        """^(day_goal|daily_standup):\d{4}-\d{2}-\d{2}$""",
    )

    fun isAllowedKey(key: String): Boolean {
        if (key == "dayflow.theme" ||
            key == "dayflow.capture.paused" ||
            key == "dayflow.logical_day_boundary_hour"
        ) {
            return true
        }
        if (!datedKeyPattern.matches(key)) return false
        val day = key.substringAfter(':')
        return runCatching {
            LocalDate.parse(day, DateTimeFormatter.ISO_LOCAL_DATE).toString() == day
        }.getOrDefault(false)
    }
}

/** Native Android transport for the opaque relay and its signed device routes. */
class DayflowAndroidSyncRelayClient(
    private val baseUrl: String,
    private val core: DayflowCoreBridge = UniFFIDayflowCoreBridge,
) {
    init {
        require(isAllowedRelayUrl(baseUrl)) {
            "Use an HTTPS Dayflow sync relay URL. HTTP is allowed only for localhost development."
        }
    }

    fun registerDevice(
        deviceId: String,
        publicKey: ByteArray,
        signingPublicKey: ByteArray,
        displayName: String,
        token: String,
        recoveryMode: Boolean,
        platform: String = "android",
    ): DayflowAndroidRelayDevice {
        val body = JSONObject()
            .put("device_id", deviceId)
            .put("public_key", Base64.encodeToString(publicKey, Base64.NO_WRAP))
            .put("signing_public_key", Base64.encodeToString(signingPublicKey, Base64.NO_WRAP))
            .put("display_name", displayName)
            .put("platform", platform)
            .put("recovery_mode", recoveryMode)
        return parseDevice(request("/v1/sync/devices", "POST", token, null, null, body.toString()))
    }

    fun listDevices(token: String): List<DayflowAndroidRelayDevice> {
        val devices = JSONArray(request("/v1/sync/devices", "GET", token, null, null, null))
        return buildList {
            for (index in 0 until devices.length()) add(parseDevice(devices.getJSONObject(index).toString()))
        }
    }

    fun approveDevice(
        targetDeviceId: String,
        token: String,
        approverDeviceId: String,
        signingPrivateKey: ByteArray,
        wrappedAccountKeyJson: String,
        keyVersion: UInt = 1u,
    ): DayflowAndroidRelayDevice {
        val body = JSONObject()
            .put("key_version", keyVersion.toLong())
            .put(
                "wrapped_account_key",
                Base64.encodeToString(wrappedAccountKeyJson.toByteArray(Charsets.UTF_8), Base64.NO_WRAP),
            )
            .put("wrapped_by_device_id", approverDeviceId)
        return parseDevice(
            request(
                "/v1/sync/devices/${encoded(targetDeviceId)}/approve",
                "POST",
                token,
                approverDeviceId,
                signingPrivateKey,
                body.toString(),
            ),
        )
    }

    fun revokeDevice(
        targetDeviceId: String,
        token: String,
        actorDeviceId: String,
        signingPrivateKey: ByteArray,
    ): DayflowAndroidRelayDevice = parseDevice(
        request(
            "/v1/sync/devices/${encoded(targetDeviceId)}/revoke",
            "POST",
            token,
            actorDeviceId,
            signingPrivateKey,
            null,
        ),
    )

    fun wrappedAccountKey(deviceId: String, token: String, signingPrivateKey: ByteArray): JSONObject? {
        val response = request(
            "/v1/sync/devices/${encoded(deviceId)}/wrapped-key",
            "GET",
            token,
            deviceId,
            signingPrivateKey,
            null,
        )
        return if (response == "null" || response.isBlank()) null else JSONObject(response)
    }

    fun wrappedAccountKeys(deviceId: String, token: String, signingPrivateKey: ByteArray): List<JSONObject> {
        val response = try {
            request(
                "/v1/sync/devices/${encoded(deviceId)}/wrapped-keys",
                "GET",
                token,
                deviceId,
                signingPrivateKey,
                null,
            )
        } catch (error: DayflowAndroidRelayException) {
            if (error.statusCode != 404) throw error
            val legacy = wrappedAccountKey(deviceId, token, signingPrivateKey)
            return legacy?.let { listOf(it) } ?: emptyList()
        }
        val values = JSONArray(response)
        return buildList {
            for (index in 0 until values.length()) add(values.getJSONObject(index))
        }
    }

    fun push(
        deviceId: String,
        token: String,
        signingPrivateKey: ByteArray,
        envelopes: List<DayflowEventEnvelope>,
    ): JSONObject {
        val body = JSONObject().put("envelopes", JSONArray().apply {
            envelopes.forEach { put(envelopeJson(it)) }
        })
        return JSONObject(request("/v1/sync/events", "POST", token, deviceId, signingPrivateKey, body.toString()))
    }

    fun pull(
        deviceId: String,
        token: String,
        signingPrivateKey: ByteArray,
        cursor: String?,
    ): Pair<String, List<DayflowEventEnvelope>> {
        val path = buildString {
            append("/v1/sync/events?limit=100")
            if (!cursor.isNullOrBlank()) append("&cursor=").append(encodedQuery(cursor))
        }
        val response = JSONObject(request(path, "GET", token, deviceId, signingPrivateKey, null))
        val events = response.optJSONArray("events") ?: JSONArray()
        val envelopes = buildList {
            for (index in 0 until events.length()) {
                add(parseEnvelope(events.getJSONObject(index).getJSONObject("envelope")))
            }
        }
        return response.getString("cursor") to envelopes
    }

    /**
     * Pulls content-free wake hints with a cursor independent from encrypted
     * event replay. The caller persists the cursor only after this response
     * has been decoded and validated.
     */
    fun pullNotificationHints(
        deviceId: String,
        token: String,
        signingPrivateKey: ByteArray,
        cursor: String?,
    ): DayflowAndroidNotificationHints {
        val path = buildString {
            append("/v1/sync/notifications?limit=100")
            if (!cursor.isNullOrBlank()) append("&cursor=").append(encodedQuery(cursor))
        }
        val response = JSONObject(request(path, "GET", token, deviceId, signingPrivateKey, null))
        val hints = response.optJSONArray("hints") ?: JSONArray()
        for (index in 0 until hints.length()) {
            val hint = hints.getJSONObject(index)
            require(hint.optString("kind") == "sync_available") {
                "The sync relay returned an unknown notification hint"
            }
            require(hint.optLong("sequence", 0L) > 0L) {
                "The sync relay returned an invalid notification hint sequence"
            }
        }
        return DayflowAndroidNotificationHints(response.getString("cursor"), hints.length())
    }

    /** Registers an OS push token; the relay accepts only a content-free wake address. */
    fun registerPushToken(
        deviceId: String,
        token: String,
        signingPrivateKey: ByteArray,
        pushToken: String,
    ): JSONObject {
        require(pushToken.isNotBlank()) { "A non-empty push token is required" }
        return JSONObject(
            request(
                "/v1/sync/notifications",
                "PUT",
                token,
                deviceId,
                signingPrivateKey,
                JSONObject().put("token", pushToken).toString(),
            ),
        )
    }

    fun unregisterPushToken(
        deviceId: String,
        token: String,
        signingPrivateKey: ByteArray,
    ): JSONObject = JSONObject(
        request(
            "/v1/sync/notifications",
            "DELETE",
            token,
            deviceId,
            signingPrivateKey,
            null,
        ),
    )

    private fun request(
        path: String,
        method: String,
        token: String,
        deviceId: String?,
        signingPrivateKey: ByteArray?,
        body: String?,
    ): String {
        val url = URL(baseUrl.trim().trimEnd('/') + path)
        val connection = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            instanceFollowRedirects = false
            useCaches = false
            connectTimeout = 30_000
            readTimeout = 30_000
            doInput = true
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Cookie", "")
        }
        if (body != null) {
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
        }
        if (deviceId != null) {
            require(signingPrivateKey?.size == 32)
            val timestamp = System.currentTimeMillis() / 1_000L
            val nonce = ByteArray(24).also { SecureRandom().nextBytes(it) }
                .let { Base64.encodeToString(it, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING) }
            val message = core.canonicalDeviceRequest(
                method,
                path,
                body?.toByteArray(Charsets.UTF_8) ?: ByteArray(0),
                timestamp,
                nonce,
                deviceId,
            )
            val signature = core.signRequest(message, signingPrivateKey)
            connection.setRequestProperty("X-Dayflow-Device-ID", deviceId)
            connection.setRequestProperty("X-Dayflow-Device-Timestamp", timestamp.toString())
            connection.setRequestProperty("X-Dayflow-Device-Nonce", nonce)
            connection.setRequestProperty(
                "X-Dayflow-Device-Signature",
                Base64.encodeToString(signature, Base64.NO_WRAP),
            )
        }
        if (body != null) {
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        }
        val status = connection.responseCode
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
        val response = stream?.bufferedReader()?.use { it.readText() } ?: ""
        connection.disconnect()
        if (status !in 200..299) {
            val message = runCatching { JSONObject(response).optString("message") }.getOrNull()
                ?.takeIf { it.isNotBlank() } ?: "The sync relay could not complete the request."
            throw DayflowAndroidRelayException(status, "Sync relay error ($status): $message")
        }
        return response
    }

    private fun parseDevice(value: String): DayflowAndroidRelayDevice {
        val json = JSONObject(value)
        return DayflowAndroidRelayDevice(
            deviceId = json.getString("device_id"),
            publicKey = json.getString("public_key"),
            signingPublicKey = json.getString("signing_public_key"),
            status = json.getString("status"),
            keyBootstrapRequired = json.optBoolean("key_bootstrap_required", false),
        )
    }

    private fun envelopeJson(envelope: DayflowEventEnvelope) = JSONObject()
        .put("event_id", envelope.eventId)
        .put("device_id", envelope.deviceId)
        .put("logical_clock", envelope.logicalClock.toLong())
        .put("schema_version", envelope.schemaVersion.toInt())
        .put("key_version", envelope.keyVersion.toLong())
        .put("nonce", envelope.nonce)
        .put("ciphertext", envelope.ciphertext)

    private fun parseEnvelope(json: JSONObject) = DayflowEventEnvelope(
        eventId = json.getString("event_id"),
        deviceId = json.getString("device_id"),
        // The relay serializes logical_clock as a JSON number. JSONObject's
        // getString only accepts an actual JSON string on Android, so using it
        // here made every non-empty pull fail before Rust could authenticate
        // and project the envelope. `toString` accepts the numeric JSON value
        // while still rejecting fractional or non-unsigned input below.
        logicalClock = json.get("logical_clock").toString().toULong(),
        schemaVersion = json.getInt("schema_version").toUShort(),
        keyVersion = json.getLong("key_version").toUInt(),
        nonce = json.getString("nonce"),
        ciphertext = json.getString("ciphertext"),
    )

    private fun encoded(value: String) = java.net.URLEncoder.encode(value, Charsets.UTF_8.name())
        .replace("+", "%20")

    private fun encodedQuery(value: String) = encoded(value)

    private companion object {
        fun isAllowedRelayUrl(value: String): Boolean {
            return DayflowAndroidEndpointPolicy.isAllowed(value)
        }
    }

}

/** End-to-end local-first Android/ChromeOS sync session. */
class DayflowAndroidSyncSession(
    context: Context,
    private val core: DayflowCoreBridge = UniFFIDayflowCoreBridge,
) {
    private val appContext = context.applicationContext
    private val keyStore = DayflowAndroidKeyStore(appContext)
    private val devicePreferences = appContext.getSharedPreferences("dayflow_device_identity", Context.MODE_PRIVATE)
    private val recoveryPreferences = appContext.getSharedPreferences("dayflow_recovery_state", Context.MODE_PRIVATE)

    companion object {
        const val LOCAL_WORKSPACE_ID = "local-workspace-v1"
        private const val PHYSICAL_DEVICE_ID_KEY = "physical-device-id"
    }

    /** Creates the device-local workspace before an account exists. */
    fun ensureLocalWorkspace() {
        if (keyStore.accountKeyRing(LOCAL_WORKSPACE_ID) == null) {
            keyStore.storeAccountKeyRing(
                LOCAL_WORKSPACE_ID,
                DayflowAndroidAccountKeyRing.fromRootKey(core.generateAccountRootKey()),
            )
        }
        physicalDeviceId()
    }

    fun hasLocalAccountKey(accountId: String): Boolean =
        runCatching {
            if (accountId.isBlank()) ensureLocalWorkspace()
            keyStore.accountKeyRing(workspaceId(accountId)) != null
        }.getOrDefault(false)

    fun pendingEventCount(accountId: String): Int =
        runCatching {
            DayflowLocalSyncStore(appContext, workspaceId(accountId)).use { it.pendingCount() }
        }.getOrDefault(0)

    fun syncHealth(accountId: String): DayflowAndroidSyncHealth =
        runCatching {
            DayflowLocalSyncStore(appContext, workspaceId(accountId)).use { it.syncHealth() }
        }.getOrDefault(DayflowAndroidSyncHealth())

    fun recordSyncHealth(
        accountId: String,
        state: DayflowAndroidSyncHealthState,
        failureCode: String? = null,
    ) {
        DayflowLocalSyncStore(appContext, workspaceId(accountId)).use {
            it.recordSyncHealth(state, failureCode)
        }
    }

    fun currentDeviceId(): String = physicalDeviceId()

    /**
     * Links records written while signed out into the canonical account
     * workspace. The Rust core re-encrypts opaque envelopes without changing
     * event identity, and the deterministic migration nonce makes retries
     * safe after a crash or interrupted sign-in.
     */
    fun linkLocalWorkspace(accountId: String) {
        require(accountId.isNotBlank()) { "A Dayflow account is required" }
        ensureLocalWorkspace()
        val linkedAccount = DayflowLocalSyncStore(appContext, LOCAL_WORKSPACE_ID).use { it.linkedAccountId() }
        require(linkedAccount == null || linkedAccount == accountId) {
            "This local workspace is already linked to another Dayflow account."
        }
        val sourceRing = keyStore.accountKeyRing(LOCAL_WORKSPACE_ID) ?: return
        val destinationRing = keyStore.accountKeyRing(accountId) ?: return
        val sourceEnvelopes = DayflowLocalSyncStore(appContext, LOCAL_WORKSPACE_ID).use { it.all() }
        DayflowLocalSyncStore(appContext, accountId).use { destinationStore ->
            sourceEnvelopes.forEach { envelope ->
                val sourceKey = sourceRing.keyData(envelope.keyVersion)
                val destinationKey = destinationRing.keyData(envelope.keyVersion)
                val candidate = if (sourceKey != null && destinationKey != null && sourceKey.contentEquals(destinationKey)) {
                    envelope
                } else {
                    core.rekey(listOf(envelope), sourceRing, destinationRing).single()
                }
                val existing = destinationStore.find(envelope.eventId)
                if (existing == null) {
                    destinationStore.enqueue(candidate)
                } else if (existing != candidate) {
                    val samePayload = runCatching {
                        core.project(listOf(envelope), sourceRing) == core.project(listOf(existing), destinationRing)
                    }.getOrDefault(false)
                    require(samePayload) {
                        "The account workspace already contains a different envelope for event ${envelope.eventId}."
                    }
                }
            }
            sourceEnvelopes.maxOfOrNull { it.logicalClock }?.let { maximumClock ->
                // The local and account stores share this device's identity.
                // Carry the source clock forward before the next account event
                // is allocated, otherwise sign-in could reuse a clock value.
                destinationStore.ensureLogicalClockAtLeast(maximumClock)
            }
        }
        DayflowLocalSyncStore(appContext, LOCAL_WORKSPACE_ID).use { localStore ->
            // Keep local ciphertext and its local key-ring. SQLite and the
            // platform secure store cannot commit atomically; leaving the
            // source mirror untouched makes a crash at any point retryable.
            localStore.setLinkedAccountId(accountId)
        }
    }

    suspend fun sync(
        accountId: String,
        token: String,
        relayUrl: String,
        displayName: String,
        recoveryMode: Boolean = false,
    ): DayflowAndroidSyncOutcome = withContext(Dispatchers.IO) {
        require(accountId.isNotBlank() && token.isNotBlank())
        val store = DayflowLocalSyncStore(appContext, accountId)
        try {
            val deviceId = physicalDeviceId()
            val deviceKeys = keyStore.deviceMaterial(accountId) ?: core.generateDeviceKeyMaterial().also {
                keyStore.store(accountId, "device-private-v1", it.privateKey)
                keyStore.store(accountId, "device-public-v1", it.publicKey)
            }
            val signingKeys = keyStore.signingMaterial(accountId) ?: core.generateDeviceSigningKeyMaterial().also {
                keyStore.store(accountId, "signing-private-v1", it.privateKey)
                keyStore.store(accountId, "signing-public-v1", it.publicKey)
            }
            val client = DayflowAndroidSyncRelayClient(relayUrl, core)
            val recoveryRegistration = recoveryMode || recoveryPreferences.getBoolean(accountId, false)
            val registration = client.registerDevice(
                deviceId = deviceId,
                publicKey = deviceKeys.publicKey,
                signingPublicKey = signingKeys.publicKey,
                displayName = displayName,
                token = token,
                recoveryMode = recoveryRegistration,
                platform = if (appContext.packageManager.hasSystemFeature("org.chromium.arc")) "chromeos" else "android",
            )
            if (registration.status != "approved") {
                store.recordSyncHealth(DayflowAndroidSyncHealthState.WAITING_FOR_APPROVAL)
                return@withContext DayflowAndroidSyncOutcome("waiting_for_approval", 0, 0)
            }
            var keyRing = keyStore.accountKeyRing(accountId)
            if (registration.keyBootstrapRequired) {
                if (keyRing == null) {
                    val generatedKeyRing = DayflowAndroidAccountKeyRing.fromRootKey(core.generateAccountRootKey())
                    keyRing = generatedKeyRing
                    keyStore.storeAccountKeyRing(accountId, generatedKeyRing)
                }
                // The relay consumes the one-time bootstrap grant after the
                // first accepted event, so preserve the local admission across
                // the next restart when no wrapped key is returned.
                keyStore.markAccountKeyAdmitted(accountId)
            }
            val wrappedKeys = client.wrappedAccountKeys(deviceId, token, signingKeys.privateKey)
            if (keyRing != null && !registration.keyBootstrapRequired && !recoveryRegistration && !keyStore.hasAccountKeyAdmission(accountId) && wrappedKeys.isEmpty()) {
                error(
                    "This local account key was not admitted by the sync relay. Restore a recovery kit or receive an approved device key before syncing."
                )
            }
            wrappedKeys.forEach { wrapped ->
                val wrappedValue = Base64.decode(wrapped.getString("wrapped_account_key"), Base64.DEFAULT)
                val wrappedDocument = JSONObject(String(wrappedValue, Charsets.UTF_8))
                val relayVersion = wrapped.optLong("key_version", 1L)
                require(relayVersion in 1L..UInt.MAX_VALUE.toLong()) {
                    "The wrapped account-key version is invalid"
                }
                val wrappedVersion = wrappedDocument.optLong("key_version", 1L)
                require(wrappedVersion == relayVersion) {
                    "The wrapped account-key version does not match its authenticated document"
                }
                require(wrappedDocument.optString("recipient_device_id") == deviceId) {
                    "The wrapped account key was issued to a different device"
                }
                val keyVersion = wrappedVersion.toUInt()
                val wrappedRootKey = parseRootKey(
                    core.unwrapAccountKey(String(wrappedValue, Charsets.UTF_8), deviceKeys.privateKey),
                )
                keyRing = if (keyRing == null) {
                    DayflowAndroidAccountKeyRing.fromKeysForSync(keyVersion, wrappedRootKey)
                } else {
                    val existingKey = keyRing.keyData(keyVersion)
                    if (existingKey != null) {
                        require(existingKey.contentEquals(wrappedRootKey)) {
                            "The relay returned a different account key for an existing key version"
                        }
                        keyRing
                    } else {
                        keyRing.adding(
                            wrappedRootKey,
                            keyVersion,
                            active = keyVersion > keyRing.activeKeyVersion,
                        )
                    }
                }
                keyStore.storeAccountKeyRing(accountId, keyRing)
                keyStore.markAccountKeyAdmitted(accountId)
            }
            if (keyRing == null) {
                error(
                    "The encrypted account key was not delivered. Restore a Dayflow recovery kit or approve this device from an existing device."
                )
            }
            val resolvedKeyRing = keyRing
            if (recoveryRegistration) keyStore.markAccountKeyAdmitted(accountId)

            linkLocalWorkspace(accountId)

            var pushed = 0
            while (true) {
                val pending = store.pending()
                if (pending.isEmpty()) break
                val response = client.push(deviceId, token, signingKeys.privateKey, pending)
                val accepted = response.optJSONArray("accepted_event_ids") ?: JSONArray()
                val duplicates = response.optJSONArray("duplicate_event_ids") ?: JSONArray()
                val ids = buildList {
                    for (i in 0 until accepted.length()) add(accepted.getString(i))
                    for (i in 0 until duplicates.length()) add(duplicates.getString(i))
                }
                pushed += store.acknowledge(ids)
                if (ids.isEmpty()) break
            }

            var cursor = store.cursor()
            var pulled = 0
            while (true) {
                val result = client.pull(deviceId, token, signingKeys.privateKey, cursor)
                // Authenticate each relay envelope through Rust before SQLite
                // persistence. This also rejects changed ciphertext for an event
                // ID that was already delivered previously.
                result.second.forEach { envelope ->
                    core.project(listOf(envelope), resolvedKeyRing)
                }
                pulled += store.merge(result.second)
                cursor = result.first
                store.setCursor(cursor)
                if (result.second.isEmpty()) break
            }
            var notificationHintCount = 0
            runCatching {
                client.pullNotificationHints(
                    deviceId,
                    token,
                    signingKeys.privateKey,
                    store.notificationCursor(),
                )
            }.onSuccess { hints ->
                notificationHintCount = hints.count
                store.setNotificationCursor(hints.cursor)
            }.onFailure { error ->
                // Hints are advisory wake signals. Keep encrypted event sync
                // successful and retry the unchanged hint cursor next time.
                println("[DayflowAndroid] Notification hints unavailable: ${error.message}")
            }
            core.project(store.all(), resolvedKeyRing)
            store.recordSyncHealth(DayflowAndroidSyncHealthState.SYNCED)
            // Keep recovery registration enabled until the complete
            // encrypted sync succeeds. A later network, projection, or local
            // write failure must remain retryable as a recovery restore.
            if (recoveryRegistration) {
                check(recoveryPreferences.edit().remove(accountId).commit()) {
                    "Android recovery state could not be cleared after sync."
                }
            }
            DayflowAndroidSyncOutcome("synced", pushed, pulled, notificationHintCount)
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            runCatching {
                store.recordSyncHealth(
                    DayflowAndroidSyncHealthState.FAILED,
                    syncFailureCode(error),
                )
            }
            throw error
        } finally {
            store.close()
        }
    }

    suspend fun listDevices(
        token: String,
        relayUrl: String,
    ): List<DayflowAndroidRelayDevice> = withContext(Dispatchers.IO) {
        DayflowAndroidSyncRelayClient(relayUrl, core).listDevices(token)
    }

    suspend fun registerPushToken(
        accountId: String,
        token: String,
        relayUrl: String,
        pushToken: String,
    ): JSONObject = withContext(Dispatchers.IO) {
        val signingKeys = keyStore.signingMaterial(accountId)
            ?: error("The device signing key is not initialized")
        DayflowAndroidSyncRelayClient(relayUrl, core).registerPushToken(
            deviceId = physicalDeviceId(),
            token = token,
            signingPrivateKey = signingKeys.privateKey,
            pushToken = pushToken,
        )
    }

    suspend fun unregisterPushToken(
        accountId: String,
        token: String,
        relayUrl: String,
    ): JSONObject = withContext(Dispatchers.IO) {
        val signingKeys = keyStore.signingMaterial(accountId)
            ?: error("The device signing key is not initialized")
        DayflowAndroidSyncRelayClient(relayUrl, core).unregisterPushToken(
            deviceId = physicalDeviceId(),
            token = token,
            signingPrivateKey = signingKeys.privateKey,
        )
    }

    fun exportRecoveryKit(accountId: String, passphrase: String): String {
        require(passphrase.length >= 8) { "Use a recovery passphrase of at least eight characters." }
        val keyRing = keyStore.accountKeyRing(accountId)
            ?: error("The account key-ring is not initialized")
        return core.exportRecoveryKit(keyRing, passphrase)
    }

    fun restoreRecoveryKit(accountId: String, kitJson: String, passphrase: String) {
        require(kitJson.isNotBlank()) { "Paste a Dayflow recovery kit before restoring it." }
        require(passphrase.isNotBlank()) { "Enter the recovery kit passphrase." }
        val keyRing = runCatching {
            core.restoreRecoveryKeyRing(kitJson, passphrase)
        }.getOrElse {
            DayflowAndroidAccountKeyRing.fromRootKey(core.restoreRecoveryKey(kitJson, passphrase))
        }
        keyStore.storeAccountKeyRing(accountId, keyRing)
        check(recoveryPreferences.edit().putBoolean(accountId, true).commit()) {
            "Android recovery state could not be committed."
        }
    }

    suspend fun approveDevice(
        accountId: String,
        token: String,
        relayUrl: String,
        targetDeviceId: String,
        keyVersion: UInt? = null,
    ): DayflowAndroidRelayDevice = withContext(Dispatchers.IO) {
        val keyRing = keyStore.accountKeyRing(accountId)
            ?: error("The account key-ring is not initialized")
        val signingKeys = keyStore.signingMaterial(accountId)
            ?: error("The device signing key is not initialized")
        val actorDeviceId = deviceId(accountId)
        val target = DayflowAndroidSyncRelayClient(relayUrl, core).listDevices(token)
            .firstOrNull { it.deviceId == targetDeviceId }
            ?: error("The target device is not registered")
        val targetPublicKey = Base64.decode(target.publicKey, Base64.DEFAULT)
        val versions = keyVersion?.let { listOf(it) } ?: keyRing.versions()
        require(versions.isNotEmpty()) { "No account key versions are retained on this device" }
        var approved: DayflowAndroidRelayDevice? = null
        val relay = DayflowAndroidSyncRelayClient(relayUrl, core)
        versions.forEach { version ->
            val rootKey = keyRing.keyData(version)
                ?: error("The requested account key version is not retained on this device")
            val wrapped = core.wrapAccountKey(rootKey, version, targetDeviceId, targetPublicKey)
            approved = relay.approveDevice(
                targetDeviceId,
                token,
                actorDeviceId,
                signingKeys.privateKey,
                wrapped,
                version,
            )
        }
        approved ?: error("The device approval did not return a device")
    }

    /**
     * Rotates the account key only after every currently approved peer has
     * received a wrapped copy. Older versions stay in the local key-ring so
     * historical events remain decryptable.
     */
    suspend fun rotateEncryptionKey(
        accountId: String,
        token: String,
        relayUrl: String,
    ): UInt = withContext(Dispatchers.IO) {
        val currentKeyRing = keyStore.accountKeyRing(accountId)
            ?: error("The account key-ring is not initialized")
        val signingKeys = keyStore.signingMaterial(accountId)
            ?: error("The device signing key is not initialized")
        val actorDeviceId = deviceId(accountId)
        val candidateKeyRing = keyStore.pendingAccountKeyRing(accountId)
            ?.takeIf { it.activeKeyVersion > currentKeyRing.activeKeyVersion }
            ?: run {
                keyStore.clearPendingAccountKeyRing(accountId)
                val currentVersion = currentKeyRing.versions().maxOrNull()
                    ?: error("No account key versions are retained on this device")
                require(currentVersion < UInt.MAX_VALUE) { "The account key version limit has been reached" }
                val nextVersion = currentVersion + 1u
                val nextRootKey = core.generateAccountRootKey()
                currentKeyRing.adding(nextRootKey, nextVersion, active = true)
                    .also { keyStore.storePendingAccountKeyRing(accountId, it) }
            }
        val nextVersion = candidateKeyRing.activeKeyVersion
        val nextRootKey = candidateKeyRing.keyData(nextVersion)
            ?: error("The pending account key-ring is invalid")
        val relay = DayflowAndroidSyncRelayClient(relayUrl, core)
        val peers = relay.listDevices(token).filter { device ->
            device.status == "approved" && device.deviceId != actorDeviceId
        }

        peers.forEach { peer ->
            val peerPublicKey = Base64.decode(peer.publicKey, Base64.DEFAULT)
            val wrapped = core.wrapAccountKey(
                nextRootKey,
                nextVersion,
                peer.deviceId,
                peerPublicKey,
            )
            relay.approveDevice(
                targetDeviceId = peer.deviceId,
                token = token,
                approverDeviceId = actorDeviceId,
                signingPrivateKey = signingKeys.privateKey,
                wrappedAccountKeyJson = wrapped,
                keyVersion = nextVersion,
            )
        }

        keyStore.storeAccountKeyRing(accountId, candidateKeyRing)
        keyStore.clearPendingAccountKeyRing(accountId)
        nextVersion
    }

    suspend fun revokeDevice(
        accountId: String,
        token: String,
        relayUrl: String,
        targetDeviceId: String,
    ): DayflowAndroidRelayDevice = withContext(Dispatchers.IO) {
        val signingKeys = keyStore.signingMaterial(accountId)
            ?: error("The device signing key is not initialized")
        DayflowAndroidSyncRelayClient(relayUrl, core).revokeDevice(
            targetDeviceId,
            token,
            deviceId(accountId),
            signingKeys.privateKey,
        )
    }

    fun enqueueCaptureDerived(
        accountId: String,
        captureId: String,
        day: String,
        startTimestamp: Long,
        endTimestamp: Long,
        title: String,
        summary: String,
        category: String,
        source: String = "android_media_projection",
        derivationMode: String = "privacy_gated_local_metadata",
    ) {
        require(captureId.isNotBlank() && day.isNotBlank())
        require(source.isNotBlank() && derivationMode.isNotBlank())
        // Capture is allowed to continue in the local workspace while an
        // account is pending approval. Do not trust a stale caller-provided
        // account ID to bypass that admission boundary.
        val workspace = captureWorkspaceId(accountId)
        val keyRing = keyStore.accountKeyRing(workspace)
            ?: error("The account key-ring is not initialized")
        val rootKey = keyRing.keyData(keyRing.activeKeyVersion)
            ?: error("The active account key is not initialized")
        val deviceId = physicalDeviceId()
        DayflowLocalSyncStore(appContext, workspace).use { store ->
            val eventId = "$deviceId:capture:$captureId"
            val payload = JSONObject()
                .put("kind", "CaptureDerived")
                .put("value", JSONObject()
                    .put("id", eventId)
                    .put("day", day)
                    .put("start_timestamp", startTimestamp)
                    .put("end_timestamp", endTimestamp)
                    .put("title", title)
                    .put("summary", summary)
                    .put("category", category)
                    .put("source", source)
                    .put("derivation_mode", derivationMode))
                .toString()
            store.enqueue(core.seal(payload, eventId, deviceId, store.nextLogicalClock(), keyRing.activeKeyVersion, rootKey))
        }
    }

    fun enqueueJournal(accountId: String, day: String, body: String) {
        val normalizedBody = body.trim()
        require(day.isNotBlank() && normalizedBody.isNotBlank())
        val workspace = workspaceId(accountId)
        val keyRing = keyStore.accountKeyRing(workspace)
            ?: error("The account key-ring is not initialized")
        val rootKey = keyRing.keyData(keyRing.activeKeyVersion)
            ?: error("The active account key is not initialized")
        val deviceId = physicalDeviceId()
        DayflowLocalSyncStore(appContext, workspace).use { store ->
            val eventId = "$deviceId:journal:${java.util.UUID.randomUUID()}"
            val aggregateId = "mac:v1:journal:$day"
            val payload = JSONObject()
                .put("kind", "JournalUpsert")
                .put("value", JSONObject()
                    .put("id", aggregateId)
                    .put("day", day)
                    .put("body", normalizedBody))
                .toString()
            store.enqueue(core.seal(payload, eventId, deviceId, store.nextLogicalClock(), keyRing.activeKeyVersion, rootKey))
        }
    }

    fun enqueuePriority(
        accountId: String,
        day: String,
        text: String,
        rank: Int,
        status: String = "open",
        stableId: String? = null,
    ) {
        val normalizedDay = day.trim()
        val normalizedText = text.trim()
        val normalizedStatus = status.trim().ifBlank { "open" }
        require(normalizedDay.isNotBlank() && normalizedText.isNotBlank())
        require(rank >= 0) { "Priority rank cannot be negative" }
        val deviceId = physicalDeviceId()
        val eventId = "$deviceId:priority:${java.util.UUID.randomUUID()}"
        val aggregateId = stableId?.trim().takeUnless { it.isNullOrBlank() }
            ?: "dayflow:v1:priority:${java.util.UUID.randomUUID()}"
        val payload = JSONObject()
            .put("kind", "PriorityUpsert")
            .put("value", JSONObject()
                .put("id", aggregateId)
                .put("day", normalizedDay)
                .put("rank", rank)
                .put("text", normalizedText)
                .put("status", normalizedStatus))
            .toString()
        enqueuePayload(accountId, eventId, payload)
    }

    fun enqueueReflection(
        accountId: String,
        day: String,
        body: String,
    ) {
        val normalizedDay = day.trim()
        val normalizedBody = body.trim()
        require(normalizedDay.isNotBlank() && normalizedBody.isNotBlank())
        val deviceId = physicalDeviceId()
        val eventId = "$deviceId:reflection:${java.util.UUID.randomUUID()}"
        val payload = JSONObject()
            .put("kind", "ReflectionUpsert")
            .put("value", JSONObject()
                // The logical-day aggregate is shared with the Mac writer so
                // editing a reflection on another device updates the same row.
                .put("id", "mac:v1:reflection:$normalizedDay")
                .put("day", normalizedDay)
                .put("body", normalizedBody))
            .toString()
        enqueuePayload(accountId, eventId, payload)
    }

    /**
     * Append a deletion operation for a stable projection aggregate. Deletes
     * are events too: another device can replay the same tombstone, and a
     * later edit can intentionally recreate the aggregate.
     */
    fun enqueueTombstone(accountId: String, targetId: String) {
        val normalizedTargetId = targetId.trim()
        require(normalizedTargetId.isNotBlank()) { "A tombstone target is required" }
        val deviceId = physicalDeviceId()
        val eventId = "$deviceId:tombstone:${java.util.UUID.randomUUID()}"
        val payload = JSONObject()
            .put("kind", "Tombstone")
            .put("value", JSONObject().put("target_id", normalizedTargetId))
            .toString()
        enqueuePayload(accountId, eventId, payload)
    }

    fun enqueueSetting(accountId: String, key: String, value: String) {
        val normalizedKey = key.trim()
        val normalizedValue = value.trim()
        require(normalizedKey.isNotBlank())
        require(
            DayflowAndroidSharedSettingContract.isAllowedKey(normalizedKey),
        ) { "Only non-secret Dayflow settings can be shared" }
        if (normalizedKey == "dayflow.capture.paused") {
            require(normalizedValue == "true" || normalizedValue == "false") {
                "Capture pause must be true or false"
            }
        }
        val deviceId = physicalDeviceId()
        val eventId = "$deviceId:setting:${java.util.UUID.randomUUID()}"
        val payload = JSONObject()
            .put("kind", "SettingUpsert")
            .put("value", JSONObject()
                .put("key", normalizedKey)
                .put("value", normalizedValue))
            .toString()
        enqueuePayload(accountId, eventId, payload)
    }

    private fun enqueuePayload(accountId: String, eventId: String, payload: String) {
        val workspace = workspaceId(accountId)
        val keyRing = keyStore.accountKeyRing(workspace)
            ?: error("The account key-ring is not initialized")
        val rootKey = keyRing.keyData(keyRing.activeKeyVersion)
            ?: error("The active account key is not initialized")
        val deviceId = physicalDeviceId()
        DayflowLocalSyncStore(appContext, workspace).use { store ->
            store.enqueue(core.seal(payload, eventId, deviceId, store.nextLogicalClock(), keyRing.activeKeyVersion, rootKey))
        }
    }

    fun projectLocal(accountId: String): String {
        val workspace = workspaceId(accountId)
        val keyRing = keyStore.accountKeyRing(workspace)
            ?: error("The account key-ring is not initialized")
        DayflowLocalSyncStore(appContext, workspace).use { store ->
            val projection = core.project(store.all(), keyRing)
            return projection
        }
    }

    private fun parseRootKey(value: ByteArray): ByteArray = value.also {
        require(it.size == 32) { "The shared core returned an invalid account key" }
    }

    private fun workspaceId(accountId: String): String = accountId.trim().ifBlank { LOCAL_WORKSPACE_ID }

    private fun physicalDeviceId(): String =
        devicePreferences.getString(PHYSICAL_DEVICE_ID_KEY, null)
            ?: java.util.UUID.randomUUID().toString().lowercase()
                .also {
                    check(devicePreferences.edit().putString(PHYSICAL_DEVICE_ID_KEY, it).commit()) {
                        "Android device identity could not be committed."
                    }
                }

    private fun deviceId(accountId: String): String = physicalDeviceId()

    private fun captureWorkspaceId(accountId: String): String {
        val normalized = accountId.trim()
        return normalized.takeIf {
            it.isNotBlank() && keyStore.hasAccountKeyAdmission(it)
        } ?: LOCAL_WORKSPACE_ID
    }

    private fun syncFailureCode(error: Throwable): String = when {
        error is DayflowAndroidRelayException && error.statusCode in 401..403 -> "authentication"
        error is DayflowAndroidRelayException && error.statusCode == 409 -> "admission"
        error is DayflowAndroidRelayException && error.statusCode >= 500 -> "relay_server"
        error is DayflowAndroidRelayException -> "invalid_response"
        error is SQLiteException -> "local_storage"
        error is org.json.JSONException -> "invalid_response"
        error is java.io.IOException -> "relay_server"
        else -> "unknown"
    }
}
