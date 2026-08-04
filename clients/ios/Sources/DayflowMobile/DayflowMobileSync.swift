import Foundation

enum DayflowMobileSharedSettingContract {
    static func isAllowedKey(_ key: String) -> Bool {
        key == "dayflow.theme"
            || key == "dayflow.capture.paused"
            || key == "dayflow.logical_day_boundary_hour"
            || isValidDatedKey(key, prefix: "day_goal:")
            || isValidDatedKey(key, prefix: "daily_standup:")
    }

    private static func isValidDatedKey(_ key: String, prefix: String) -> Bool {
        guard key.hasPrefix(prefix) else { return false }
        let day = String(key.dropFirst(prefix.count))
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return false
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: day) else { return false }
        return formatter.string(from: date) == day
    }
}

public struct DayflowMobileRelayDevice: Codable, Equatable, Sendable {
    public let deviceID: String
    public let publicKey: String
    public let signingPublicKey: String
    public let displayName: String
    public let platform: String
    public let status: String
    public let createdAt: Int64
    public let lastSeenAt: Int64
    /// Non-nil only when registration explicitly authorizes first-device key bootstrap.
    public let keyBootstrapRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case publicKey = "public_key"
        case signingPublicKey = "signing_public_key"
        case displayName = "display_name"
        case platform
        case status
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
        case keyBootstrapRequired = "key_bootstrap_required"
    }
}

public struct DayflowMobileRelayWrappedKey: Codable, Equatable, Sendable {
    public let deviceID: String
    public let keyVersion: UInt32
    public let wrappedAccountKey: String
    public let wrappedByDeviceID: String
    public let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case keyVersion = "key_version"
        case wrappedAccountKey = "wrapped_account_key"
        case wrappedByDeviceID = "wrapped_by_device_id"
        case createdAt = "created_at"
    }
}

public struct DayflowMobileRelayPushResponse: Codable, Equatable, Sendable {
    public let acceptedEventIDs: [String]
    public let duplicateEventIDs: [String]
    public let cursor: String
    public let notificationCount: Int

    enum CodingKeys: String, CodingKey {
        case acceptedEventIDs = "accepted_event_ids"
        case duplicateEventIDs = "duplicate_event_ids"
        case cursor
        case notificationCount = "notification_count"
    }
}

public struct DayflowMobileRelayPulledEvent: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let envelope: DayflowEventEnvelope
}

public struct DayflowMobileRelayPullResponse: Codable, Equatable, Sendable {
    public let cursor: String
    public let events: [DayflowMobileRelayPulledEvent]
}

public struct DayflowMobileRelayNotificationHint: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let kind: String
}

public struct DayflowMobileRelayNotificationHintsResponse: Codable, Equatable, Sendable {
    public let cursor: String
    public let hints: [DayflowMobileRelayNotificationHint]
}

public struct DayflowMobilePushRegistrationResult: Codable, Equatable, Sendable {
    public let deviceID: String
    public let platform: String
    public let registered: Bool

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case platform
        case registered
    }
}

public enum DayflowMobileSyncError: LocalizedError, Equatable {
    case invalidResponse
    case invalidEndpoint
    case invalidAccount
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The Dayflow sync relay returned an invalid response."
        case .invalidEndpoint:
            return "Use an HTTPS Dayflow sync relay URL. HTTP is allowed only for localhost development."
        case .invalidAccount:
            return "Sign in to Dayflow before enabling sync on this device."
        case .server(let status, let message):
            return "Sync relay error (\(status)): \(message)"
        }
    }
}

