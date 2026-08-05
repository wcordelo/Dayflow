package app.dayflow.android

import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.PasswordVisualTransformation
import app.dayflow.android.capture.CaptureStatus
import app.dayflow.android.capture.DayflowCaptureStatusFields

private enum class DayflowAndroidRoute(val label: String) {
    TODAY("Today"),
    TIMELINE("Timeline"),
    WEEK("Week"),
    JOURNAL("Journal"),
    CHAT("Chat"),
    SETTINGS("Settings"),
    ACCOUNT("Account"),
    RECOVERY("Recovery"),
}

@Composable
fun DayflowAndroidProductSurface(
    appModel: DayflowAndroidAppModel,
    appState: DayflowAndroidAppState,
    captureStatus: CaptureStatus,
    statusFields: DayflowCaptureStatusFields,
    capabilities: ChromeOsCapabilities,
    onStartCapture: () -> Unit,
    onStopCapture: () -> Unit,
) {
    var selectedRoute by remember { mutableStateOf(DayflowAndroidRoute.TODAY) }
    val today = appState.journalDay.ifBlank { "Today" }
    val contentPadding = capabilities.contentPaddingDp.dp
    val contentSpacing = capabilities.contentSpacingDp.dp

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding)
                .widthIn(max = capabilities.contentMaxWidthDp.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(contentSpacing),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Dayflow", style = MaterialTheme.typography.headlineLarge)
                Text(
                    if (capabilities.isChromeOs) "Your day, adapted for Chromebook" else "Your day, on this device",
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    "Timeline and journal stay useful offline. Only encrypted derived events sync.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }

            CaptureSummary(
                status = captureStatus,
                statusFields = statusFields,
                canCapture = appState.canCapture,
                onStartCapture = onStartCapture,
                onStopCapture = onStopCapture,
            )

            ScrollableTabRow(
                selectedTabIndex = DayflowAndroidRoute.entries.indexOf(selectedRoute),
                edgePadding = 0.dp,
            ) {
                DayflowAndroidRoute.entries.forEach { route ->
                    Tab(
                        selected = route == selectedRoute,
                        onClick = { selectedRoute = route },
                        text = { Text(route.label) },
                    )
                }
            }

            when (selectedRoute) {
                DayflowAndroidRoute.TODAY -> TimelinePage(
                    title = "Today",
                    subtitle = "Your local activity and priorities for $today.",
                    cards = appState.projection.timelineCardsForDay(today),
                    priorities = appState.projection.priorities.values.filter { it.day == today },
                    onDelete = appModel::deleteTimelineCard,
                )
                DayflowAndroidRoute.TIMELINE -> TimelinePage(
                    title = "Timeline",
                    subtitle = "Recent cards from the local projection.",
                    cards = appState.projection.latestTimelineCards(),
                    priorities = emptyList(),
                    onDelete = appModel::deleteTimelineCard,
                )
                DayflowAndroidRoute.WEEK -> TimelinePage(
                    title = "Last seven days",
                    subtitle = "A compact weekly view ending on $today.",
                    cards = appState.projection.timelineCardsForWeek(today),
                    priorities = emptyList(),
                    onDelete = appModel::deleteTimelineCard,
                )
                DayflowAndroidRoute.JOURNAL -> JournalPage(appModel, appState)
                DayflowAndroidRoute.CHAT -> ChatPage(appModel, appState)
                DayflowAndroidRoute.SETTINGS -> SettingsPage(appModel, appState)
                DayflowAndroidRoute.ACCOUNT -> AccountPage(appModel, appState)
                DayflowAndroidRoute.RECOVERY -> RecoveryPage(appModel, appState)
            }
        }
    }
}

@Composable
private fun CaptureSummary(
    status: CaptureStatus,
    statusFields: DayflowCaptureStatusFields,
    canCapture: Boolean,
    onStartCapture: () -> Unit,
    onStopCapture: () -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Capture", style = MaterialTheme.typography.titleLarge)
            Text(status.state.name.replace('_', ' '), style = MaterialTheme.typography.titleMedium)
            Text(status.detail)
            Text("Permission: ${statusFields.capturePermission}", style = MaterialTheme.typography.bodySmall)
            Text("Session: ${statusFields.captureSession}", style = MaterialTheme.typography.bodySmall)
            Text("Privacy: ${statusFields.capturePaused}", style = MaterialTheme.typography.bodySmall)
            Text("Derived sync: ${statusFields.derivedSync}", style = MaterialTheme.typography.bodySmall)
            Text("${status.framesObserved} frames sampled locally", style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = onStartCapture, enabled = canCapture) { Text("Start capture") }
                Button(onClick = onStopCapture) { Text("Stop") }
            }
        }
    }
}

