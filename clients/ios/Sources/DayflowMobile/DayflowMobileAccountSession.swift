import Combine
import Foundation

public struct DayflowMobileAccountSession: Codable, Equatable, Sendable {
    public let accountID: String
    public let token: String
    public let authURL: String
    public let email: String
    public let relayURL: String
    public let displayName: String

    public init(
        accountID: String,
        token: String,
        authURL: String = "",
        email: String = "",
        relayURL: String,
        displayName: String
    ) {
        self.accountID = accountID
        self.token = token
        self.authURL = authURL
        self.email = email
        self.relayURL = relayURL
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case accountID
        case token
        case authURL
        case email
        case relayURL
        case displayName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(String.self, forKey: .accountID)
        token = try container.decode(String.self, forKey: .token)
        authURL = try container.decodeIfPresent(String.self, forKey: .authURL) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        relayURL = try container.decode(String.self, forKey: .relayURL)
        displayName = try container.decode(String.self, forKey: .displayName)
    }
}

public struct DayflowMobileAuthResult: Equatable, Sendable {
    public let accountID: String
    public let email: String
    public let token: String
}

public enum DayflowMobileAuthError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidEmail
    case invalidCode
    case server(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter the HTTPS Dayflow account service URL."
        case .invalidEmail: return "Enter a valid email address."
        case .invalidCode: return "Enter the six-digit sign-in code."
        case .server(let status, let message): return "Dayflow sign-in error (\(status)): \(message)"
        case .invalidResponse: return "Dayflow sign-in returned an invalid response."
        }
    }
}

/// Client for the canonical Dayflow email-code auth flow. The relay token is
/// obtained here and then stored only in Keychain by DayflowMobileAccountStore.
public struct DayflowMobileAuthClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = DayflowMobileHTTP.noRedirectSession) {
        self.session = session
    }

    public func requestCode(email: String, endpoint: URL) async throws {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedEmail.contains("@"), normalizedEmail.contains("."), normalizedEmail.contains(" ") == false else {
            throw DayflowMobileAuthError.invalidEmail
        }
        let _: AuthStartResponse = try await send(
            path: "/v1/auth/code/start",
            method: "POST",
            endpoint: endpoint,
            body: try JSONEncoder().encode(AuthStartRequest(email: normalizedEmail))
        )
    }

    public func verifyCode(
        email: String,
        code: String,
        deviceName: String,
        endpoint: URL
    ) async throws -> DayflowMobileAuthResult {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = code.filter(\.isNumber)
        guard normalizedEmail.contains("@"), normalizedEmail.contains("."), normalizedEmail.contains(" ") == false else {
            throw DayflowMobileAuthError.invalidEmail
        }
        guard digits.count == 6 else { throw DayflowMobileAuthError.invalidCode }
        let response: AuthVerifyResponse = try await send(
            path: "/v1/auth/code/verify",
            method: "POST",
            endpoint: endpoint,
            body: try JSONEncoder().encode(AuthVerifyRequest(
                email: normalizedEmail,
                code: digits,
                deviceName: deviceName
            ))
        )
        return DayflowMobileAuthResult(
            accountID: response.user.id,
            email: response.user.email,
            token: response.sessionToken
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        endpoint: URL,
        body: Data
    ) async throws -> Response {
        guard DayflowMobileHTTP.isAllowedEndpoint(endpoint) else {
            throw DayflowMobileAuthError.invalidEndpoint
        }
        guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else {
            throw DayflowMobileAuthError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DayflowMobileAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(AuthErrorResponse.self, from: data))?.messageValue
                ?? "The account service could not complete sign-in."
            throw DayflowMobileAuthError.server(status: http.statusCode, message: message)
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw DayflowMobileAuthError.invalidResponse }
    }
}

