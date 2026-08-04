package app.dayflow.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Build
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import app.dayflow.android.capture.CapturePrivacyContext
import app.dayflow.android.capture.MediaProjectionCaptureController

class MainActivity : ComponentActivity() {
    private lateinit var captureController: MediaProjectionCaptureController
    private lateinit var chromeOsCapabilities: ChromeOsCapabilities
    private lateinit var appModel: DayflowAndroidAppModel
    private var pendingCaptureAccountId: String? = null

    private val capturePermission = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        captureController.acceptConsent(result.resultCode, result.data)
    }

    private val notificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val accountId = pendingCaptureAccountId
        pendingCaptureAccountId = null
        if (granted && notificationsAreVisible()) {
            captureController.requestCapture(capturePermission, accountId)
        } else {
            captureController.markNotificationPermissionRequired()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureController = MediaProjectionCaptureController(this)
        chromeOsCapabilities = ChromeOsCapabilities.detect(this)
        appModel = DayflowAndroidAppModel(applicationContext)
        setContent {
            val captureStatus by captureController.status.collectAsStateWithLifecycle()
            val appState by appModel.state.collectAsStateWithLifecycle()
            LaunchedEffect(appState.projection.settings[CapturePrivacyContext.SHARED_CAPTURE_PAUSE_SETTING]) {
                // Shared settings are decrypted and projected locally before
                // they reach capture. Applying them here also handles a
                // setting changed on another device after the next sync.
                captureController.updatePrivacyContext(
                    CapturePrivacyContext.fromSharedSettings(appState.projection.settings),
                )
            }
            LaunchedEffect(Unit) {
                while (isActive) {
                    delay(5_000)
                    captureController.refreshFromService()
                    appModel.refreshLocalProjection()
                }
            }
            val coreStatus = remember {
                runCatching { UniFFIDayflowCoreBridge.version() }
                    .fold(
                        onSuccess = { "Rust core $it" },
                        onFailure = { "Rust core not packaged in this build" },
                    )
            }
            val sharedCapturePaused = CapturePrivacyContext.fromSharedSettings(
                appState.projection.settings,
            ).userPaused
            val contentPadding = chromeOsCapabilities.contentPaddingDp.dp
            val contentSpacing = chromeOsCapabilities.contentSpacingDp.dp
            val statusFields = captureStatus.statusFields(
                sharedCapturePaused = sharedCapturePaused,
                derivedSync = appState.syncHealthSummary(),
            )
            Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                Box(modifier = Modifier.fillMaxSize().padding(contentPadding)) {
                    Column(
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .fillMaxWidth()
                            .widthIn(max = chromeOsCapabilities.contentMaxWidthDp.dp)
                            .verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(contentSpacing),
                    ) {
                    Text("Dayflow", style = MaterialTheme.typography.headlineLarge)
                    Text(
                        if (chromeOsCapabilities.isChromeOs) "Android client for ChromeOS" else "Native Android client",
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text("Your timeline and journal stay useful offline. Sync carries encrypted derived events only.")
                    Text(coreStatus, style = MaterialTheme.typography.labelMedium)
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Capture", style = MaterialTheme.typography.titleLarge)
                            Text(captureStatus.state.name.replace('_', ' '))
                            Text(captureStatus.detail)
                            Text("Capture permission: ${statusFields.capturePermission}")
                            Text("Capture session: ${statusFields.captureSession}")
                            Text("Capture paused: ${statusFields.capturePaused}")
                            Text("Derived sync: ${statusFields.derivedSync}")
                            Text("Frames observed locally: ${captureStatus.framesObserved}")
                            Text(
                                if (sharedCapturePaused
                                ) {
                                    "Shared privacy setting: capture paused"
                                } else {
                                    "Shared privacy setting: capture allowed"
                                },
                                style = MaterialTheme.typography.bodySmall,
                            )
                            if (!appState.canCapture) {
                                Text(
                                    "The local workspace is unavailable until secure storage is ready.",
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            onClick = { startCapture(appModel.captureAccountId()) },
                            enabled = appState.canCapture,
                        ) {
                            Text("Start capture")
                        }
                        Button(onClick = captureController::stop) {
                            Text("Stop")
                        }
                    }

                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Local timeline, journal & chat context", style = MaterialTheme.typography.titleLarge)
                            Text(
                                "${appState.projection.timelineCardCount} timeline cards · " +
                                    "${appState.projection.journalEntryCount} journal entries · " +
                                    "${appState.projection.priorityCount} priorities · " +
                                    "${appState.projection.reflectionCount} reflections · " +
                                    "${appState.projection.settings.size} shared settings",
                            )
                            Text(
                                if (appState.accountId.isBlank()) {
                                    "Records stay on this device while offline and become syncable after you connect a Dayflow account."
                                } else if (appState.pendingEventCount > 0) {
                                    "Local record state: ${appState.pendingEventCount} encrypted event(s) pending sync."
                                } else {
                                    "Local record state: projection is up to date with the last sync."
                                },
                                style = MaterialTheme.typography.bodySmall,
                            )
                            appState.projection.chatContext.take(5).forEach { item ->
                                Column {
                                    Text("${item.kind} · ${item.day}", style = MaterialTheme.typography.labelSmall)
                                    Text(item.content, maxLines = 2, style = MaterialTheme.typography.bodySmall)
                                }
                            }
                            Text("Saved records", style = MaterialTheme.typography.titleMedium)
                            appState.projection.timelineCards.values
                                .sortedWith(compareByDescending<DayflowAndroidTimelineCard> { it.day }.thenByDescending { it.id })
                                .take(10)
                                .forEach { card ->
                                    RecordRow(
                                        title = card.title,
                                        detail = "${card.day} · ${card.summary}",
                                        onDelete = { appModel.deleteTimelineCard(card.id) },
                                    )
                                }
                            appState.projection.journalEntries.values
                                .sortedWith(compareByDescending<DayflowAndroidJournalEntry> { it.day }.thenByDescending { it.id })
                                .take(10)
                                .forEach { entry ->
                                    RecordRow(
                                        title = "Journal · ${entry.day}",
                                        detail = entry.body,
                                        onDelete = { appModel.deleteJournalEntry(entry.id) },
                                    )
                                }
                            appState.projection.priorities.values
                                .sortedWith(compareBy<DayflowAndroidPriority> { it.day }.thenBy { it.rank })
                                .take(10)
                                .forEach { priority ->
                                    RecordRow(
                                        title = "Priority · ${priority.day}",
                                        detail = priority.text,
                                        onDelete = { appModel.deletePriority(priority.id) },
                                    )
                                }
                            appState.projection.reflections.values
                                .sortedWith(compareByDescending<DayflowAndroidReflection> { it.day }.thenByDescending { it.id })
                                .take(10)
                                .forEach { reflection ->
                                    RecordRow(
                                        title = "Reflection · ${reflection.day}",
                                        detail = reflection.body,
                                        onDelete = { appModel.deleteReflection(reflection.id) },
                                    )
                                }
                            OutlinedTextField(
                                value = appState.journalDay,
                                onValueChange = appModel::setJournalDay,
                                label = { Text("Logical day (YYYY-MM-DD)") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            OutlinedTextField(
                                value = appState.journalBody,
                                onValueChange = appModel::setJournalBody,
                                label = { Text("Journal entry") },
                                modifier = Modifier.fillMaxWidth(),
                                minLines = 3,
                            )
                            Button(onClick = appModel::addJournalEntry) { Text("Save journal entry locally") }
                            appState.journalMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            HorizontalDivider()
                            Text("Priorities & reflections", style = MaterialTheme.typography.titleMedium)
                            OutlinedTextField(
                                value = appState.priorityDay,
                                onValueChange = appModel::setPriorityDay,
                                label = { Text("Priority logical day (YYYY-MM-DD)") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            OutlinedTextField(
                                value = appState.priorityText,
                                onValueChange = appModel::setPriorityText,
                                label = { Text("What matters next?") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            Button(onClick = appModel::addPriority) { Text("Save priority locally") }
                            appState.priorityMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            OutlinedTextField(
                                value = appState.reflectionDay,
                                onValueChange = appModel::setReflectionDay,
                                label = { Text("Reflection logical day (YYYY-MM-DD)") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            OutlinedTextField(
                                value = appState.reflectionBody,
                                onValueChange = appModel::setReflectionBody,
                                label = { Text("What did you learn?") },
                                modifier = Modifier.fillMaxWidth(),
                                minLines = 3,
                            )
                            Button(onClick = appModel::addReflection) { Text("Save reflection locally") }
                            appState.reflectionMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            HorizontalDivider()
                            Text("Shared Dayflow setting", style = MaterialTheme.typography.titleMedium)
                            OutlinedTextField(
                                value = appState.sharedSettingKey,
                                onValueChange = {},
                                readOnly = true,
                                label = { Text("Safe shared setting key") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            OutlinedTextField(
                                value = appState.sharedSettingValue,
                                onValueChange = appModel::setSharedSettingValue,
                                label = { Text("Value (true or false)") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            Button(onClick = appModel::saveSharedSetting) { Text("Save shared setting locally") }
                            appState.sharedSettingMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                        }
                    }

                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Account & encrypted sync", style = MaterialTheme.typography.titleLarge)
                            Text(appState.status, color = MaterialTheme.colorScheme.secondary)
                            Text(
                                appState.syncHealthSummary(),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.secondary,
                            )
                            OutlinedTextField(
                                value = appState.authUrl,
                                onValueChange = appModel::setAuthUrl,
                                label = { Text("Dayflow account service URL") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            OutlinedTextField(
                                value = appState.email,
                                onValueChange = appModel::setEmail,
                                label = { Text("Email") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            OutlinedTextField(
                                value = appState.verificationCode,
                                onValueChange = appModel::setVerificationCode,
                                label = { Text("Email code") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Button(onClick = appModel::requestSignInCode) { Text("Send code") }
                                Button(onClick = appModel::verifySignInCode) { Text("Verify & connect") }
                            }
                            appState.authMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            OutlinedTextField(
                                value = appState.accountId,
                                onValueChange = appModel::setAccountId,
                                label = { Text("Dayflow account ID") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            OutlinedTextField(
                                value = appState.relayUrl,
                                onValueChange = appModel::setRelayUrl,
                                label = { Text("Sync relay URL") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            OutlinedTextField(
                                value = appState.displayName,
                                onValueChange = appModel::setDisplayName,
                                label = { Text("Device name") },
                                modifier = Modifier.fillMaxWidth(),
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Button(onClick = appModel::sync) { Text("Sync") }
                                Button(onClick = appModel::refreshDevices) { Text("Refresh devices") }
                                Button(
                                    onClick = appModel::rotateEncryptionKey,
                                    enabled = appState.accountId.isNotBlank()
                                        && appState.token.isNotBlank()
                                        && !appState.isRotatingKey,
                                ) {
                                    Text(if (appState.isRotatingKey) "Rotating…" else "Rotate key")
                                }
                                Button(onClick = {
                                    // Capture owns an account-scoped event
                                    // writer. Stop it before clearing the
                                    // account session so samples cannot be
                                    // attributed after sign-out.
                                    captureController.stop()
                                    appModel.signOut()
                                }) { Text("Sign out") }
                            }
                            appState.rotationMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            appState.devices.forEach { device ->
                                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                    Column {
                                        Text(device.deviceId)
                                        Text("${device.status}", style = MaterialTheme.typography.labelSmall)
                                    }
                                    if (device.status == "pending") {
                                        Button(onClick = { appModel.approveDevice(device.deviceId) }) { Text("Approve") }
                                    } else if (device.deviceId != appState.currentDeviceId) {
                                        Button(onClick = { appModel.revokeDevice(device.deviceId) }) { Text("Revoke") }
                                    }
                                }
                            }
                            OutlinedTextField(
                                value = appState.recoveryPassphrase,
                                onValueChange = appModel::setRecoveryPassphrase,
                                label = { Text("Recovery passphrase") },
                                visualTransformation = PasswordVisualTransformation(),
                                modifier = Modifier.fillMaxWidth(),
                            )
                            OutlinedTextField(
                                value = appState.recoveryKitText,
                                onValueChange = appModel::setRecoveryKitText,
                                label = { Text("Recovery kit JSON") },
                                modifier = Modifier.fillMaxWidth(),
                                minLines = 4,
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Button(onClick = {
                                    appModel.exportRecoveryKit()?.let { kit ->
                                        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                                            type = "application/json"
                                            putExtra(Intent.EXTRA_TEXT, kit)
                                            putExtra(Intent.EXTRA_SUBJECT, "Dayflow recovery kit")
                                        }, "Share Dayflow recovery kit"))
                                    }
                                }) { Text("Export/share kit") }
                                Button(onClick = appModel::restoreRecoveryKit) { Text("Restore kit") }
                            }
                            appState.recoveryMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            Text(
                                "The passphrase is never stored or synced. Keep it separate from the recovery kit.",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }

                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("On-device AI", style = MaterialTheme.typography.titleLarge)
                            OutlinedTextField(appState.providerId, appModel::setProviderId, label = { Text("Provider") }, modifier = Modifier.fillMaxWidth())
                            OutlinedTextField(appState.providerEndpoint, appModel::setProviderEndpoint, label = { Text("Endpoint") }, modifier = Modifier.fillMaxWidth())
                            OutlinedTextField(appState.providerModelId, appModel::setProviderModelId, label = { Text("Model") }, modifier = Modifier.fillMaxWidth())
                            OutlinedTextField(
                                appState.providerApiKey,
                                appModel::setProviderApiKey,
                                label = { Text("API key (if required)") },
                                visualTransformation = PasswordVisualTransformation(),
                                modifier = Modifier.fillMaxWidth(),
                            )
                            Button(onClick = appModel::saveProvider) { Text("Save provider settings") }
                            appState.providerMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            Text("Provider routes and secrets stay in Android Keystore and are not synced.", style = MaterialTheme.typography.bodySmall)
                        }
                    }

                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Chat with your local Dayflow context", style = MaterialTheme.typography.titleLarge)
                            OutlinedTextField(
                                value = appState.chatQuestion,
                                onValueChange = appModel::setChatQuestion,
                                label = { Text("Ask a question") },
                                modifier = Modifier.fillMaxWidth(),
                                minLines = 3,
                            )
                            Button(
                                onClick = appModel::askChat,
                                enabled = !appState.isChatting,
                            ) { Text(if (appState.isChatting) "Thinking…" else "Ask Dayflow") }
                            appState.chatMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            appState.chatAnswer?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
                            Text(
                                "Only bounded local projection context is sent to your selected provider. Dayflow's sync relay is not an inference service.",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (::appModel.isInitialized) {
            appModel.syncIfConfigured()
        }
        if (::captureController.isInitialized) {
            captureController.refreshFromService()
            appModel.refreshLocalProjection()
        }
    }

    override fun onDestroy() {
        if (::appModel.isInitialized) appModel.close()
        super.onDestroy()
    }

    private fun startCapture(accountId: String?) {
        if (notificationsAreVisible()) {
            captureController.requestCapture(capturePermission, accountId)
            return
        }

        pendingCaptureAccountId = accountId
        captureController.markNotificationPermissionRequired()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
            && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }

        // On pre-33 devices (or after a user disables notifications in system
        // settings), there is no runtime permission prompt to show. Keep the
        // capture session stopped until the user restores the visible status
        // channel, then taps Start capture again.
        startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        })
    }

    private fun notificationsAreVisible(): Boolean =
        NotificationManagerCompat.from(this).areNotificationsEnabled()

    @androidx.compose.runtime.Composable
    private fun RecordRow(title: String, detail: String, onDelete: () -> Unit) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.labelMedium)
                Text(detail, maxLines = 2, style = MaterialTheme.typography.bodySmall)
            }
            Button(onClick = onDelete) { Text("Delete") }
        }
    }
}