public struct DayflowMobileSyncRelayClient: Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let core: any DayflowCoreBridge

    public init(
        baseURL: URL,
        session: URLSession = DayflowMobileHTTP.noRedirectSession,
        core: any DayflowCoreBridge = UniFFIDayflowCoreBridge()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.core = core
    }

    public func registerDevice(
        deviceID: String,
        publicKey: Data,
        signingPublicKey: Data,
        displayName: String,
        platform: String = "ios",
        token: String,
        recoveryMode: Bool = false
    ) async throws -> DayflowMobileRelayDevice {
        try await request(
            path: "/v1/sync/devices",
            method: "POST",
            token: token,
            deviceID: nil,
            body: try JSONSerialization.data(withJSONObject: [
                "device_id": deviceID,
                "public_key": publicKey.base64EncodedString(),
                "signing_public_key": signingPublicKey.base64EncodedString(),
                "display_name": displayName,
                "platform": platform,
                "recovery_mode": recoveryMode,
            ])
        )
    }

    public func listDevices(token: String) async throws -> [DayflowMobileRelayDevice] {
        try await request(path: "/v1/sync/devices", method: "GET", token: token, deviceID: nil, body: nil)
    }

    public func approveDevice(
        targetDeviceID: String,
        keyVersion: UInt32 = 1,
        wrappedAccountKey: Data,
        token: String,
        approverDeviceID: String,
        signingPrivateKey: Data
    ) async throws -> DayflowMobileRelayDevice {
        try await request(
            path: "/v1/sync/devices/\(encodedPathComponent(targetDeviceID))/approve",
            method: "POST",
            token: token,
            deviceID: approverDeviceID,
            body: try JSONSerialization.data(withJSONObject: [
                "key_version": keyVersion,
                "wrapped_account_key": wrappedAccountKey.base64EncodedString(),
                "wrapped_by_device_id": approverDeviceID,
            ]),
            signingPrivateKey: signingPrivateKey
        )
    }

    public func revokeDevice(
        targetDeviceID: String,
        token: String,
        actorDeviceID: String,
        signingPrivateKey: Data
    ) async throws -> DayflowMobileRelayDevice {
        try await request(
            path: "/v1/sync/devices/\(encodedPathComponent(targetDeviceID))/revoke",
            method: "POST",
            token: token,
            deviceID: actorDeviceID,
            body: nil,
            signingPrivateKey: signingPrivateKey
        )
    }

    public func wrappedAccountKey(
        deviceID: String,
        token: String,
        signingPrivateKey: Data
    ) async throws -> DayflowMobileRelayWrappedKey? {
        try await request(
            path: "/v1/sync/devices/\(encodedPathComponent(deviceID))/wrapped-key",
            method: "GET",
            token: token,
            deviceID: deviceID,
            body: nil,
            signingPrivateKey: signingPrivateKey
        )
    }

    public func wrappedAccountKeys(
        deviceID: String,
        token: String,
        signingPrivateKey: Data
    ) async throws -> [DayflowMobileRelayWrappedKey] {
        do {
            return try await request(
                path: "/v1/sync/devices/\(encodedPathComponent(deviceID))/wrapped-keys",
                method: "GET",
                token: token,
                deviceID: deviceID,
                body: nil,
                signingPrivateKey: signingPrivateKey
            )
        } catch let error as DayflowMobileSyncError {
            guard case .server(let status, _) = error, status == 404 else { throw error }
            guard let legacy = try await wrappedAccountKey(
                deviceID: deviceID,
                token: token,
                signingPrivateKey: signingPrivateKey
            ) else { return [] }
            return [legacy]
        }
    }

    public func push(
        envelopes: [DayflowEventEnvelope],
        token: String,
        deviceID: String,
        signingPrivateKey: Data
    ) async throws -> DayflowMobileRelayPushResponse {
        try await request(
            path: "/v1/sync/events",
            method: "POST",
            token: token,
            deviceID: deviceID,
            body: try JSONEncoder().encode(EventBatch(envelopes: envelopes)),
            signingPrivateKey: signingPrivateKey
        )
    }

    public func pull(
        cursor: String?,
        token: String,
        deviceID: String,
        signingPrivateKey: Data
    ) async throws -> DayflowMobileRelayPullResponse {
        var path = "/v1/sync/events?limit=100"
        if let cursor, cursor.isEmpty == false {
            path += "&cursor=\(DayflowMobileHTTP.encodedQueryComponent(cursor))"
        }
        return try await request(
            path: path,
            method: "GET",
            token: token,
            deviceID: deviceID,
            body: nil,
            signingPrivateKey: signingPrivateKey
        )
    }

    /// Pulls content-free wake hints using a cursor separate from encrypted
    /// event replay. Persist the returned cursor only after this response has
    /// decoded successfully.
    public func pullNotificationHints(
        cursor: String?,
        token: String,
        deviceID: String,
        signingPrivateKey: Data
    ) async throws -> DayflowMobileRelayNotificationHintsResponse {
        var path = "/v1/sync/notifications?limit=100"
        if let cursor, cursor.isEmpty == false {
            path += "&cursor=\(DayflowMobileHTTP.encodedQueryComponent(cursor))"
        }
        return try await request(
            path: path,
            method: "GET",
            token: token,
            deviceID: deviceID,
            body: nil,
            signingPrivateKey: signingPrivateKey
        )
    }

    /// Registers an OS push token as a content-free wake address. The relay
    /// never receives journal, capture, or ciphertext content through this
    /// route.
    public func registerPushToken(
        pushToken: String,
        token: String,
        deviceID: String,
        signingPrivateKey: Data
    ) async throws -> DayflowMobilePushRegistrationResult {
        guard pushToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DayflowMobileSyncError.invalidResponse
        }
        return try await request(
            path: "/v1/sync/notifications",
            method: "PUT",
            token: token,
            deviceID: deviceID,
            body: try JSONEncoder().encode(["token": pushToken]),
            signingPrivateKey: signingPrivateKey
        )
    }

    public func unregisterPushToken(
        token: String,
        deviceID: String,
        signingPrivateKey: Data
    ) async throws -> DayflowMobilePushRegistrationResult {
        try await request(
            path: "/v1/sync/notifications",
            method: "DELETE",
            token: token,
            deviceID: deviceID,
            body: nil,
            signingPrivateKey: signingPrivateKey
        )
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        token: String,
        deviceID: String?,
        body: Data?,
        signingPrivateKey: Data? = nil
    ) async throws -> Response {
        guard Self.isAllowedRelayURL(baseURL),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw DayflowMobileSyncError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let deviceID {
            guard let signingPrivateKey, signingPrivateKey.count == 32 else {
                throw DayflowMobileSyncError.invalidResponse
            }
            let timestamp = Int(Date().timeIntervalSince1970)
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let message = try core.canonicalDeviceRequest(
                method: method,
                pathWithQuery: path,
                body: body ?? Data(),
                timestamp: Int64(timestamp),
                nonce: nonce,
                deviceID: deviceID
            )
            let signature = try core.signRequest(message: message, privateKey: signingPrivateKey)
            request.setValue(deviceID, forHTTPHeaderField: "X-Dayflow-Device-ID")
            request.setValue(String(timestamp), forHTTPHeaderField: "X-Dayflow-Device-Timestamp")
            request.setValue(nonce, forHTTPHeaderField: "X-Dayflow-Device-Nonce")
            request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-Dayflow-Device-Signature")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DayflowMobileSyncError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(RelayError.self, from: data))?.message
                ?? "The relay could not complete the request."
            throw DayflowMobileSyncError.server(status: httpResponse.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DayflowMobileSyncError.invalidResponse
        }
    }

    private func encodedPathComponent(_ value: String) -> String {
        // `.urlPathAllowed` includes `/`, which would let a malformed device
        // ID escape the route segment. Device IDs are normally UUIDs, but relay
        // data is still untrusted input and must remain one encoded component.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func isAllowedRelayURL(_ url: URL) -> Bool {
        DayflowMobileHTTP.isAllowedEndpoint(url)
    }
}

