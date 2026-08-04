package app.dayflow.android

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalTime

data class DayflowAndroidAccountSession(
    val accountId: String,
    val token: String,
    val authUrl: String,
    val email: String,
    val relayUrl: String,
    val displayName: String,
)

data class DayflowAndroidAppState(
    val authUrl: String = "",
    val email: String = "",
    val verificationCode: String = "",
    val authMessage: String? = null,
    val accountId: String = "",
    val token: String = "",
    val relayUrl: String = "",
    val displayName: String = "This Android device",
    val status: String = "Not connected",
    val canCapture: Boolean = false,
    val pendingEventCount: Int = 0,
    val syncHealth: DayflowAndroidSyncHealth = DayflowAndroidSyncHealth(),
    val currentDeviceId: String? = null,
    val devices: List<DayflowAndroidRelayDevice> = emptyList(),
    val projection: DayflowAndroidProjection = DayflowAndroidProjection(),
    val journalDay: String = "",
    val journalBody: String = "",
    val journalMessage: String? = null,
    val priorityDay: String = "",
    val priorityText: String = "",
    val priorityMessage: String? = null,
    val reflectionDay: String = "",
    val reflectionBody: String = "",
    val reflectionMessage: String? = null,
    val sharedSettingKey: String = "dayflow.capture.paused",
    val sharedSettingValue: String = "false",
    val sharedSettingMessage: String? = null,
    val chatQuestion: String = "",
    val chatAnswer: String? = null,
    val chatMessage: String? = null,
    val isChatting: Boolean = false,
    val recoveryPassphrase: String = "",
    val recoveryKitText: String = "",
    val recoveryMessage: String? = null,
    val providerId: String = DayflowAIProviderIds.LOCAL,
    val providerEndpoint: String = "http://127.0.0.1:11434",
    val providerModelId: String = "llama3.2",
    val providerApiKey: String = "",
    val providerMessage: String? = null,
    val isRotatingKey: Boolean = false,
    val rotationMessage: String? = null,
) {
    fun syncHealthSummary(nowMillis: Long = System.currentTimeMillis()): String =
        syncHealth.summary(pendingEventCount, nowMillis)
}

/** Account session storage backed by Android Keystore encryption. */
class DayflowAndroidAccountStore(private val keyStore: DayflowAndroidKeyStore) {
    private val account = "active-session"
    private val sessionName = "account-session-v1"

    fun load(): DayflowAndroidAccountSession? = keyStore.loadText(account, sessionName)?.let { value ->
        runCatching {
            val json = JSONObject(value)
            DayflowAndroidAccountSession(
                accountId = json.getString("account_id"),
                token = json.getString("token"),
                authUrl = json.optString("auth_url", ""),
                email = json.optString("email", ""),
                relayUrl = json.getString("relay_url"),
                displayName = json.getString("display_name"),
            )
        }.getOrNull() ?: run {
            val parts = value.split("\u0000", limit = 4)
            if (parts.size != 4) null else DayflowAndroidAccountSession(parts[0], parts[1], "", "", parts[2], parts[3])
        }
    }

    fun save(session: DayflowAndroidAccountSession) {
        keyStore.storeText(
            account,
            sessionName,
            JSONObject()
                .put("account_id", session.accountId)
                .put("token", session.token)
                .put("auth_url", session.authUrl)
                .put("email", session.email)
                .put("relay_url", session.relayUrl)
                .put("display_name", session.displayName)
                .toString(),
        )
    }

    fun clear() = keyStore.delete(account, sessionName)
}

/**
 * Connects the Compose shell to the same account-scoped sync, device
 * administration, provider storage, and local-first state used by capture.
 */