@Composable
private fun TimelinePage(
    title: String,
    subtitle: String,
    cards: List<DayflowAndroidTimelineCard>,
    priorities: List<DayflowAndroidPriority>,
    onDelete: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, style = MaterialTheme.typography.headlineSmall)
        Text(subtitle, style = MaterialTheme.typography.bodyMedium)
        if (cards.isEmpty()) {
            EmptyState("No derived activity cards yet. Start capture or add a journal entry.")
        } else {
            cards.forEach { card ->
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(
                        modifier = Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(card.title, style = MaterialTheme.typography.titleMedium)
                        Text("${card.day} · ${card.category}", style = MaterialTheme.typography.labelMedium)
                        Text(card.summary)
                        Text(
                            "${card.source} · ${card.derivationMode}",
                            style = MaterialTheme.typography.bodySmall,
                        )
                        TextButton(onClick = { onDelete(card.id) }) { Text("Delete") }
                    }
                }
            }
        }
        if (priorities.isNotEmpty()) {
            Text("Priorities", style = MaterialTheme.typography.titleMedium)
            priorities.sortedBy { it.rank }.forEach { priority ->
                Text("${priority.rank + 1}. ${priority.text}", style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
private fun JournalPage(
    appModel: DayflowAndroidAppModel,
    appState: DayflowAndroidAppState,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Journal", style = MaterialTheme.typography.headlineSmall)
        Text("Write locally first. Entries remain available offline.", style = MaterialTheme.typography.bodyMedium)
        OutlinedTextField(
            value = appState.journalDay,
            onValueChange = appModel::setJournalDay,
            label = { Text("Logical day (YYYY-MM-DD)") },
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = appState.journalBody,
            onValueChange = appModel::setJournalBody,
            label = { Text("What happened?") },
            modifier = Modifier.fillMaxWidth(),
            minLines = 4,
        )
        Button(onClick = appModel::addJournalEntry) { Text("Save journal entry") }
        appState.journalMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        HorizontalDivider()
        Text("Recent journal", style = MaterialTheme.typography.titleMedium)
        appState.projection.journalEntries.values
            .sortedWith(compareByDescending<DayflowAndroidJournalEntry> { it.day }.thenByDescending { it.id })
            .take(10)
            .forEach { entry ->
                RecordRow(
                    title = entry.day,
                    detail = entry.body,
                    onDelete = { appModel.deleteJournalEntry(entry.id) },
                )
            }
        Text("Reflections", style = MaterialTheme.typography.titleMedium)
        appState.projection.reflections.values
            .sortedWith(compareByDescending<DayflowAndroidReflection> { it.day }.thenByDescending { it.id })
            .take(10)
            .forEach { reflection ->
                RecordRow(
                    title = reflection.day,
                    detail = reflection.body,
                    onDelete = { appModel.deleteReflection(reflection.id) },
                )
            }
    }
}

@Composable
private fun ChatPage(
    appModel: DayflowAndroidAppModel,
    appState: DayflowAndroidAppState,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Chat", style = MaterialTheme.typography.headlineSmall)
        Text("Ask about the bounded projection stored on this device.", style = MaterialTheme.typography.bodyMedium)
        OutlinedTextField(
            value = appState.chatQuestion,
            onValueChange = appModel::setChatQuestion,
            label = { Text("Ask Dayflow") },
            modifier = Modifier.fillMaxWidth(),
            minLines = 4,
        )
        Button(onClick = appModel::askChat, enabled = !appState.isChatting) {
            Text(if (appState.isChatting) "Thinking…" else "Ask")
        }
        appState.chatMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        appState.chatAnswer?.let {
            Card(modifier = Modifier.fillMaxWidth()) {
                Text(it, modifier = Modifier.padding(16.dp))
            }
        }
    }
}

@Composable
private fun SettingsPage(
    appModel: DayflowAndroidAppModel,
    appState: DayflowAndroidAppState,
) {
    val paused = appState.sharedSettingValue.trim().equals("true", ignoreCase = true)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Settings", style = MaterialTheme.typography.headlineSmall)
        Text("Privacy controls apply locally before a frame can become a card.", style = MaterialTheme.typography.bodyMedium)
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("Pause capture everywhere", style = MaterialTheme.typography.titleMedium)
                Text("Clearing this switch never silently resumes capture.", style = MaterialTheme.typography.bodySmall)
            }
            Switch(
                checked = paused,
                onCheckedChange = {
                    appModel.setSharedSettingValue(if (it) "true" else "false")
                    appModel.saveSharedSetting()
                },
            )
        }
        Text("On-device AI provider", style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(appState.providerId, appModel::setProviderId, label = { Text("Provider") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(appState.providerEndpoint, appModel::setProviderEndpoint, label = { Text("Endpoint") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(appState.providerModelId, appModel::setProviderModelId, label = { Text("Model") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(
            appState.providerApiKey,
            appModel::setProviderApiKey,
            label = { Text("API key") },
            visualTransformation = PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth(),
        )
        Button(onClick = appModel::saveProvider) { Text("Save provider") }
        appState.providerMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun AccountPage(
    appModel: DayflowAndroidAppModel,
    appState: DayflowAndroidAppState,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Account and devices", style = MaterialTheme.typography.headlineSmall)
        Text(appState.status, color = MaterialTheme.colorScheme.secondary)
        Text(appState.syncHealthSummary(), style = MaterialTheme.typography.bodySmall)
        OutlinedTextField(appState.authUrl, appModel::setAuthUrl, label = { Text("Account service URL") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(appState.email, appModel::setEmail, label = { Text("Email") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(appState.verificationCode, appModel::setVerificationCode, label = { Text("Email code") }, modifier = Modifier.fillMaxWidth())
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = appModel::requestSignInCode) { Text("Send code") }
            Button(onClick = appModel::verifySignInCode) { Text("Connect") }
        }
        appState.authMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        OutlinedTextField(appState.accountId, appModel::setAccountId, label = { Text("Account ID") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(appState.relayUrl, appModel::setRelayUrl, label = { Text("Sync relay URL") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(appState.displayName, appModel::setDisplayName, label = { Text("Device name") }, modifier = Modifier.fillMaxWidth())
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = appModel::sync) { Text("Sync") }
            Button(onClick = appModel::refreshDevices) { Text("Refresh devices") }
            TextButton(onClick = appModel::signOut) { Text("Sign out") }
        }
        appState.devices.forEach { device ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column {
                    Text(device.deviceId)
                    Text("Android/ChromeOS · ${device.status}", style = MaterialTheme.typography.bodySmall)
                }
                if (device.status == "pending") {
                    TextButton(onClick = { appModel.approveDevice(device.deviceId) }) { Text("Approve") }
                } else if (device.deviceId != appState.currentDeviceId) {
                    TextButton(onClick = { appModel.revokeDevice(device.deviceId) }) { Text("Revoke") }
                }
            }
        }
    }
}

@Composable
private fun RecoveryPage(
    appModel: DayflowAndroidAppModel,
    appState: DayflowAndroidAppState,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Recovery", style = MaterialTheme.typography.headlineSmall)
        Text("Keep the recovery kit and passphrase separate. Neither is synced.", style = MaterialTheme.typography.bodyMedium)
        OutlinedTextField(
            appState.recoveryPassphrase,
            appModel::setRecoveryPassphrase,
            label = { Text("Passphrase") },
            visualTransformation = PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            appState.recoveryKitText,
            appModel::setRecoveryKitText,
            label = { Text("Recovery kit JSON") },
            minLines = 6,
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { appModel.exportRecoveryKit() }) { Text("Prepare kit") }
            Button(onClick = appModel::restoreRecoveryKit) { Text("Restore kit") }
        }
        appState.recoveryMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun EmptyState(message: String) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Text(message, modifier = Modifier.padding(16.dp))
    }
}

@Composable
private fun RecordRow(title: String, detail: String, onDelete: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.labelLarge)
            Text(detail, maxLines = 3, style = MaterialTheme.typography.bodySmall)
        }
        TextButton(onClick = onDelete) { Text("Delete") }
    }
}