public struct DayflowMobileSyncOutcome: Equatable, Sendable {
    public let status: String
    public let pushed: Int
    public let pulled: Int
    public let notificationHints: Int
}

/// Orchestrates the complete offline-first lifecycle for the native iOS
/// client: secure keys, registration, wrapped-key admission, encrypted outbox,
/// cursor pull, and local Rust projection replay.
public final class DayflowMobileSyncSession: @unchecked Sendable {
    public static let localWorkspaceID = "local-workspace-v1"
    private static let physicalDeviceIDKey = "dayflow.mobile.physical-device-id"
    private let store: DayflowMobileLocalSyncStore
    private let keyStore: DayflowMobileKeyStore
    private let core: any DayflowCoreBridge

    public init(
        store: DayflowMobileLocalSyncStore,
        keyStore: DayflowMobileKeyStore = .init(),
        core: any DayflowCoreBridge = UniFFIDayflowCoreBridge()
    ) {
        self.store = store
        self.keyStore = keyStore
        self.core = core
    }

    public func ensureLocalWorkspace() throws {
        if try keyStore.accountKeyRing(accountID: Self.localWorkspaceID) == nil {
            let rootKey = try core.generateAccountRootKey()
            let ring = try DayflowMobileAccountKeyRing(rootKey: rootKey)
            try keyStore.storeAccountKeyRing(ring, accountID: Self.localWorkspaceID)
        }
        _ = Self.deviceIdentifier(accountID: Self.localWorkspaceID)
    }

    /// Re-encrypts signed-out local envelopes into the account outbox. Event
    /// identity remains stable and retries skip event IDs already copied into
    /// the account database, so an interrupted link cannot duplicate records.
    public func linkLocalWorkspace(
        accountID: String,
        destinationKeyRing: DayflowMobileAccountKeyRing
    ) throws {
        guard accountID.isEmpty == false else { throw DayflowMobileSyncError.invalidAccount }
        try ensureLocalWorkspace()
        let localStore = try DayflowMobileLocalSyncStore(accountID: Self.localWorkspaceID)
        let linkedAccount = try localStore.linkedAccountID()
        guard linkedAccount == nil || linkedAccount == accountID else {
            throw DayflowMobileSyncError.invalidAccount
        }
        guard let sourceKeyRing = try keyStore.accountKeyRing(accountID: Self.localWorkspaceID) else {
            return
        }
        let localEnvelopes = try localStore.allEnvelopes()
        for envelope in localEnvelopes {
            let candidate: DayflowEventEnvelope
            if let sourceKey = sourceKeyRing.keyData(for: envelope.keyVersion),
               let destinationKey = destinationKeyRing.keyData(for: envelope.keyVersion),
               sourceKey == destinationKey
            {
                candidate = envelope
            } else {
                candidate = try core.rekey(
                    envelopes: [envelope],
                    sourceKeyRing: sourceKeyRing,
                    destinationKeyRing: destinationKeyRing
                ).first ?? envelope
            }

            if let existing = try store.envelope(eventID: envelope.eventID) {
                if existing != candidate {
                    guard let sourceProjection = try? core.project(
                        envelopes: [envelope],
                        keyRing: sourceKeyRing
                    ), let destinationProjection = try? core.project(
                        envelopes: [existing],
                        keyRing: destinationKeyRing
                    ), sourceProjection == destinationProjection else {
                        throw DayflowMobileLocalSyncStoreError.conflictingEnvelope(envelope.eventID)
                    }
                    // A retry after account-key rotation may find an older,
                    // already-authenticated destination envelope. Preserve it
                    // instead of treating the immutable event as a conflict.
                }
            } else {
                try store.enqueue(candidate)
            }
        }
        if let maximumClock = localEnvelopes.map(\.logicalClock).max() {
            // The local and account stores share one physical device ID.
            // Carry the source clock forward before allocating the next
            // account event so sign-in cannot reuse a logical-clock value.
            try store.ensureLogicalClock(atLeast: maximumClock)
        }
        // Keep local ciphertext and its local key-ring; source mirror untouched
        // makes a crash at any point retryable because secure-store and SQLite
        // commits cannot be atomic.
        try localStore.setLinkedAccountID(accountID)
    }

