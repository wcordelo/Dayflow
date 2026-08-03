import SwiftUI
import UniformTypeIdentifiers

public struct DayflowRootView: View {
    @ObservedObject private var captureSession: ActivityCaptureSession
    @ObservedObject private var appModel: DayflowMobileAppModel
    @State private var recoveryPassphrase = ""
    @State private var isImportingRecoveryKit = false

    public init(captureSession: ActivityCaptureSession, appModel: DayflowMobileAppModel) {
        self.captureSession = captureSession
        self.appModel = appModel
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Today") {
                    Label("Timeline and journal stay available offline", systemImage: "clock")
                    Label("AI context is built on this device", systemImage: "lock.shield")
                    Text("\(appModel.projection.timelineCards.count) timeline cards · \(appModel.projection.journalEntries.count) journal entries · \(appModel.projection.priorities.count) priorities · \(appModel.projection.reflections.count) reflections · \(appModel.projection.settings.count) shared settings")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(localRecordState)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(Array(appModel.projection.chatContext.prefix(5))) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.kind) · \(item.day)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.content)
                                .font(.footnote)
                                .lineLimit(2)
                        }
                    }
                }

                Section("Saved records") {
                    ForEach(appModel.projection.timelineCards.values.sorted { $0.id < $1.id }) { card in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.title)
                            Text("\(card.day) · \(card.summary)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Delete timeline card", role: .destructive) {
                                appModel.deleteTimelineCard(id: card.id)
                            }
                        }
                    }
                    ForEach(appModel.projection.journalEntries.values.sorted { $0.id < $1.id }) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Journal · \(entry.day)")
                            Text(entry.body)
                                .font(.footnote)
                                .lineLimit(3)
                            Button("Delete journal entry", role: .destructive) {
                                appModel.deleteJournalEntry(id: entry.id)
                            }
                        }
                    }
                    ForEach(appModel.projection.priorities.values.sorted {
                        $0.day == $1.day ? $0.rank < $1.rank : $0.day < $1.day
                    }) { priority in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Priority · \(priority.day)")
                            Text(priority.text)
                                .font(.footnote)
                            Button("Delete priority", role: .destructive) {
                                appModel.deletePriority(id: priority.id)
                            }
                        }
                    }
                    ForEach(appModel.projection.reflections.values.sorted { $0.id < $1.id }) { reflection in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reflection · \(reflection.day)")
                            Text(reflection.body)
                                .font(.footnote)
                                .lineLimit(3)
                            Button("Delete reflection", role: .destructive) {
                                appModel.deleteReflection(id: reflection.id)
                            }
                        }
                    }
                    if appModel.projection.timelineCards.isEmpty
                        && appModel.projection.journalEntries.isEmpty
                        && appModel.projection.priorities.isEmpty
                        && appModel.projection.reflections.isEmpty
                    {
                        Text("Records you save or capture will appear here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Journal") {
                    TextField("Logical day (YYYY-MM-DD)", text: $appModel.journalDay)
                    TextEditor(text: $appModel.journalBody)
                        .frame(minHeight: 90)
                    Button("Save journal entry locally") {
                        appModel.addJournalEntry()
                    }
                    if let journalMessage = appModel.journalMessage {
                        Text(journalMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Priorities & reflections") {
                    TextField("Priority logical day (YYYY-MM-DD)", text: $appModel.priorityDay)
                    TextField("What matters next?", text: $appModel.priorityText)
                    Button("Save priority locally") {
                        appModel.addPriority()
                    }
                    if let priorityMessage = appModel.priorityMessage {
                        Text(priorityMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Reflection logical day (YYYY-MM-DD)", text: $appModel.reflectionDay)
                    TextEditor(text: $appModel.reflectionBody)
                        .frame(minHeight: 90)
                    Button("Save reflection locally") {
                        appModel.addReflection()
                    }
                    if let reflectionMessage = appModel.reflectionMessage {
                        Text(reflectionMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Shared Dayflow setting") {
                    Text("Safe shared setting: dayflow.capture.paused")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Value (true or false)", text: $appModel.sharedSettingValue)
                    Button("Save shared setting locally") {
                        appModel.saveSharedSetting()
                    }
                    if let sharedSettingMessage = appModel.sharedSettingMessage {
                        Text(sharedSettingMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Provider routes and secrets remain device-only and are never written to this shared setting stream.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Activity capture") {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                    Text("Capture permission: \(captureStatusFields.capturePermission)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Capture session: \(captureStatusFields.captureSession)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Capture paused: \(captureStatusFields.capturePaused)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Derived sync: \(captureStatusFields.derivedSync)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !appModel.canCapture {
                        Text("The local workspace is unavailable until secure storage is ready.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Start capture") {
                        captureSession.start()
                    }
                    .disabled(!appModel.canCapture)
                    Button("Stop capture", role: .destructive) {
                        captureSession.stop()
                    }
                    Text("Samples observed locally: \(captureSession.samplesObserved)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Account & encrypted sync") {
                    Text(appModel.status.label)
                        .foregroundStyle(.secondary)
                    Text(appModel.syncHealthSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Account service URL", text: $appModel.authURL)
                        .autocorrectionDisabled()
                    TextField("Email", text: $appModel.email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                    TextField("Email code", text: $appModel.verificationCode)
                        .textContentType(.oneTimeCode)
                    HStack {
                        Button("Send sign-in code") { appModel.requestSignInCode() }
                        Button("Verify & connect") { appModel.verifySignInCode() }
                    }
                    if let authMessage = appModel.authMessage {
                        Text(authMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Sync relay URL", text: $appModel.relayURL)
                        .autocorrectionDisabled()
                    TextField("Device name", text: $appModel.displayName)
                    Button(appModel.isConnected ? "Sync now" : "Connect & sync") {
                        appModel.connectAndSync()
                    }
                    if appModel.isConnected {
                        Button("Refresh devices") { appModel.refreshDevices() }
                        Button(appModel.isRotatingKey ? "Rotating encryption key…" : "Rotate encryption key") {
                            appModel.rotateEncryptionKey()
                        }
                        .disabled(appModel.isRotatingKey)
                        Text("Approved devices receive the new key before this device activates it. Previous key versions remain available for replay.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Sign out", role: .destructive) {
                            // ReplayKit may continue delivering frames until
                            // its session is explicitly stopped. End capture
                            // before removing the account that owns derived
                            // event writes.
                            captureSession.stop()
                            appModel.signOut()
                        }
                        ForEach(appModel.devices, id: \.deviceID) { device in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.displayName)
                                    Text("\(device.platform) · \(device.status)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.status == "pending" {
                                    Button("Approve") { appModel.approveDevice(device.deviceID) }
                                } else if device.deviceID != appModel.currentDeviceID {
                                    Button("Revoke", role: .destructive) { appModel.revokeDevice(device.deviceID) }
                                }
                            }
                        }
                    } else {
                        Text("This is a local-only workspace. Connect a Dayflow account when you want to sync it across devices.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    SecureField("Recovery passphrase", text: $recoveryPassphrase)
                    HStack {
                        Button("Prepare recovery kit") {
                            appModel.prepareRecoveryKit(passphrase: recoveryPassphrase)
                            recoveryPassphrase = ""
                        }
                        Button("Import recovery kit") {
                            isImportingRecoveryKit = true
                        }
                    }
                    if let recoveryKitText = appModel.recoveryKitText {
                        ShareLink(
                            item: recoveryKitText,
                            subject: Text("Dayflow recovery kit"),
                            message: Text("Keep this kit and its passphrase separate.")
                        ) {
                            Label("Share recovery kit", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let recoveryMessage = appModel.recoveryMessage {
                        Text(recoveryMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("A recovery kit restores the account encryption key. Dayflow never stores its passphrase.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("On-device AI") {
                    TextField("Provider", text: $appModel.providerID)
                    TextField("Endpoint", text: $appModel.providerEndpoint)
                        .autocorrectionDisabled()
                    TextField("Model", text: $appModel.providerModelID)
                    SecureField("API key (if required)", text: $appModel.providerAPIKey)
                    Button("Save provider settings") { appModel.saveProvider() }
                    if let providerMessage = appModel.providerMessage {
                        Text(providerMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Provider routes and secrets stay in this device's secure store and are not synced.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Chat with your local Dayflow context") {
                    TextEditor(text: $appModel.chatQuestion)
                        .frame(minHeight: 70)
                        .overlay(alignment: .topLeading) {
                            if appModel.chatQuestion.isEmpty {
                                Text("Ask what you worked on, what to do next, or what you wrote…")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button(appModel.isChatting ? "Thinking…" : "Ask Dayflow") {
                        appModel.askChat()
                    }
                    .disabled(appModel.isChatting)
                    if let chatMessage = appModel.chatMessage {
                        Text(chatMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let chatAnswer = appModel.chatAnswer {
                        Text(chatAnswer)
                            .textSelection(.enabled)
                    }
                    Text("Only the bounded local projection context is sent to the provider you selected. Dayflow's sync relay is not an inference service.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Dayflow")
            .fileImporter(
                isPresented: $isImportingRecoveryKit,
                allowedContentTypes: [.json, .plainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    do {
                        appModel.restoreRecoveryKit(data: try Data(contentsOf: url), passphrase: recoveryPassphrase)
                        recoveryPassphrase = ""
                    } catch {
                        appModel.reportRecoveryError(error)
                    }
                case .failure(let error):
                    appModel.reportRecoveryError(error)
                }
            }
            .onChange(of: appModel.projection.settings[ActivityCaptureSession.sharedCapturePauseSetting], initial: true) { _, value in
                captureSession.updateSharedCapturePause(value)
            }
        }
    }

    private var statusText: String {
        switch captureSession.state {
        case .idle:
            return "Capture is off."
        case .unavailable(let reason):
            return reason
        case .requestingPermission:
            return "Waiting for the system capture permission…"
        case .running:
            return "Capture is active."
        case .privacyPaused(let reason):
            return reason
        case .stopped(let reason):
            return reason
        }
    }

    private var captureStatusFields: ActivityCaptureStatusFields {
        let paused = ActivityCaptureSession.sharedCapturePauseEnabled(
            appModel.projection.settings[ActivityCaptureSession.sharedCapturePauseSetting]
        )
        return captureSession.statusFields(
            sharedCapturePaused: paused,
            derivedSync: appModel.syncHealthSummary
        )
    }

    private var localRecordState: String {
        if appModel.accountID.isEmpty { return "Local record state: stored on this device; connect an account to sync." }
        if appModel.pendingEventCount > 0 {
            return "Local record state: \(appModel.pendingEventCount) encrypted event(s) pending sync."
        }
        return "Local record state: projection is up to date with the last sync."
    }
}