private struct AuthStartRequest: Encodable { let email: String }
private struct AuthStartResponse: Decodable { let ok: Bool }
private struct AuthVerifyRequest: Encodable {
    let email: String
    let code: String
    let deviceName: String
    enum CodingKeys: String, CodingKey {
        case email
        case code
        case deviceName = "device_name"
    }
}
private struct AuthVerifyResponse: Decodable {
    let sessionToken: String
    let user: AuthUser
    enum CodingKeys: String, CodingKey { case sessionToken = "session_token"; case user }
}
private struct AuthUser: Decodable { let id: String; let email: String }
private struct AuthErrorResponse: Decodable {
    let message: String?
    let detail: String?
    var messageValue: String { message ?? detail ?? "The account service could not complete sign-in." }
    enum CodingKeys: String, CodingKey { case message; case detail }
}

public enum DayflowMobileAppStatus: Equatable, Sendable {
    case signedOut
    case localOnly
    case ready
    case syncing
    case waitingForApproval
    case synced(String)
    case failed(String)

    public var label: String {
        switch self {
        case .signedOut: return "Not connected"
        case .localOnly: return "Local workspace · offline"
        case .ready: return "Ready to sync"
        case .syncing: return "Syncing encrypted events…"
        case .waitingForApproval: return "Waiting for device approval"
        case .synced(let message): return message
        case .failed(let message): return message
        }
    }
}

/// Stores the active Dayflow session in Keychain. The bearer token is never
/// written to UserDefaults, SQLite, an event envelope, or the relay payload.
public final class DayflowMobileAccountStore: @unchecked Sendable {
    private static let storageAccount = "active-session"
    private static let storageName = "account-session-v1"
    private let keyStore: DayflowMobileKeyStore

    public init(keyStore: DayflowMobileKeyStore = .init()) {
        self.keyStore = keyStore
    }

    public func load() -> DayflowMobileAccountSession? {
        guard let data = keyStore.secret(accountID: Self.storageAccount, name: Self.storageName) else {
            return nil
        }
        return try? JSONDecoder().decode(DayflowMobileAccountSession.self, from: data)
    }

    public func save(_ session: DayflowMobileAccountSession) throws {
        try keyStore.storeSecret(
            JSONEncoder().encode(session),
            accountID: Self.storageAccount,
            name: Self.storageName
        )
    }

    public func clear() {
        keyStore.deleteSecret(accountID: Self.storageAccount, name: Self.storageName)
    }
}

/// App-facing coordinator for account admission, local encrypted sync, device
/// approval, provider storage, and capture-derived event creation.
@MainActor
public final class DayflowMobileAppModel: ObservableObject {
    @Published public var authURL = ""
    @Published public var email = ""
    @Published public var verificationCode = ""
    @Published public private(set) var authMessage: String?
    @Published public var accountID = ""
    @Published public var token = ""
    @Published public var relayURL = ""
    @Published public var displayName = "This iPhone"
    @Published public private(set) var status: DayflowMobileAppStatus = .signedOut
    @Published public private(set) var devices: [DayflowMobileRelayDevice] = []
    @Published public private(set) var projection = DayflowMobileProjection()
    @Published public private(set) var pendingEventCount = 0
    @Published public private(set) var syncHealth = DayflowMobileSyncHealth.initial
    @Published public var journalDay = ""
    @Published public var journalBody = ""
    @Published public private(set) var journalMessage: String?
    @Published public var priorityDay = ""
    @Published public var priorityText = ""
    @Published public private(set) var priorityMessage: String?
    @Published public var reflectionDay = ""
    @Published public var reflectionBody = ""
    @Published public private(set) var reflectionMessage: String?
    @Published public var sharedSettingKey = "dayflow.capture.paused"
    @Published public var sharedSettingValue = "false"
    @Published public private(set) var sharedSettingMessage: String?
    @Published public var providerID = DayflowAIProviderIds.local
    @Published public var providerEndpoint = "http://127.0.0.1:11434"
    @Published public var providerModelID = "llama3.2"
    @Published public var providerAPIKey = ""
    @Published public private(set) var providerMessage: String?
    @Published public var chatQuestion = ""
    @Published public private(set) var chatAnswer: String?
    @Published public private(set) var chatMessage: String?
    @Published public private(set) var isChatting = false
    @Published public private(set) var recoveryKitText: String?
    @Published public private(set) var recoveryMessage: String?
    @Published public private(set) var isRotatingKey = false