    public func exportRecoveryKit(accountID: String, passphrase: String) throws -> Data {
        guard let keyRing = try keyStore.accountKeyRing(accountID: accountID) else {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        return try core.exportRecoveryKit(keyRing: keyRing, passphrase: passphrase)
    }

    public func restoreRecoveryKit(accountID: String, kit: Data, passphrase: String) throws {
        let keyRing: DayflowMobileAccountKeyRing
        do {
            keyRing = try core.restoreRecoveryKeyRing(kit: kit, passphrase: passphrase)
        } catch {
            // v1 recovery kits contain one raw root key rather than a key-ring
            // payload. Keep them restorable during the format migration.
            let rootKey = try core.restoreRecoveryKey(kit: kit, passphrase: passphrase)
            guard rootKey.count == 32 else { throw DayflowMobileKeyStoreError.invalidKey }
            keyRing = try DayflowMobileAccountKeyRing(rootKey: rootKey)
        }
        try keyStore.storeAccountKeyRing(keyRing, accountID: accountID)
        UserDefaults.standard.set(true, forKey: Self.recoveryRestorePendingKey(accountID: accountID))
    }

    public func listDevices(token: String, relayURL: URL) async throws -> [DayflowMobileRelayDevice] {
        try await DayflowMobileSyncRelayClient(baseURL: relayURL, core: core).listDevices(token: token)
    }

    public func registerPushToken(
        accountID: String,
        token: String,
        relayURL: URL,
        pushToken: String
    ) async throws -> DayflowMobilePushRegistrationResult {
        guard let signingKeys = keyStore.signingKeyMaterial(accountID: accountID) else {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        return try await DayflowMobileSyncRelayClient(baseURL: relayURL, core: core).registerPushToken(
            pushToken: pushToken,
            token: token,
            deviceID: Self.deviceIdentifier(accountID: accountID),
            signingPrivateKey: signingKeys.privateKey
        )
    }

    public func unregisterPushToken(
        accountID: String,
        token: String,
        relayURL: URL
    ) async throws -> DayflowMobilePushRegistrationResult {
        guard let signingKeys = keyStore.signingKeyMaterial(accountID: accountID) else {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        return try await DayflowMobileSyncRelayClient(baseURL: relayURL, core: core).unregisterPushToken(
            token: token,
            deviceID: Self.deviceIdentifier(accountID: accountID),
            signingPrivateKey: signingKeys.privateKey
        )
    }

    public func approveDevice(
        accountID: String,
        token: String,
        relayURL: URL,
        targetDeviceID: String,
        keyVersion: UInt32? = nil
    ) async throws -> DayflowMobileRelayDevice {
        guard let keyRing = try keyStore.accountKeyRing(accountID: accountID),
              let signingKeys = keyStore.signingKeyMaterial(accountID: accountID)
        else { throw DayflowMobileKeyStoreError.invalidKey }
        let devices = try await listDevices(token: token, relayURL: relayURL)
        guard let target = devices.first(where: { $0.deviceID == targetDeviceID }),
              let publicKey = Data(base64Encoded: target.publicKey)
        else { throw DayflowMobileSyncError.invalidResponse }
        let versions = keyVersion.map { [$0] }
          ?? keyRing.keys.keys.compactMap(UInt32.init).sorted()
        guard versions.isEmpty == false else { throw DayflowMobileKeyStoreError.invalidKey }
        var approvedDevice: DayflowMobileRelayDevice?
        let relay = DayflowMobileSyncRelayClient(baseURL: relayURL, core: core)
        for version in versions {
            guard let rootKey = keyRing.keyData(for: version) else {
                throw DayflowMobileKeyStoreError.invalidKey
            }
            let wrapped = try core.wrapAccountKey(
                accountRootKey: rootKey,
                keyVersion: version,
                recipientDeviceID: targetDeviceID,
                recipientPublicKey: publicKey
            )
            approvedDevice = try await relay.approveDevice(
                targetDeviceID: targetDeviceID,
                keyVersion: version,
                wrappedAccountKey: wrapped,
                token: token,
                approverDeviceID: Self.deviceIdentifier(accountID: accountID),
                signingPrivateKey: signingKeys.privateKey
            )
        }
        guard let approvedDevice else { throw DayflowMobileSyncError.invalidResponse }
        return approvedDevice
    }

    /// Distributes a new account key to every approved peer before committing
    /// it locally. Retaining the previous versions keeps historical events
    /// decryptable after rotation.
    public func rotateEncryptionKey(
        accountID: String,
        token: String,
        relayURL: URL
    ) async throws -> UInt32 {
        guard let currentKeyRing = try keyStore.accountKeyRing(accountID: accountID),
              let signingKeys = keyStore.signingKeyMaterial(accountID: accountID)
        else { throw DayflowMobileKeyStoreError.invalidKey }

        let actorDeviceID = Self.deviceIdentifier(accountID: accountID)
        let candidateKeyRing: DayflowMobileAccountKeyRing
        if let pending = try keyStore.pendingAccountKeyRing(accountID: accountID),
           pending.activeKeyVersion > currentKeyRing.activeKeyVersion {
            candidateKeyRing = pending
        } else {
            keyStore.clearPendingAccountKeyRing(accountID: accountID)
            let currentVersion = currentKeyRing.keys.keys.compactMap(UInt32.init).max() ?? 0
            guard currentVersion < UInt32.max else {
                throw DayflowMobileKeyStoreError.invalidKey
            }
            let nextVersion = currentVersion + 1
            let nextRootKey = try core.generateAccountRootKey()
            candidateKeyRing = try currentKeyRing.adding(nextRootKey, version: nextVersion, active: true)
            try keyStore.storePendingAccountKeyRing(candidateKeyRing, accountID: accountID)
        }
        let nextVersion = candidateKeyRing.activeKeyVersion
        guard let nextRootKey = candidateKeyRing.keyData(for: nextVersion) else {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        let relay = DayflowMobileSyncRelayClient(baseURL: relayURL, core: core)
        let peers = try await listDevices(token: token, relayURL: relayURL).filter {
            $0.status == "approved" && $0.deviceID != actorDeviceID
        }

        for peer in peers {
            guard let publicKey = Data(base64Encoded: peer.publicKey) else {
                throw DayflowMobileSyncError.invalidResponse
            }
            let wrapped = try core.wrapAccountKey(
                accountRootKey: nextRootKey,
                keyVersion: nextVersion,
                recipientDeviceID: peer.deviceID,
                recipientPublicKey: publicKey
            )
            _ = try await relay.approveDevice(
                targetDeviceID: peer.deviceID,
                keyVersion: nextVersion,
                wrappedAccountKey: wrapped,
                token: token,
                approverDeviceID: actorDeviceID,
                signingPrivateKey: signingKeys.privateKey
            )
        }

        try keyStore.storeAccountKeyRing(candidateKeyRing, accountID: accountID)
        keyStore.clearPendingAccountKeyRing(accountID: accountID)
        return nextVersion
    }

    public func revokeDevice(
        accountID: String,
        token: String,
        relayURL: URL,
        targetDeviceID: String
    ) async throws -> DayflowMobileRelayDevice {
        guard let signingKeys = keyStore.signingKeyMaterial(accountID: accountID) else {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        return try await DayflowMobileSyncRelayClient(baseURL: relayURL, core: core).revokeDevice(
            targetDeviceID: targetDeviceID,
            token: token,
            actorDeviceID: Self.deviceIdentifier(accountID: accountID),
            signingPrivateKey: signingKeys.privateKey
        )
    }

    public func enqueueCaptureDerived(
        accountID: String,
        captureID: String,
        day: String,
        startTimestamp: Int64,
        endTimestamp: Int64,
        title: String,
        summary: String,
        category: String,
        source: String = "ios_replaykit",
        derivationMode: String = "privacy_gated_local_metadata"
    ) throws {
        // Capture remains local until the account key has been explicitly
        // admitted. This protects the event writer from stale callers that
        // still hold an account ID after an approval or sign-out transition.
        let workspace = captureWorkspaceID(accountID)
        guard captureID.isEmpty == false, day.isEmpty == false,
              source.isEmpty == false, derivationMode.isEmpty == false,
              let keyRing = try keyStore.accountKeyRing(accountID: workspace),
              let rootKey = keyRing.keyData(for: keyRing.activeKeyVersion)
        else { throw DayflowMobileKeyStoreError.invalidKey }
        let deviceID = Self.deviceIdentifier(accountID: workspace)
        let workspaceStore = try localStore(accountID: workspace)
        defer { _ = workspaceStore }
        let eventID = "\(deviceID):capture:\(captureID)"
        let payload = try JSONSerialization.data(withJSONObject: [
            "kind": "CaptureDerived",
            "value": [
                "id": eventID,
                "day": day,
                "start_timestamp": startTimestamp,
                "end_timestamp": endTimestamp,
                "title": title,
                "summary": summary,
                "category": category,
                "source": source,
                "derivation_mode": derivationMode,
              ],
        ], options: [.sortedKeys])
        try workspaceStore.enqueue(core.seal(
            payload: payload,
            eventID: eventID,
            deviceID: deviceID,
            logicalClock: try workspaceStore.nextLogicalClock(),
            keyVersion: keyRing.activeKeyVersion,
            accountRootKey: rootKey
        ))
    }

    public func enqueueJournal(accountID: String, day: String, body: String) throws {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = workspaceID(accountID)
        guard day.isEmpty == false, normalizedBody.isEmpty == false,
              let keyRing = try keyStore.accountKeyRing(accountID: workspace),
              let rootKey = keyRing.keyData(for: keyRing.activeKeyVersion)
        else { throw DayflowMobileKeyStoreError.invalidKey }
        let deviceID = Self.deviceIdentifier(accountID: workspace)
        let workspaceStore = try localStore(accountID: workspace)
        defer { _ = workspaceStore }
        let eventID = "\(deviceID):journal:\(UUID().uuidString.lowercased())"
        let aggregateID = "mac:v1:journal:\(day)"
        let payload = try JSONSerialization.data(withJSONObject: [
            "kind": "JournalUpsert",
            "value": ["id": aggregateID, "day": day, "body": normalizedBody],
        ], options: [.sortedKeys])
        try workspaceStore.enqueue(core.seal(
            payload: payload,
            eventID: eventID,
            deviceID: deviceID,
            logicalClock: try workspaceStore.nextLogicalClock(),
            keyVersion: keyRing.activeKeyVersion,
            accountRootKey: rootKey
        ))
    }

    public func enqueuePriority(
        accountID: String,
        day: String,
        text: String,
        rank: Int,
        status: String = "open",
        stableID: String? = nil
    ) throws {
        let normalizedDay = day.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "open"
            : status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedDay.isEmpty == false, normalizedText.isEmpty == false, rank >= 0 else {
            throw DayflowMobileSyncError.invalidAccount
        }
        let deviceID = Self.deviceIdentifier(accountID: workspaceID(accountID))
        let eventID = "\(deviceID):priority:\(UUID().uuidString.lowercased())"
        let requestedStableID = stableID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let aggregateID = requestedStableID?.isEmpty == false
            ? requestedStableID!
            : "dayflow:v1:priority:\(UUID().uuidString.lowercased())"
        let payload = try JSONSerialization.data(withJSONObject: [
            "kind": "PriorityUpsert",
            "value": [
                "id": aggregateID,
                "day": normalizedDay,
                "rank": rank,
                "text": normalizedText,
                "status": normalizedStatus,
            ],
        ], options: [.sortedKeys])
        try enqueuePayload(accountID: accountID, eventID: eventID, payload: payload)
    }

    public func enqueueReflection(accountID: String, day: String, body: String) throws {
        let normalizedDay = day.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedDay.isEmpty == false, normalizedBody.isEmpty == false else {
            throw DayflowMobileSyncError.invalidAccount
        }
        let deviceID = Self.deviceIdentifier(accountID: workspaceID(accountID))
        let eventID = "\(deviceID):reflection:\(UUID().uuidString.lowercased())"
        let payload = try JSONSerialization.data(withJSONObject: [
            "kind": "ReflectionUpsert",
            "value": [
                // Keep the logical-day aggregate compatible with the Mac
                // writer so a reflection edit converges across clients.
                "id": "mac:v1:reflection:\(normalizedDay)",
                "day": normalizedDay,
                "body": normalizedBody,
            ],
        ], options: [.sortedKeys])
        try enqueuePayload(accountID: accountID, eventID: eventID, payload: payload)
    }

    /// Append a deletion operation for a stable projection aggregate. Deletes
    /// remain replayable events so another device can converge without a
    /// destructive snapshot overwrite.
    public func enqueueTombstone(accountID: String, targetID: String) throws {
        let normalizedTargetID = targetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTargetID.isEmpty == false else {
            throw DayflowMobileSyncError.invalidAccount
        }
        let deviceID = Self.deviceIdentifier(accountID: workspaceID(accountID))
        let eventID = "\(deviceID):tombstone:\(UUID().uuidString.lowercased())"
        let payload = try JSONSerialization.data(withJSONObject: [
            "kind": "Tombstone",
            "value": ["target_id": normalizedTargetID],
        ], options: [.sortedKeys])
        try enqueuePayload(accountID: accountID, eventID: eventID, payload: payload)
    }

    public func enqueueSetting(accountID: String, key: String, value: String) throws {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKey.isEmpty == false,
              DayflowMobileSharedSettingContract.isAllowedKey(normalizedKey)
        else { throw DayflowMobileSyncError.invalidAccount }
        if normalizedKey == "dayflow.capture.paused",
           normalizedValue != "true",
           normalizedValue != "false"
        {
            throw DayflowMobileSyncError.invalidAccount
        }
        let deviceID = Self.deviceIdentifier(accountID: workspaceID(accountID))
        let eventID = "\(deviceID):setting:\(UUID().uuidString.lowercased())"
        let payload = try JSONSerialization.data(withJSONObject: [
            "kind": "SettingUpsert",
            "value": [
                "key": normalizedKey,
                "value": normalizedValue,
            ],
        ], options: [.sortedKeys])
        try enqueuePayload(accountID: accountID, eventID: eventID, payload: payload)
    }

    private func enqueuePayload(accountID: String, eventID: String, payload: Data) throws {
        let workspace = workspaceID(accountID)
        guard let keyRing = try keyStore.accountKeyRing(accountID: workspace),
              let rootKey = keyRing.keyData(for: keyRing.activeKeyVersion)
        else { throw DayflowMobileKeyStoreError.invalidKey }
        let deviceID = Self.deviceIdentifier(accountID: workspace)
        let workspaceStore = try localStore(accountID: workspace)
        defer { _ = workspaceStore }
        try workspaceStore.enqueue(core.seal(
            payload: payload,
            eventID: eventID,
            deviceID: deviceID,
            logicalClock: try workspaceStore.nextLogicalClock(),
            keyVersion: keyRing.activeKeyVersion,
            accountRootKey: rootKey
        ))
    }

    public func localProjection(accountID: String) throws -> DayflowMobileProjection {
        let workspace = workspaceID(accountID)
        guard let keyRing = try keyStore.accountKeyRing(accountID: workspace) else {
            throw DayflowMobileKeyStoreError.invalidKey
        }
        let workspaceStore = try localStore(accountID: workspace)
        defer { _ = workspaceStore }
        let json = try core.project(envelopes: try workspaceStore.allEnvelopes(), keyRing: keyRing)
        return try JSONDecoder().decode(DayflowMobileProjection.self, from: Data(json.utf8))
    }

    public func hasLocalAccountKey(accountID: String) -> Bool {
        (try? keyStore.accountKeyRing(accountID: workspaceID(accountID))) != nil
    }

    private func workspaceID(_ accountID: String) -> String {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? Self.localWorkspaceID : normalized
    }

    private func captureWorkspaceID(_ accountID: String) -> String {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              keyStore.hasAccountKeyAdmission(accountID: normalized)
        else { return Self.localWorkspaceID }
        return normalized
    }

    private func localStore(accountID: String) throws -> DayflowMobileLocalSyncStore {
        try DayflowMobileLocalSyncStore(accountID: workspaceID(accountID))
    }

    public func pendingEventCount() throws -> Int {
        try store.pendingCount()
    }

    public func syncHealth() throws -> DayflowMobileSyncHealth {
        try store.syncHealth()
    }

    public func recordSyncHealth(
        _ state: DayflowMobileSyncHealthState,
        failureCode: String? = nil
    ) throws {
        try store.recordSyncHealth(state, failureCode: failureCode)
    }

    public func sync(
        accountID: String,
        token: String,
        relayURL: URL,
        displayName: String,
        recoveryMode: Bool = false
    ) async throws -> DayflowMobileSyncOutcome {
        guard accountID.isEmpty == false, token.isEmpty == false else {
            throw DayflowMobileSyncError.invalidAccount
        }
        do {
        let deviceID = Self.deviceIdentifier(accountID: accountID)
        let deviceKeys: (privateKey: Data, publicKey: Data)
        if let existing = keyStore.deviceKeyMaterial(accountID: accountID) {
            deviceKeys = existing
        } else {
            let generated = try core.generateDeviceKeyMaterial()
            try keyStore.storeDeviceKeyMaterial(
                privateKey: generated.privateKey,
                publicKey: generated.publicKey,
                accountID: accountID
            )
            deviceKeys = generated
        }
        let signingKeys: (privateKey: Data, publicKey: Data)
        if let existing = keyStore.signingKeyMaterial(accountID: accountID) {
            signingKeys = existing
        } else {
            let generated = try core.generateDeviceSigningKeyMaterial()
            try keyStore.storeSigningKeyMaterial(
                privateKey: generated.privateKey,
                publicKey: generated.publicKey,
                accountID: accountID
            )
            signingKeys = generated
        }

        let client = DayflowMobileSyncRelayClient(baseURL: relayURL, core: core)
        let recoveryRegistration = recoveryMode
            || UserDefaults.standard.bool(forKey: Self.recoveryRestorePendingKey(accountID: accountID))
        let registration = try await client.registerDevice(
            deviceID: deviceID,
            publicKey: deviceKeys.publicKey,
            signingPublicKey: signingKeys.publicKey,
            displayName: displayName,
            token: token,
            recoveryMode: recoveryRegistration
        )
        guard registration.status == "approved" else {
            try store.recordSyncHealth(.waitingForApproval)
            return DayflowMobileSyncOutcome(status: "waiting_for_approval", pushed: 0, pulled: 0, notificationHints: 0)
        }
        var keyRing = try keyStore.accountKeyRing(accountID: accountID)
        if registration.keyBootstrapRequired == true {
            if keyRing == nil {
                let generated = try core.generateAccountRootKey()
                guard generated.count == 32 else { throw DayflowMobileKeyStoreError.invalidKey }
                keyRing = try DayflowMobileAccountKeyRing(rootKey: generated)
                try keyStore.storeAccountKeyRing(keyRing!, accountID: accountID)
            }
            // Preserve explicit first-device admission after the one-time
            // bootstrap grant is consumed by the first accepted event.
            try keyStore.markAccountKeyAdmitted(accountID: accountID)
        }
        let wrappedKeys = try await client.wrappedAccountKeys(
            deviceID: deviceID,
            token: token,
            signingPrivateKey: signingKeys.privateKey
        )
        if keyRing != nil,
           registration.keyBootstrapRequired != true,
           recoveryRegistration == false,
           keyStore.hasAccountKeyAdmission(accountID: accountID) == false,
           wrappedKeys.isEmpty
        {
            throw DayflowMobileSyncError.server(
                status: 409,
                message: "This local account key was not admitted by the sync relay. Restore a recovery kit or receive an approved device key before syncing."
            )
        }
        for wrapped in wrappedKeys {
          guard let wrappedData = Data(base64Encoded: wrapped.wrappedAccountKey) else {
            throw DayflowMobileSyncError.invalidResponse
          }
            let wrappedDocument = try JSONSerialization.jsonObject(with: wrappedData) as? [String: Any]
            let authenticatedVersion = (wrappedDocument?["key_version"] as? NSNumber)?.uint32Value ?? 1
            let recipientDeviceID = wrappedDocument?["recipient_device_id"] as? String
            guard wrapped.deviceID == deviceID,
                  recipientDeviceID == deviceID,
                  authenticatedVersion == wrapped.keyVersion
            else {
                throw DayflowMobileSyncError.invalidResponse
            }
            let wrappedRootKey = try core.unwrapAccountKey(
                wrappedKey: wrappedData,
                privateKey: deviceKeys.privateKey
            )
            if let existing = keyRing {
                if let existingKey = existing.keyData(for: authenticatedVersion) {
                    guard existingKey == wrappedRootKey else {
                        throw DayflowMobileSyncError.invalidResponse
                    }
                } else {
                    keyRing = try existing.adding(
                        wrappedRootKey,
                        version: authenticatedVersion,
                        active: authenticatedVersion > existing.activeKeyVersion
                    )
                }
            } else {
                keyRing = try DayflowMobileAccountKeyRing(
                    activeKeyVersion: authenticatedVersion,
                    keyData: [authenticatedVersion: wrappedRootKey]
                )
            }
            try keyStore.storeAccountKeyRing(keyRing!, accountID: accountID)
            try keyStore.markAccountKeyAdmitted(accountID: accountID)
        }
        if keyRing == nil {
            throw DayflowMobileSyncError.server(
                status: 409,
                message: "The encrypted account key was not delivered. Restore a Dayflow recovery kit or approve this device from an existing device."
            )
        }
        guard let keyRing else { throw DayflowMobileKeyStoreError.invalidKey }
        if recoveryRegistration {
            try keyStore.markAccountKeyAdmitted(accountID: accountID)
        }

        try linkLocalWorkspace(accountID: accountID, destinationKeyRing: keyRing)

        var pushed = 0
        while true {
            let pending = try store.pending()
            guard pending.isEmpty == false else { break }
            let response = try await client.push(
                envelopes: pending,
                token: token,
                deviceID: deviceID,
                signingPrivateKey: signingKeys.privateKey
            )
            let acknowledged = response.acceptedEventIDs + response.duplicateEventIDs
            pushed += try store.acknowledge(eventIDs: acknowledged)
            if acknowledged.isEmpty { break }
        }

        var cursor = try store.cursor()
        var pulled = 0
        while true {
            let response = try await client.pull(
                cursor: cursor,
                token: token,
                deviceID: deviceID,
                signingPrivateKey: signingKeys.privateKey
            )
            let envelopes = response.events.map(\.envelope)
            // Authenticate before persistence. Projecting one envelope at a
            // time also catches a changed ciphertext for an already-known ID.
            for envelope in envelopes {
                _ = try core.project(envelopes: [envelope], keyRing: keyRing)
            }
            pulled += try store.merge(envelopes)
            cursor = response.cursor
            try store.setCursor(response.cursor)
            if response.events.isEmpty { break }
        }
        var notificationHintCount = 0
        do {
            let hintResponse = try await client.pullNotificationHints(
                cursor: try store.notificationCursor(),
                token: token,
                deviceID: deviceID,
                signingPrivateKey: signingKeys.privateKey
            )
            notificationHintCount = hintResponse.hints.count
            try store.setNotificationCursor(hintResponse.cursor)
        } catch {
            // Hints are advisory wake signals. Keep the encrypted event sync
            // successful and retry the unchanged hint cursor next time.
            print("⚠️ [DayflowMobile] Notification hints unavailable: \(error)")
        }
        _ = try core.project(envelopes: try store.allEnvelopes(), keyRing: keyRing)
        try store.recordSyncHealth(.synced)
        // Keep recovery registration enabled until the complete encrypted
        // sync succeeds. A later network, projection, or local-write failure
        // must remain retryable as a recovery restore.
        if recoveryRegistration {
            UserDefaults.standard.removeObject(forKey: Self.recoveryRestorePendingKey(accountID: accountID))
        }
        return DayflowMobileSyncOutcome(
            status: "synced",
            pushed: pushed,
            pulled: pulled,
            notificationHints: notificationHintCount
        )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? store.recordSyncHealth(.failed, failureCode: syncFailureCode(error))
            throw error
        }
    }

    public static func deviceIdentifier(accountID: String) -> String {
        let key = physicalDeviceIDKey
        if let existing = UserDefaults.standard.string(forKey: key), existing.isEmpty == false {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private static func recoveryRestorePendingKey(accountID: String) -> String {
        "dayflow.mobile.recovery-restore-pending.\(accountID)"
    }

    private func syncFailureCode(_ error: Error) -> String {
        if let relayError = error as? DayflowMobileSyncError {
            switch relayError {
            case .server(let status, _):
                if status == 401 || status == 403 { return "authentication" }
                if status == 409 { return "admission" }
                return status >= 500 ? "relay_server" : "invalid_response"
            case .invalidEndpoint, .invalidResponse:
                return "invalid_response"
            case .invalidAccount:
                return "authentication"
            }
        }
        if error is DayflowMobileLocalSyncStoreError { return "local_storage" }
        if error is URLError { return "relay_server" }
        return "unknown"
    }
}

private struct EventBatch: Encodable {
    let envelopes: [DayflowEventEnvelope]
}

private struct RelayError: Decodable {
    let message: String
}