class DayflowAndroidAppModel(
    context: Context,
    private val core: DayflowCoreBridge = UniFFIDayflowCoreBridge,
) {
    private val appContext = context.applicationContext
    private val keyStore = DayflowAndroidKeyStore(appContext)
    private val accountStore = DayflowAndroidAccountStore(keyStore)
    private val providerStore = DayflowAIProviderStore(keyStore)
    private val syncSession = DayflowAndroidSyncSession(appContext, core)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(loadInitialState())
    private var syncJob: Job? = null
    private var sessionGeneration = 0

    val state: StateFlow<DayflowAndroidAppState> = mutableState.asStateFlow()

    fun setAccountId(value: String) = update {
        it.copy(
            accountId = value,
            canCapture = syncSession.hasLocalAccountKey(activeWorkspaceId(value)),
        )
    }
    fun setToken(value: String) = update { it.copy(token = value) }
    fun setRelayUrl(value: String) = update { it.copy(relayUrl = value) }
    fun setDisplayName(value: String) = update { it.copy(displayName = value) }
    fun setAuthUrl(value: String) = update { it.copy(authUrl = value) }
    fun setEmail(value: String) = update { it.copy(email = value) }
    fun setVerificationCode(value: String) = update { it.copy(verificationCode = value) }
    fun setProviderId(value: String) = update { it.copy(providerId = value) }
    fun setProviderEndpoint(value: String) = update { it.copy(providerEndpoint = value) }
    fun setProviderModelId(value: String) = update { it.copy(providerModelId = value) }
    fun setProviderApiKey(value: String) = update { it.copy(providerApiKey = value) }
    fun setJournalDay(value: String) = update { it.copy(journalDay = value) }
    fun setJournalBody(value: String) = update { it.copy(journalBody = value) }
    fun setPriorityDay(value: String) = update { it.copy(priorityDay = value) }
    fun setPriorityText(value: String) = update { it.copy(priorityText = value) }
    fun setReflectionDay(value: String) = update { it.copy(reflectionDay = value) }
    fun setReflectionBody(value: String) = update { it.copy(reflectionBody = value) }
    fun setSharedSettingKey(value: String) = update { it.copy(sharedSettingKey = value) }
    fun setSharedSettingValue(value: String) = update { it.copy(sharedSettingValue = value) }
    fun setChatQuestion(value: String) = update { it.copy(chatQuestion = value) }
    fun setRecoveryPassphrase(value: String) = update { it.copy(recoveryPassphrase = value) }
    fun setRecoveryKitText(value: String) = update { it.copy(recoveryKitText = value) }

    /**
     * Capture must use the same workspace decision as journal and timeline
     * writes. A signed-in device that is still pending approval may continue
     * capturing locally, but it must not hand an unadmitted account ID to the
     * foreground service.
     */
    fun captureAccountId(): String? = activeWorkspaceId(state.value.accountId).takeIf { it.isNotBlank() }

    fun sync() {
        if (syncJob?.isActive == true) return
        val current = state.value
        val generation = sessionGeneration
        update { it.copy(status = "Syncing encrypted events…") }
        syncJob = scope.launch {
            try {
                val session = accountSession(current)
                accountStore.save(session)
                val result = syncSession.sync(
                    accountId = session.accountId,
                    token = session.token,
                    relayUrl = session.relayUrl,
                    displayName = session.displayName,
                )
                val devices = syncSession.listDevices(session.token, session.relayUrl)
                val currentDeviceId = syncSession.currentDeviceId()
                val projection = if (result.status == "waiting_for_approval") {
                    current.projection
                } else {
                    DayflowAndroidProjection.fromJson(syncSession.projectLocal(session.accountId))
                }
                if (generation != sessionGeneration) return@launch
                val syncHealth = syncSession.syncHealth(session.accountId)
                update {
                    it.copy(
                        status = result.statusLabel(),
                        devices = devices,
                        currentDeviceId = currentDeviceId,
                        canCapture = syncSession.hasLocalAccountKey(activeWorkspaceId(session.accountId)),
                        pendingEventCount = syncSession.pendingEventCount(activeWorkspaceId(session.accountId)),
                        syncHealth = syncHealth,
                        projection = projection,
                        journalDay = it.journalDay.ifBlank { defaultLogicalDay() },
                    )
                }
                loadProvider(
                    activeWorkspaceId(session.accountId)
                        .ifBlank { DayflowAndroidSyncSession.LOCAL_WORKSPACE_ID },
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (generation == sessionGeneration) {
                    update {
                        it.copy(
                            status = error.message ?: "Sync failed",
                            syncHealth = syncSession.syncHealth(current.accountId),
                        )
                    }
                }
            } finally {
                syncJob = null
            }
        }
    }

    /**
     * Reconnects an already configured account when the app returns to the
     * foreground. This deliberately does nothing for signed-out or partially
     * configured state so local-first use never causes an unexpected request.
     */
    fun syncIfConfigured() {
        val current = state.value
        if (current.accountId.isBlank()
            || current.token.isBlank()
            || current.relayUrl.isBlank()
            || current.displayName.isBlank()
        ) return
        sync()
    }

    /**
     * Runs a content-free background wake through the same guarded sync job
     * used by foreground activation. The wake payload is only a signal; the
     * encrypted event cursor and local projection remain the source of truth.
     */
    suspend fun syncForPushWake() {
        val current = state.value
        if (current.accountId.isBlank()
            || current.token.isBlank()
            || current.relayUrl.isBlank()
            || current.displayName.isBlank()
        ) return
        syncIfConfigured()
        syncJob?.join()
    }

    fun requestSignInCode() {
        val current = state.value
        scope.launch {
            runCatching { DayflowAndroidAuthClient(current.authUrl).requestCode(current.email) }
                .onSuccess { update { it.copy(authMessage = "Sign-in code sent. Check your email.") } }
                .onFailure { error -> update { it.copy(authMessage = error.message ?: "Sign-in failed") } }
        }
    }

    fun verifySignInCode() {
        val current = state.value
        scope.launch {
            runCatching {
                DayflowAndroidAuthClient(current.authUrl).verifyCode(
                    current.email,
                    current.verificationCode,
                    current.displayName,
                )
            }.onSuccess { result ->
                update {
                    it.copy(
                        accountId = result.accountId,
                        token = result.token,
                        email = result.email,
                        authMessage = "Signed in. Connecting this device…",
                    )
                }
                sync()
            }.onFailure { error -> update { it.copy(authMessage = error.message ?: "Sign-in failed") } }
        }
    }

    fun refreshDevices() {
        val current = state.value
        if (current.accountId.isBlank() || current.token.isBlank() || current.relayUrl.isBlank()) return
        scope.launch {
            runCatching { syncSession.listDevices(current.token, current.relayUrl) }
                .onSuccess { devices -> update { it.copy(devices = devices) } }
                .onFailure { error -> update { it.copy(status = error.message ?: "Unable to refresh devices") } }
        }
    }

    fun refreshLocalProjection() {
        val current = state.value
        val workspace = activeWorkspaceId(current.accountId)
        if (!syncSession.hasLocalAccountKey(workspace)) return
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    DayflowAndroidProjection.fromJson(syncSession.projectLocal(workspace))
                }
            }.onSuccess { projection ->
                update {
                    it.copy(
                        projection = projection,
                        pendingEventCount = syncSession.pendingEventCount(workspace),
                    )
                }
            }
        }
    }

    fun approveDevice(deviceId: String) = deviceAction { session ->
        syncSession.approveDevice(session.accountId, session.token, session.relayUrl, deviceId)
    }

    fun revokeDevice(deviceId: String) = deviceAction { session ->
        syncSession.revokeDevice(session.accountId, session.token, session.relayUrl, deviceId)
    }

    fun rotateEncryptionKey() {
        val current = state.value
        if (current.isRotatingKey) return
        scope.launch {
            update { it.copy(isRotatingKey = true, rotationMessage = null, status = "Rotating encrypted account key…") }
            runCatching {
                val session = accountSession(current)
                accountStore.save(session)
                val nextVersion = syncSession.rotateEncryptionKey(
                    accountId = session.accountId,
                    token = session.token,
                    relayUrl = session.relayUrl,
                )
                val devices = syncSession.listDevices(session.token, session.relayUrl)
                nextVersion to devices
            }.onSuccess { (version, devices) ->
                update {
                    it.copy(
                        isRotatingKey = false,
                        devices = devices,
                        status = "Encrypted key rotated to version $version.",
                        rotationMessage = "All approved devices received the new key. Previous versions remain available for replay.",
                    )
                }
            }.onFailure { error ->
                update {
                    it.copy(
                        isRotatingKey = false,
                        status = error.message ?: "Encryption key rotation failed",
                        rotationMessage = "No local key change was committed. Fix the issue and try again.",
                    )
                }
            }
        }
    }

    fun saveProvider() {
        val current = state.value
        val workspace = activeWorkspaceId(current.accountId).ifBlank { DayflowAndroidSyncSession.LOCAL_WORKSPACE_ID }
        runCatching {
            providerStore.save(
                workspace,
                DayflowAIProviderConfiguration(current.providerId, current.providerEndpoint, current.providerModelId),
                current.providerApiKey,
            )
        }.onSuccess {
            update { it.copy(providerMessage = "Provider settings saved on this device.") }
        }.onFailure { error ->
            update { it.copy(providerMessage = error.message ?: "Provider settings were not saved") }
        }
    }

    fun askChat() {
        val current = state.value
        update { it.copy(isChatting = true, chatAnswer = null, chatMessage = null) }
        scope.launch {
            runCatching {
                DayflowAndroidAIChatClient(
                    DayflowAIProviderConfiguration(
                        providerId = current.providerId,
                        endpoint = current.providerEndpoint,
                        modelId = current.providerModelId,
                    ),
                    current.providerApiKey,
                ).answer(current.chatQuestion, current.projection.chatContext)
            }.onSuccess { answer ->
                update {
                    it.copy(
                        isChatting = false,
                        chatAnswer = answer,
                        chatMessage = "Answered from local Dayflow context via ${current.providerId}.",
                    )
                }
            }.onFailure { error ->
                update { it.copy(isChatting = false, chatAnswer = null, chatMessage = error.message ?: "Dayflow could not answer") }
            }
        }
    }

    fun exportRecoveryKit(): String? {
        val current = state.value
        if (current.accountId.isBlank()) {
            update { it.copy(recoveryMessage = "Connect a Dayflow account before exporting a recovery kit.") }
            return null
        }
        return runCatching {
            syncSession.exportRecoveryKit(current.accountId, current.recoveryPassphrase)
        }.onSuccess { kit ->
            update {
                it.copy(
                    recoveryKitText = kit,
                    recoveryPassphrase = "",
                    recoveryMessage = "Recovery kit prepared. Keep it and its passphrase separate.",
                )
            }
        }.onFailure { error ->
            update { it.copy(recoveryMessage = error.message ?: "Recovery kit was not exported") }
        }.getOrNull()
    }

    fun restoreRecoveryKit() {
        val current = state.value
        if (current.accountId.isBlank()) {
            update { it.copy(recoveryMessage = "Enter the Dayflow account ID before restoring a recovery kit.") }
            return
        }
        runCatching {
            syncSession.restoreRecoveryKit(
                current.accountId,
                current.recoveryKitText,
                current.recoveryPassphrase,
            )
        }.onSuccess {
            update {
                it.copy(
                    recoveryPassphrase = "",
                    canCapture = syncSession.hasLocalAccountKey(current.accountId),
                    recoveryMessage = "Recovery key restored. Review approved devices before syncing.",
                )
            }
        }.onFailure { error ->
            update { it.copy(recoveryMessage = error.message ?: "Recovery kit was not restored") }
        }
    }

    fun addJournalEntry() {
        val current = state.value
        scope.launch {
            runCatching {
                val workspace = activeWorkspaceId(current.accountId)
                syncSession.enqueueJournal(workspace, current.journalDay, current.journalBody)
                DayflowAndroidProjection.fromJson(syncSession.projectLocal(workspace))
            }.onSuccess { projection ->
                update {
                    it.copy(
                        projection = projection,
                        journalBody = "",
                        pendingEventCount = syncSession.pendingEventCount(activeWorkspaceId(current.accountId)),
                        journalMessage = "Saved locally. It will sync as an encrypted event when you connect.",
                    )
                }
            }.onFailure { error ->
                update { it.copy(journalMessage = error.message ?: "Journal entry was not saved") }
            }
        }
    }

    fun addPriority() {
        val current = state.value
        scope.launch {
            runCatching {
                val workspace = activeWorkspaceId(current.accountId)
                val day = current.priorityDay.ifBlank { current.journalDay }
                val rank = current.projection.priorities.values
                    .filter { it.day == day }
                    .maxOfOrNull { it.rank }
                    ?.plus(1)
                    ?: 0
                syncSession.enqueuePriority(workspace, day, current.priorityText, rank)
                DayflowAndroidProjection.fromJson(syncSession.projectLocal(workspace))
            }.onSuccess { projection ->
                update {
                    it.copy(
                        projection = projection,
                        priorityText = "",
                        pendingEventCount = syncSession.pendingEventCount(activeWorkspaceId(current.accountId)),
                        priorityMessage = "Priority saved locally. It will sync as an encrypted event when you connect.",
                    )
                }
            }.onFailure { error ->
                update { it.copy(priorityMessage = error.message ?: "Priority was not saved") }
            }
        }
    }

    fun addReflection() {
        val current = state.value
        scope.launch {
            runCatching {
                val workspace = activeWorkspaceId(current.accountId)
                val day = current.reflectionDay.ifBlank { current.journalDay }
                syncSession.enqueueReflection(workspace, day, current.reflectionBody)
                DayflowAndroidProjection.fromJson(syncSession.projectLocal(workspace))
            }.onSuccess { projection ->
                update {
                    it.copy(
                        projection = projection,
                        reflectionBody = "",
                        pendingEventCount = syncSession.pendingEventCount(activeWorkspaceId(current.accountId)),
                        reflectionMessage = "Reflection saved locally. It will sync as an encrypted event when you connect.",
                    )
                }
            }.onFailure { error ->
                update { it.copy(reflectionMessage = error.message ?: "Reflection was not saved") }
            }
        }
    }

    fun deleteTimelineCard(id: String) = deleteRecord(
        targetId = id,
        successMessage = "Timeline card deleted locally. The deletion will sync as an encrypted event.",
        failureMessage = "Timeline card was not deleted",
    ) { state, message -> state.copy(journalMessage = message) }

    fun deleteJournalEntry(id: String) = deleteRecord(
        targetId = id,
        successMessage = "Journal entry deleted locally. The deletion will sync as an encrypted event.",
        failureMessage = "Journal entry was not deleted",
    ) { state, message -> state.copy(journalMessage = message) }

    fun deletePriority(id: String) = deleteRecord(
        targetId = id,
        successMessage = "Priority deleted locally. The deletion will sync as an encrypted event.",
        failureMessage = "Priority was not deleted",
    ) { state, message -> state.copy(priorityMessage = message) }

    fun deleteReflection(id: String) = deleteRecord(
        targetId = id,
        successMessage = "Reflection deleted locally. The deletion will sync as an encrypted event.",
        failureMessage = "Reflection was not deleted",
    ) { state, message -> state.copy(reflectionMessage = message) }

    fun saveSharedSetting() {
        val current = state.value
        scope.launch {
            runCatching {
                val workspace = activeWorkspaceId(current.accountId)
                syncSession.enqueueSetting(workspace, current.sharedSettingKey, current.sharedSettingValue)
                DayflowAndroidProjection.fromJson(syncSession.projectLocal(workspace))
            }.onSuccess { projection ->
                update {
                    it.copy(
                        projection = projection,
                        pendingEventCount = syncSession.pendingEventCount(activeWorkspaceId(current.accountId)),
                        sharedSettingMessage = "Shared setting saved locally. Provider secrets remain device-only.",
                    )
                }
            }.onFailure { error ->
                update { it.copy(sharedSettingMessage = error.message ?: "Shared setting was not saved") }
            }
        }
    }

    fun signOut() {
        sessionGeneration += 1
        syncJob?.cancel()
        syncJob = null
        accountStore.clear()
        mutableState.value = loadLocalState()
    }

    fun close() = scope.cancel()

    private fun deleteRecord(
        targetId: String,
        successMessage: String,
        failureMessage: String,
        setMessage: (DayflowAndroidAppState, String) -> DayflowAndroidAppState,
    ) {
        val current = state.value
        scope.launch {
            runCatching {
                val workspace = activeWorkspaceId(current.accountId)
                syncSession.enqueueTombstone(workspace, targetId)
                DayflowAndroidProjection.fromJson(syncSession.projectLocal(workspace))
            }.onSuccess { projection ->
                update {
                    setMessage(
                        it.copy(
                            projection = projection,
                            pendingEventCount = syncSession.pendingEventCount(activeWorkspaceId(current.accountId)),
                        ),
                        successMessage,
                    )
                }
            }.onFailure { error ->
                update { setMessage(it, "$failureMessage: ${error.message ?: "unknown error"}") }
            }
        }
    }

    private fun loadInitialState(): DayflowAndroidAppState {
        val session = accountStore.load() ?: return loadLocalState()
        val workspace = activeWorkspaceId(session.accountId)
        val providerWorkspace = workspace.ifBlank { DayflowAndroidSyncSession.LOCAL_WORKSPACE_ID }
        val provider = providerStore.load(providerWorkspace)
        return DayflowAndroidAppState(
            authUrl = session.authUrl,
            email = session.email,
            accountId = session.accountId,
            token = session.token,
            relayUrl = session.relayUrl,
            displayName = session.displayName,
            status = "Ready to sync",
            canCapture = syncSession.hasLocalAccountKey(workspace),
            pendingEventCount = syncSession.pendingEventCount(workspace),
            syncHealth = syncSession.syncHealth(session.accountId),
            journalDay = defaultLogicalDay(),
            projection = runCatching {
                DayflowAndroidProjection.fromJson(syncSession.projectLocal(workspace))
            }.getOrDefault(DayflowAndroidProjection()),
            currentDeviceId = syncSession.currentDeviceId(),
            providerId = provider?.providerId ?: DayflowAIProviderIds.LOCAL,
            providerEndpoint = provider?.endpoint ?: "http://127.0.0.1:11434",
            providerModelId = provider?.modelId ?: "llama3.2",
            providerApiKey = providerStore.loadApiKey(providerWorkspace) ?: "",
        )
    }

    private fun loadLocalState(): DayflowAndroidAppState {
        val localWorkspace = DayflowAndroidSyncSession.LOCAL_WORKSPACE_ID
        val provider = providerStore.load(localWorkspace)
        val projection = runCatching {
            syncSession.ensureLocalWorkspace()
            DayflowAndroidProjection.fromJson(syncSession.projectLocal(""))
        }.getOrDefault(DayflowAndroidProjection())
        return DayflowAndroidAppState(
            status = "Local workspace · offline",
            canCapture = syncSession.hasLocalAccountKey(""),
            pendingEventCount = syncSession.pendingEventCount(""),
            syncHealth = syncSession.syncHealth(""),
            projection = projection,
            journalDay = defaultLogicalDay(),
            currentDeviceId = syncSession.currentDeviceId(),
            providerId = provider?.providerId ?: DayflowAIProviderIds.LOCAL,
            providerEndpoint = provider?.endpoint ?: "http://127.0.0.1:11434",
            providerModelId = provider?.modelId ?: "llama3.2",
            providerApiKey = providerStore.loadApiKey(localWorkspace) ?: "",
        )
    }

    private fun accountSession(state: DayflowAndroidAppState): DayflowAndroidAccountSession {
        require(state.accountId.isNotBlank() && state.token.isNotBlank()) { "Sign in to Dayflow before syncing." }
        val relay = state.relayUrl.trim()
        require(DayflowAndroidEndpointPolicy.isAllowed(relay)) {
            "Sync relay must use HTTPS, or loopback HTTP for local development."
        }
        require(state.displayName.isNotBlank()) { "A device name is required." }
        return DayflowAndroidAccountSession(
            accountId = state.accountId.trim(),
            token = state.token.trim(),
            authUrl = state.authUrl.trim(),
            email = state.email.trim(),
            relayUrl = relay,
            displayName = state.displayName.trim(),
        )
    }

    private fun deviceAction(action: suspend (DayflowAndroidAccountSession) -> DayflowAndroidRelayDevice) {
        val current = state.value
        scope.launch {
            runCatching { action(accountSession(current)) }
                .onSuccess { refreshDevices() }
                .onFailure { error -> update { it.copy(status = error.message ?: "Device action failed") } }
        }
    }

    private fun loadProvider(accountId: String) {
        val provider = providerStore.load(accountId) ?: return
        update {
            it.copy(
                providerId = provider.providerId,
                providerEndpoint = provider.endpoint,
                providerModelId = provider.modelId,
                providerApiKey = providerStore.loadApiKey(accountId) ?: "",
            )
        }
    }

    private fun activeWorkspaceId(accountId: String): String =
        accountId.trim().takeIf {
            it.isNotBlank()
                && keyStore.hasAccountKeyAdmission(it)
                && syncSession.hasLocalAccountKey(it)
        } ?: ""

    private fun defaultLogicalDay(): String {
        val today = LocalDate.now()
        return if (LocalTime.now().isBefore(LocalTime.of(4, 0))) today.minusDays(1).toString() else today.toString()
    }

    private fun update(transform: (DayflowAndroidAppState) -> DayflowAndroidAppState) {
        mutableState.value = transform(mutableState.value)
    }

    private fun DayflowAndroidSyncOutcome.statusLabel(): String = when (status) {
        "waiting_for_approval" -> "Waiting for device approval"
        else -> "Synced $pushed sent, $pulled received, $notificationHints wake hints consumed"
    }
}