    private let accountStore: DayflowMobileAccountStore
    private let keyStore: DayflowMobileKeyStore
    private let providerStore: DayflowAIProviderStore
    private let core: any DayflowCoreBridge
    private var accountSession: DayflowMobileAccountSession?
    private var syncSession: DayflowMobileSyncSession?
    private var localSyncSession: DayflowMobileSyncSession?
    private var syncTask: Task<Void, Never>?
    // APNs tokens are device-local wake addresses. They are deliberately not
    // part of the encrypted event projection or account session persisted in
    // Keychain. A token can rotate at any time, so it is re-registered after
    // the next successful admitted sync.
    private var pendingPushToken: String?
    private var registeredPushToken: String?

    public init(
        accountStore: DayflowMobileAccountStore = .init(),
        keyStore: DayflowMobileKeyStore = .init(),
        core: any DayflowCoreBridge = UniFFIDayflowCoreBridge()
    ) {
        self.accountStore = accountStore
        self.keyStore = keyStore
        self.providerStore = DayflowAIProviderStore(keyStore: keyStore)
        self.core = core
        if let saved = accountStore.load() {
            accountID = saved.accountID
            token = saved.token
            authURL = saved.authURL
            email = saved.email
            relayURL = saved.relayURL
            displayName = saved.displayName
            accountSession = saved
            status = .ready
            journalDay = Self.defaultLogicalDay()
            restoreActiveWorkspace()
        } else {
            status = .localOnly
            journalDay = Self.defaultLogicalDay()
            prepareLocalWorkspace()
        }
    }

    public var isConnected: Bool { accountSession != nil && status != .signedOut }

    public var syncHealthSummary: String {
        syncHealth.summary(pendingEventCount: pendingEventCount)
    }

    public var canCapture: Bool {
        guard let session = try? activeWorkspaceSession() else { return false }
        return session.hasLocalAccountKey(accountID: activeWorkspaceID())
    }

    public var currentDeviceID: String? {
        DayflowMobileSyncSession.deviceIdentifier(accountID: DayflowMobileSyncSession.localWorkspaceID)
    }

    public func connectAndSync() {
        guard syncTask == nil else { return }
        syncTask = Task { @MainActor [weak self] in
            defer { self?.syncTask = nil }
            await self?.performSync()
        }
    }

    /// Reconnects an already stored account when the app returns to the
    /// foreground. This is intentionally a no-op until account-backed sync
    /// has been configured by the user.
    public func syncIfConfigured() {
        guard accountSession != nil,
              accountID.isEmpty == false,
              token.isEmpty == false,
              relayURL.isEmpty == false,
              displayName.isEmpty == false
        else { return }
        connectAndSync()
    }

    /// Runs the same guarded sync used by foreground activation and waits for
    /// it to finish. The iOS remote-notification delegate uses this for the
    /// content-free `sync_available` wake payload; it never receives event or
    /// journal data from the notification itself.
    public func syncForPushWake() async {
        guard accountSession != nil,
              accountID.isEmpty == false,
              token.isEmpty == false,
              relayURL.isEmpty == false,
              displayName.isEmpty == false
        else { return }

        if let existingTask = syncTask {
            await existingTask.value
        } else {
            connectAndSync()
            await syncTask?.value
        }
    }

    /// Stores an APNs token in memory and registers it only after the device
    /// has completed account-key admission. The relay sees only this wake
    /// address and the signed device proof.
    public func setPushToken(_ token: String) {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        pendingPushToken = normalized
        registerPendingPushTokenIfPossible()
    }

    public func requestSignInCode() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let endpoint = try self.validEndpoint(self.authURL)
                try await DayflowMobileAuthClient().requestCode(email: self.email, endpoint: endpoint)
                self.authMessage = "Sign-in code sent. Check your email."
            } catch {
                self.authMessage = error.localizedDescription
            }
        }
    }

    public func verifySignInCode() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let endpoint = try self.validEndpoint(self.authURL)
                let result = try await DayflowMobileAuthClient().verifyCode(
                    email: self.email,
                    code: self.verificationCode,
                    deviceName: self.displayName,
                    endpoint: endpoint
                )
                self.accountID = result.accountID
                self.email = result.email
                self.token = result.token
                self.authMessage = "Signed in. Connecting this device…"
                self.connectAndSync()
            } catch {
                self.authMessage = error.localizedDescription
            }
        }
    }

    public func refreshDevices() {
        Task { @MainActor [weak self] in
            guard let self, let account = self.accountSession else { return }
            do {
                let relay = try self.validRelayURL()
                self.devices = try await self.syncSessionForCurrentAccount()
                    .listDevices(token: account.token, relayURL: relay)
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    public func approveDevice(_ deviceID: String) {
        runDeviceAction { session, account in
            _ = try await session.approveDevice(
                accountID: account.accountID,
                token: account.token,
                relayURL: self.validRelayURL(),
                targetDeviceID: deviceID
            )
        }
    }

    public func revokeDevice(_ deviceID: String) {
        runDeviceAction { session, account in
            _ = try await session.revokeDevice(
                accountID: account.accountID,
                token: account.token,
                relayURL: self.validRelayURL(),
                targetDeviceID: deviceID
            )
        }
    }

    public func rotateEncryptionKey() {
        guard let accountSession else {
            status = .failed("Connect a Dayflow account before rotating the encryption key.")
            return
        }
        guard isRotatingKey == false else { return }
        isRotatingKey = true
        status = .syncing
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRotatingKey = false }
            do {
                let session = try self.syncSessionForCurrentAccount()
                let version = try await session.rotateEncryptionKey(
                    accountID: accountSession.accountID,
                    token: accountSession.token,
                    relayURL: self.validRelayURL()
                )
                self.devices = try await session.listDevices(
                    token: accountSession.token,
                    relayURL: self.validRelayURL()
                )
                self.status = .synced("Encrypted key rotated to version \(version).")
            } catch {
                self.status = .failed("Encryption key rotation failed: \(error.localizedDescription)")
            }
        }
    }

    public func saveProvider() {
        let activeWorkspace = activeWorkspaceID()
        let workspace = activeWorkspace.isEmpty ? DayflowMobileSyncSession.localWorkspaceID : activeWorkspace
        do {
            let configuration = DayflowAIProviderConfiguration(
                providerID: providerID,
                endpoint: providerEndpoint,
                modelID: providerModelID
            )
            try providerStore.save(
                accountID: workspace,
                configuration: configuration,
                apiKey: providerAPIKey
            )
            providerMessage = "Provider settings saved on this device."
        } catch {
            providerMessage = "Provider settings were not saved: \(error.localizedDescription)"
        }
    }

    public func askChat() {
        let question = chatQuestion
        let context = projection.chatContext
        let configuration = DayflowAIProviderConfiguration(
            providerID: providerID,
            endpoint: providerEndpoint,
            modelID: providerModelID
        )
        isChatting = true
        chatMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let answer = try await DayflowMobileAIChatClient(configuration: configuration).answer(
                    question: question,
                    context: context,
                    apiKey: providerAPIKey
                )
                self.chatAnswer = answer
                self.chatMessage = "Answered from local Dayflow context via \(configuration.providerID)."
            } catch {
                self.chatAnswer = nil
                self.chatMessage = error.localizedDescription
            }
            self.isChatting = false
        }
    }

    public func prepareRecoveryKit(passphrase: String) {
        do {
            let session = try recoverySession()
            let data = try session.exportRecoveryKit(accountID: accountID, passphrase: passphrase)
            guard let text = String(data: data, encoding: .utf8) else {
                throw DayflowMobileSyncError.invalidResponse
            }
            recoveryKitText = text
            recoveryMessage = "Recovery kit prepared. Save it somewhere safe and keep its passphrase separate."
        } catch {
            recoveryMessage = error.localizedDescription
        }
    }

    public func restoreRecoveryKit(data: Data, passphrase: String) {
        do {
            let session = try recoverySession()
            try session.restoreRecoveryKit(accountID: accountID, kit: data, passphrase: passphrase)
            recoveryMessage = "Recovery key restored on this device. Connect and review approved devices before syncing."
        } catch {
            recoveryMessage = error.localizedDescription
        }
    }

    public func reportRecoveryError(_ error: Error) {
        recoveryMessage = error.localizedDescription
    }

    public func recordCaptureSample(at timestamp: Int64) {
        do {
            let workspace = activeWorkspaceID()
            let syncSession = try activeWorkspaceSession()
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let offset = Int32(TimeZone.current.secondsFromGMT(for: date) / 60)
            let day = try core.logicalDayKey(
                timestampUnix: timestamp,
                timezoneOffsetMinutes: offset,
                boundaryHour: 4
            )
            try syncSession.enqueueCaptureDerived(
                accountID: workspace,
                captureID: "\(timestamp)-\(UUID().uuidString.lowercased())",
                day: day,
                startTimestamp: timestamp,
                endTimestamp: timestamp,
                title: "iOS activity captured locally",
                summary: "Privacy-approved ReplayKit metadata; no frame was synced.",
                category: "activity_capture",
                source: "ios_replaykit",
                derivationMode: "privacy_gated_local_metadata"
            )
            projection = try syncSession.localProjection(accountID: workspace)
            pendingEventCount = try syncSession.pendingEventCount()
        } catch {
            status = .failed("Local capture event was not queued: \(error.localizedDescription)")
        }
    }

    public func addJournalEntry() {
        do {
            let workspace = activeWorkspaceID()
            let syncSession = try activeWorkspaceSession()
            try syncSession.enqueueJournal(accountID: workspace, day: journalDay, body: journalBody)
            projection = try syncSession.localProjection(accountID: workspace)
            pendingEventCount = try syncSession.pendingEventCount()
            journalBody = ""
            journalMessage = "Saved locally. It will sync as an encrypted event when you connect."
        } catch {
            journalMessage = "Journal entry was not saved: \(error.localizedDescription)"
        }
    }

    public func addPriority() {
        let workspace = activeWorkspaceID()
        let day = priorityDay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? journalDay
            : priorityDay
        let rank = projection.priorities.values
            .filter { $0.day == day }
            .map { $0.rank }
            .max()
            .map { $0 + 1 } ?? 0
        do {
            let syncSession = try activeWorkspaceSession()
            try syncSession.enqueuePriority(
                accountID: workspace,
                day: day,
                text: priorityText,
                rank: rank
            )
            projection = try syncSession.localProjection(accountID: workspace)
            pendingEventCount = try syncSession.pendingEventCount()
            priorityText = ""
            priorityMessage = "Priority saved locally. It will sync as an encrypted event when you connect."
        } catch {
            priorityMessage = "Priority was not saved: \(error.localizedDescription)"
        }
    }

    public func addReflection() {
        let workspace = activeWorkspaceID()
        let day = reflectionDay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? journalDay
            : reflectionDay
        do {
            let syncSession = try activeWorkspaceSession()
            try syncSession.enqueueReflection(
                accountID: workspace,
                day: day,
                body: reflectionBody
            )
            projection = try syncSession.localProjection(accountID: workspace)
            pendingEventCount = try syncSession.pendingEventCount()
            reflectionBody = ""
            reflectionMessage = "Reflection saved locally. It will sync as an encrypted event when you connect."
        } catch {
            reflectionMessage = "Reflection was not saved: \(error.localizedDescription)"
        }
    }

    public func deleteTimelineCard(id: String) {
        deleteRecord(id: id) { message in
            self.journalMessage = message
        } failure: { message in
            self.journalMessage = message
        }
    }

    public func deleteJournalEntry(id: String) {
        deleteRecord(id: id) { message in
            self.journalMessage = message
        } failure: { message in
            self.journalMessage = message
        }
    }

    public func deletePriority(id: String) {
        deleteRecord(id: id) { message in
            self.priorityMessage = message
        } failure: { message in
            self.priorityMessage = message
        }
    }

    public func deleteReflection(id: String) {
        deleteRecord(id: id) { message in
            self.reflectionMessage = message
        } failure: { message in
            self.reflectionMessage = message
        }
    }

    public func saveSharedSetting() {
        do {
            let workspace = activeWorkspaceID()
            let syncSession = try activeWorkspaceSession()
            try syncSession.enqueueSetting(
                accountID: workspace,
                key: sharedSettingKey,
                value: sharedSettingValue
            )
            projection = try syncSession.localProjection(accountID: workspace)
            pendingEventCount = try syncSession.pendingEventCount()
            sharedSettingMessage = "Shared setting saved locally. Provider secrets remain device-only."
        } catch {
            sharedSettingMessage = "Shared setting was not saved: \(error.localizedDescription)"
        }
    }

    private func deleteRecord(
        id: String,
        success: (String) -> Void,
        failure: (String) -> Void
    ) {
        let workspace = activeWorkspaceID()
        do {
            let syncSession = try activeWorkspaceSession()
            try syncSession.enqueueTombstone(accountID: workspace, targetID: id)
            projection = try syncSession.localProjection(accountID: workspace)
            pendingEventCount = try syncSession.pendingEventCount()
            success("Deleted locally. The deletion will sync as an encrypted event.")
        } catch {
            failure("Delete failed: \(error.localizedDescription)")
        }
    }

    public func signOut() {
        unregisterPushTokenIfPossible()
        syncTask?.cancel()
        syncTask = nil
        pendingPushToken = nil
        registeredPushToken = nil
        accountStore.clear()
        accountSession = nil
        syncSession = nil
        devices = []
        pendingEventCount = (try? localWorkspaceSession().pendingEventCount()) ?? 0
        projection = (try? localWorkspaceSession().localProjection(accountID: "")) ?? DayflowMobileProjection()
        syncHealth = (try? localWorkspaceSession().syncHealth()) ?? .initial
        accountID = ""
        token = ""
        authURL = ""
        email = ""
        verificationCode = ""
        authMessage = nil
        relayURL = ""
        status = .localOnly
        journalDay = ""
        journalBody = ""
        journalMessage = nil
        priorityDay = ""
        priorityText = ""
        priorityMessage = nil
        reflectionDay = ""
        reflectionBody = ""
        reflectionMessage = nil
        sharedSettingKey = "dayflow.capture.paused"
        sharedSettingValue = "false"
        sharedSettingMessage = nil
        providerMessage = nil
        chatQuestion = ""
        chatAnswer = nil
        chatMessage = nil
        recoveryKitText = nil
        recoveryMessage = nil
        isRotatingKey = false
        prepareLocalWorkspace()
    }

    private func performSync() async {
        guard Task.isCancelled == false else { return }
        do {
            let session = try makeAccountSession()
            guard Task.isCancelled == false else { return }
            if accountSession?.accountID != session.accountID {
                syncSession = nil
            }
            try accountStore.save(session)
            accountSession = session
            loadProvider(
                accountID: activeWorkspaceID().isEmpty
                    ? DayflowMobileSyncSession.localWorkspaceID
                    : activeWorkspaceID()
            )
            let syncSession = try syncSessionForCurrentAccount()
            status = .syncing
            let result = try await syncSession.sync(
                accountID: session.accountID,
                token: session.token,
                relayURL: try validRelayURL(),
                displayName: session.displayName
            )
            guard Task.isCancelled == false else { return }
            devices = try await syncSession.listDevices(
                token: session.token,
                relayURL: try validRelayURL()
            )
            guard Task.isCancelled == false else { return }
            if result.status == "waiting_for_approval" {
                // A pending device has no account key yet, so projecting here
                // would turn a normal approval wait into a misleading key
                // error. Keep the existing local projection and let the user
                // retry after an approved device delivers the wrapped keys.
                status = .waitingForApproval
                syncHealth = (try? syncSession.syncHealth()) ?? .initial
                loadProvider(accountID: DayflowMobileSyncSession.localWorkspaceID)
                if journalDay.isEmpty { journalDay = Self.defaultLogicalDay() }
                return
            }
            status = .synced("Synced \(result.pushed) sent, \(result.pulled) received, \(result.notificationHints) wake hints consumed")
            projection = try syncSession.localProjection(accountID: session.accountID)
            pendingEventCount = try syncSession.pendingEventCount()
            syncHealth = (try? syncSession.syncHealth()) ?? .initial
            loadProvider(accountID: session.accountID)
            if journalDay.isEmpty { journalDay = Self.defaultLogicalDay() }
            await registerPendingPushTokenIfPossible(
                account: session,
                relayURL: try validRelayURL(),
                syncSession: syncSession
            )
        } catch is CancellationError {
            return
        } catch {
            if let session = self.syncSession {
                self.syncHealth = (try? session.syncHealth()) ?? self.syncHealth
            }
            status = .failed(error.localizedDescription)
        }
    }

    private func makeAccountSession() throws -> DayflowMobileAccountSession {
        let account = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearer = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.isEmpty == false, bearer.isEmpty == false, name.isEmpty == false else {
            throw DayflowMobileSyncError.invalidAccount
        }
        _ = try validRelayURL()
        return DayflowMobileAccountSession(
            accountID: account,
            token: bearer,
            authURL: authURL.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            relayURL: relayURL.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: name
        )
    }

    private func validRelayURL() throws -> URL {
        return try validEndpoint(relayURL)
    }

    private func validEndpoint(_ rawValue: String) throws -> URL {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), DayflowMobileHTTP.isAllowedEndpoint(url) else {
            throw DayflowMobileSyncError.invalidResponse
        }
        return url
    }

    private func syncSessionForCurrentAccount() throws -> DayflowMobileSyncSession {
        guard let accountSession else { throw DayflowMobileSyncError.invalidAccount }
        if let syncSession { return syncSession }
        let store = try DayflowMobileLocalSyncStore(accountID: accountSession.accountID)
        let session = DayflowMobileSyncSession(store: store, keyStore: keyStore, core: core)
        syncSession = session
        return session
    }

    private func localWorkspaceSession() throws -> DayflowMobileSyncSession {
        if let localSyncSession { return localSyncSession }
        let session = DayflowMobileSyncSession(
            store: try DayflowMobileLocalSyncStore(accountID: DayflowMobileSyncSession.localWorkspaceID),
            keyStore: keyStore,
            core: core
        )
        try session.ensureLocalWorkspace()
        localSyncSession = session
        return session
    }

    private func activeWorkspaceSession() throws -> DayflowMobileSyncSession {
        if let accountSession,
           let session = try? syncSessionForCurrentAccount(),
           keyStore.hasAccountKeyAdmission(accountID: accountSession.accountID),
           session.hasLocalAccountKey(accountID: accountSession.accountID)
        {
            return session
        }
        return try localWorkspaceSession()
    }

    private func activeWorkspaceID() -> String {
        guard let accountSession,
              let session = try? syncSessionForCurrentAccount(),
              keyStore.hasAccountKeyAdmission(accountID: accountSession.accountID),
              session.hasLocalAccountKey(accountID: accountSession.accountID)
        else { return "" }
        return accountSession.accountID
    }

    private func prepareLocalWorkspace() {
        do {
            let session = try localWorkspaceSession()
            projection = try session.localProjection(accountID: "")
            pendingEventCount = try session.pendingEventCount()
            syncHealth = try session.syncHealth()
            loadProvider(accountID: DayflowMobileSyncSession.localWorkspaceID)
        } catch {
            status = .failed("Local workspace is unavailable: \(error.localizedDescription)")
        }
    }

    private func restoreActiveWorkspace() {
        do {
            if accountSession != nil, let accountWorkspace = try? syncSessionForCurrentAccount() {
                syncHealth = (try? accountWorkspace.syncHealth()) ?? .initial
            }
            let workspaceSession = try activeWorkspaceSession()
            let workspaceID = activeWorkspaceID()
            projection = try workspaceSession.localProjection(accountID: workspaceID)
            pendingEventCount = try workspaceSession.pendingEventCount()
            if workspaceID.isEmpty == false {
                syncHealth = (try? workspaceSession.syncHealth()) ?? syncHealth
            }
            loadProvider(accountID: workspaceID.isEmpty ? DayflowMobileSyncSession.localWorkspaceID : workspaceID)
        } catch {
            projection = DayflowMobileProjection()
            pendingEventCount = 0
            status = .failed("Local workspace is unavailable: \(error.localizedDescription)")
        }
    }

    private func recoverySession() throws -> DayflowMobileSyncSession {
        let normalizedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedAccountID.isEmpty == false else { throw DayflowMobileSyncError.invalidAccount }
        if let syncSession { return syncSession }
        let store = try DayflowMobileLocalSyncStore(accountID: normalizedAccountID)
        let session = DayflowMobileSyncSession(store: store, keyStore: keyStore, core: core)
        syncSession = session
        return session
    }

    private func loadProvider(accountID: String) {
        guard let configuration = providerStore.load(accountID: accountID) else { return }
        providerID = configuration.providerID
        providerEndpoint = configuration.endpoint
        providerModelID = configuration.modelID
        providerAPIKey = providerStore.loadAPIKey(accountID: accountID) ?? ""
    }

    private func registerPendingPushTokenIfPossible() {
        guard let account = accountSession,
              keyStore.hasAccountKeyAdmission(accountID: account.accountID),
              pendingPushToken != nil,
              pendingPushToken != registeredPushToken
        else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  let account = self.accountSession,
                  let syncSession = self.syncSession,
                  let relayURL = try? self.validRelayURL(),
                  let pushToken = self.pendingPushToken,
                  self.keyStore.hasAccountKeyAdmission(accountID: account.accountID)
            else { return }
            await self.registerPendingPushTokenIfPossible(
                account: account,
                relayURL: relayURL,
                syncSession: syncSession,
                pushToken: pushToken
            )
        }
    }

    private func registerPendingPushTokenIfPossible(
        account: DayflowMobileAccountSession,
        relayURL: URL,
        syncSession: DayflowMobileSyncSession,
        pushToken: String? = nil
    ) async {
        guard let pushToken = pushToken ?? pendingPushToken,
              pushToken != registeredPushToken,
              keyStore.hasAccountKeyAdmission(accountID: account.accountID)
        else { return }
        do {
            _ = try await syncSession.registerPushToken(
                accountID: account.accountID,
                token: account.token,
                relayURL: relayURL,
                pushToken: pushToken
            )
            guard accountSession?.accountID == account.accountID else { return }
            registeredPushToken = pushToken
        } catch {
            // Push is advisory. Foreground activation and the durable relay
            // hint cursor remain the fallback when APNs/dispatcher setup is
            // unavailable or the device is still waiting for approval.
            print("[DayflowMobile] Push token registration unavailable: \(error)")
        }
    }

    private func unregisterPushTokenIfPossible() {
        guard let account = accountSession,
              let syncSession,
              let relayURL = try? validRelayURL(),
              registeredPushToken != nil
        else { return }
        Task { [syncSession, account, relayURL] in
            try? await syncSession.unregisterPushToken(
                accountID: account.accountID,
                token: account.token,
                relayURL: relayURL
            )
        }
    }

    private static func defaultLogicalDay() -> String {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let components = calendar.dateComponents(in: .current, from: now)
        let day = components.hour ?? 0 < 4
            ? calendar.date(byAdding: .day, value: -1, to: now) ?? now
            : now
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    private func runDeviceAction(
        _ action: @escaping (DayflowMobileSyncSession, DayflowMobileAccountSession) async throws -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, let account = self.accountSession else { return }
            do {
                let session = try self.syncSessionForCurrentAccount()
                try await action(session, account)
                self.refreshDevices()
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }
}
