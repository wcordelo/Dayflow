import Foundation
import ScreenCaptureKit
import SwiftUI

private enum DayflowLocalWorkspaceLinkError: LocalizedError {
  case conflictingEnvelope(String)
  case enqueueFailed(String)

  var errorDescription: String? {
    switch self {
    case .conflictingEnvelope(let eventID):
      return "The local workspace conflicts with account event \(eventID)."
    case .enqueueFailed(let eventID):
      return "Dayflow could not copy local event \(eventID) into the account outbox."
    }
  }
}

struct DayflowMacStatusFields: Equatable, Sendable {
  let capturePermission: String
  let captureSession: String
  let capturePaused: String
  let derivedSync: String

  static let capturePermissionKey = "capture_permission"
  static let captureSessionKey = "capture_session"
  static let capturePausedKey = "capture_paused"
  static let derivedSyncKey = "derived_sync"

  var asDictionary: [String: String] {
    [
      Self.capturePermissionKey: capturePermission,
      Self.captureSessionKey: captureSession,
      Self.capturePausedKey: capturePaused,
      Self.derivedSyncKey: derivedSync,
    ]
  }
}

@MainActor
final class DayflowMultiDeviceViewModel: ObservableObject {
  /// The app delegate and Connected Devices settings must observe the same
  /// sync state. A second view model could show stale approval, migration,
  /// or capture-pause status while the resident sync model was already active.
  static let shared = DayflowMultiDeviceViewModel()

  @Published private(set) var preview = DayflowMigrationPreview(
    dayCount: 0,
    timelineCardCount: 0,
    journalEntryCount: 0,
    dailyStandupCount: 0,
    priorityCount: 0,
    dayGoalCount: 0,
    migratedRecordCount: 0,
    pendingEventCount: 0
  )
  @Published private(set) var syncStatus = DayflowSyncStatus.initial
  @Published private(set) var hasAccountRootKey = false
  @Published private(set) var captureStatus = "Checking capture permissions…"
  @Published private(set) var isSharedCapturePaused = false
  @Published private(set) var relayStatus = "Relay not configured"
  @Published private(set) var approvedDeviceCount = 0
  @Published private(set) var devices: [DayflowRelayDevice] = []
  @Published private(set) var isRefreshingDevices = false
  @Published private(set) var isSyncing = false
  @Published private(set) var isBusy = false
  @Published var message: String?
  @Published var errorMessage: String?

  private let keyStore: DayflowMultiDeviceKeyStore
  private let migrationCoordinator: DayflowMigrationCoordinator

  init(
    keyStore: DayflowMultiDeviceKeyStore = .shared,
    migrationCoordinator: DayflowMigrationCoordinator = .init()
  ) {
    self.keyStore = keyStore
    self.migrationCoordinator = migrationCoordinator
    refresh()
  }

  var deviceID: String {
    DayflowDeviceIdentity.currentID
  }

  var shortDeviceID: String {
    String(deviceID.prefix(8))
  }

  func refresh() {
    hasAccountRootKey = keyStore.hasAccountRootKey
    syncStatus = StorageManager.shared.multiDeviceSyncStatus()
    preview = migrationCoordinator.preview()
    captureStatus = currentCaptureStatus()
    isSharedCapturePaused = DayflowSharedCapturePause.isPaused(
      StorageManager.shared.multiDeviceSharedSettingValue(for: DayflowSharedCapturePause.settingKey)
    )
    NotificationCenter.default.post(
      name: .dayflowSharedCapturePauseChanged,
      object: nil,
      userInfo: [
        "paused": isSharedCapturePaused
      ]
    )
    relayStatus = DayflowSyncRelayConfiguration.baseURL == nil
      ? "Relay not configured"
      : relayStatusForCurrentHealth
    if DayflowAuthManager.shared.isSignedIn == false {
      devices = []
      approvedDeviceCount = 0
    }
  }

  var syncHealthSummary: String {
    var parts: [String] = []
    switch syncStatus.lastSyncState {
    case .synced:
      if let date = syncStatus.lastSuccessfulSyncAt {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        parts.append("Last synced \(formatter.localizedString(for: date, relativeTo: Date()))")
      } else {
        parts.append("Synced locally")
      }
    case .waitingForApproval:
      parts.append("Waiting for device approval")
    case .failed:
      parts.append("Last sync failed")
    case .unknown:
      parts.append("Not synced yet")
    }
    if syncStatus.pendingCount > 0 {
      parts.append(
        "\(syncStatus.pendingCount) encrypted event\(syncStatus.pendingCount == 1 ? "" : "s") queued"
      )
    } else if syncStatus.lastSyncState == .synced {
      parts.append("No events queued")
    }
    if let lastFailureCode = syncStatus.lastFailureCode,
      syncStatus.lastSyncState == .failed
    {
      parts.append("Reason: \(lastFailureCode.replacingOccurrences(of: "_", with: " "))")
    }
    return parts.joined(separator: " · ")
  }

  var nativeStatusFields: DayflowMacStatusFields {
    let capturePermission = CGPreflightScreenCaptureAccess() ? "granted" : "denied"
    let captureSession: String
    if PauseManager.shared.isPaused {
      captureSession = "paused"
    } else if AppState.shared.isRecording {
      captureSession = "running"
    } else {
      captureSession = "idle"
    }
    return DayflowMacStatusFields(
      capturePermission: capturePermission,
      captureSession: captureSession,
      capturePaused: (isSharedCapturePaused || PauseManager.shared.isPaused) ? "paused" : "not_paused",
      derivedSync: syncHealthSummary.isEmpty ? "unknown" : syncHealthSummary
    )
  }

  func setSharedCapturePaused(_ paused: Bool) {
    message = nil
    errorMessage = nil

    let accountScope: String
    let keyRing: DayflowAccountKeyRing
    if DayflowAccountIdentity.currentID != nil,
      keyStore.hasAccountKeyAdmission,
      let accountKeyRing = keyStore.loadAccountKeyRing(),
      let currentAccountScope = DayflowMultiDeviceAccountScope.current
    {
      accountScope = currentAccountScope
      keyRing = accountKeyRing
    } else {
      do {
        accountScope = DayflowMultiDeviceAccountScope.localWorkspace
        keyRing = try keyStore.ensureLocalWorkspaceKeyRing()
      } catch {
        errorMessage = error.localizedDescription
        return
      }
    }

    guard DayflowMacEventWriter.appendSetting(
      key: DayflowSharedCapturePause.settingKey,
      value: paused ? "true" : "false"
    ) else {
      errorMessage = "Dayflow could not save the shared capture pause. Try again."
      return
    }

    do {
      let envelopes = try StorageManager.shared.throwingAllMultiDeviceEvents(accountScope: accountScope)
      let projection = try DayflowCoreBridge.shared.project(
        envelopes: envelopes,
        keyRing: keyRing
      )
      _ = try StorageManager.shared.applyMultiDeviceProjection(
        projection,
        accountScope: accountScope
      )
      refresh()
    } catch {
      errorMessage = "The pause was saved locally, but Dayflow could not refresh its capture state."
      refresh()
    }
  }

  func refreshRemoteDevices() {
    guard let baseURL = DayflowSyncRelayConfiguration.baseURL,
      DayflowAuthManager.shared.isSignedIn,
      let token = DayflowAuthManager.shared.sessionToken()
    else {
      devices = []
      approvedDeviceCount = 0
      return
    }

    isRefreshingDevices = true
    Task { [weak self] in
      do {
        let devices = try await DayflowSyncRelayClient(baseURL: baseURL).listDevices(token: token)
        guard let self else { return }
        self.devices = devices
        self.approvedDeviceCount = devices.filter { $0.status == "approved" }.count
        self.isRefreshingDevices = false
      } catch {
        guard let self else { return }
        self.isRefreshingDevices = false
        self.errorMessage = error.localizedDescription
      }
    }
  }

  func enableEncryptedSync() {
    message = nil
    errorMessage = nil
    guard let accountID = DayflowAccountIdentity.currentID else {
      errorMessage = DayflowMigrationError.missingAccount.localizedDescription
      return
    }
    do {
      try DayflowLocalDataAccountBinding.bindIfNeeded(to: accountID)
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    guard DayflowSyncRelayConfiguration.baseURL != nil else {
      errorMessage = "Configure the Dayflow sync relay before enabling encrypted account sync."
      return
    }
    guard DayflowAuthManager.shared.isSignedIn else {
      errorMessage = "Sign in to Dayflow before enabling encrypted account sync."
      return
    }

    // The account root key is created inside performSync only after the relay
    // returns key_bootstrap_required=true. This prevents a second device, or a
    // client that has not completed admission, from silently forking the
    // account encryption key.
    syncNow()
  }

  func migrateExistingData() {
    guard keyStore.hasAccountKeyAdmission else {
      errorMessage = "Finish encrypted sync admission before migrating records into the account workspace."
      return
    }
    guard let keyRing = keyStore.loadAccountKeyRing() else {
      errorMessage = DayflowMigrationError.missingRootKey.localizedDescription
      return
    }

    isBusy = true
    message = nil
    errorMessage = nil
    let coordinator = migrationCoordinator
    let migrationTask = Task.detached(priority: .userInitiated) {
      try coordinator.migrate(keyRing: keyRing)
    }
    Task { [weak self] in
      do {
        let result = try await migrationTask.value
        guard let self else { return }
        self.message = result.migratedRecordCount == 0
          ? "Your local record is already prepared for encrypted sync."
          : "Prepared \(result.migratedRecordCount) local records for encrypted sync."
        self.isBusy = false
        self.refresh()
      } catch {
        guard let self else { return }
        self.errorMessage = error.localizedDescription
        self.isBusy = false
      }
    }
  }

  func exportRecoveryKit(passphrase: String) throws -> Data {
    guard let keyRing = keyStore.loadAccountKeyRing() else {
      throw DayflowMigrationError.missingRootKey
    }
    return try DayflowCoreBridge.shared.exportRecoveryKit(keyRing: keyRing, passphrase: passphrase)
  }

  func restoreRecoveryKit(_ data: Data, passphrase: String) throws {
    let keyRing: DayflowAccountKeyRing
    do {
      keyRing = try DayflowCoreBridge.shared.restoreRecoveryKeyRing(kit: data, passphrase: passphrase)
    } catch {
      // Preserve restore compatibility with v1 kits that contain one root key.
      let rootKey = try DayflowCoreBridge.shared.restoreRecoveryKey(kit: data, passphrase: passphrase)
      keyRing = try DayflowAccountKeyRing(rootKey: rootKey)
    }
    try keyStore.storeAccountKeyRing(keyRing)
    UserDefaults.standard.set(true, forKey: recoveryRestorePendingKey)
    refresh()
    message = "Recovery kit restored on this Mac. Review devices before enabling sync."
  }

  func syncNow() {
    guard isSyncing == false else { return }
    guard let baseURL = DayflowSyncRelayConfiguration.baseURL else {
      errorMessage = DayflowSyncRelayClientError.invalidBaseURL.localizedDescription
      return
    }
    guard DayflowAuthManager.shared.isSignedIn,
      let token = DayflowAuthManager.shared.sessionToken()
    else {
      errorMessage = "Sign in to Dayflow before connecting another device."
      return
    }
    guard let accountID = DayflowAccountIdentity.currentID else {
      errorMessage = DayflowMigrationError.missingAccount.localizedDescription
      return
    }
    let keyRing = keyStore.loadAccountKeyRing()

    isSyncing = true
    isBusy = true
    message = nil
    errorMessage = nil

    Task { [weak self] in
      do {
        let result = try await self?.performSync(
          client: DayflowSyncRelayClient(baseURL: baseURL),
          token: token,
          keyRing: keyRing,
          accountID: accountID
        )
        guard let self else { return }
        relayStatus = result?.status ?? "Sync complete"
        approvedDeviceCount = result?.approvedDeviceCount ?? 0
        message = result?.message
        isSyncing = false
        isBusy = false
        refresh()
      } catch {
        guard let self else { return }
        relayStatus = "Sync failed"
        try? StorageManager.shared.recordMultiDeviceSync(
          state: .failed,
          failureCode: syncFailureCode(for: error)
        )
        syncStatus = StorageManager.shared.multiDeviceSyncStatus()
        errorMessage = error.localizedDescription
        isSyncing = false
        isBusy = false
      }
    }
  }

  /// Reconnects an already enabled account when Dayflow returns to the
  /// foreground. A root key is required so merely signing in or configuring
  /// a relay cannot start an unintended registration/network flow.
  func syncIfConfigured() {
    guard isSyncing == false,
      DayflowSyncRelayConfiguration.baseURL != nil,
      DayflowAuthManager.shared.isSignedIn,
      DayflowAuthManager.shared.sessionToken() != nil,
      keyStore.loadAccountKeyRing() != nil
    else { return }
    syncNow()
  }

  private func performSync(
    client: DayflowSyncRelayClient,
    token: String,
    keyRing: DayflowAccountKeyRing?,
    accountID: String
  ) async throws -> DayflowSyncOutcome {
    let deviceMaterial: (privateKey: Data, publicKey: Data, signingPrivateKey: Data, signingPublicKey: Data)
    if let privateKey = keyStore.loadDevicePrivateKey(),
      let publicKey = keyStore.loadDevicePublicKey(),
      let signingPrivateKey = keyStore.loadDeviceSigningPrivateKey(),
      let signingPublicKey = keyStore.loadDeviceSigningPublicKey(),
      privateKey.count == 32,
      publicKey.count == 32,
      signingPrivateKey.count == 32,
      signingPublicKey.count == 32
    {
      deviceMaterial = (privateKey, publicKey, signingPrivateKey, signingPublicKey)
    } else {
      let generated = try DayflowCoreBridge.shared.generateDeviceKeyMaterial()
      try keyStore.storeDeviceKeyMaterial(
        privateKey: generated.privateKey,
        publicKey: generated.publicKey
      )
      let signing = try DayflowCoreBridge.shared.generateDeviceSigningKeyMaterial()
      try keyStore.storeDeviceSigningKeyMaterial(
        privateKey: signing.privateKey,
        publicKey: signing.publicKey
      )
      deviceMaterial = (
        privateKey: generated.privateKey,
        publicKey: generated.publicKey,
        signingPrivateKey: signing.privateKey,
        signingPublicKey: signing.publicKey
      )
    }
    let deviceID = DayflowDeviceIdentity.currentID
    let recoveryMode = UserDefaults.standard.bool(forKey: recoveryRestorePendingKey)
    let registration = try await client.registerDevice(
      deviceID: deviceID,
      publicKey: deviceMaterial.publicKey,
      signingPublicKey: deviceMaterial.signingPublicKey,
      displayName: Host.current().localizedName ?? "This Mac",
      token: token,
      recoveryMode: recoveryMode
    )
    let devices = try await client.listDevices(token: token)
    let approvedCount = devices.filter { $0.status == "approved" }.count
    guard registration.status == "approved" else {
      try? StorageManager.shared.recordMultiDeviceSync(state: .waitingForApproval)
      return DayflowSyncOutcome(
        status: "Waiting for device approval",
        approvedDeviceCount: approvedCount,
        message: "This Mac is registered. Approve it from an existing Dayflow device before sync can begin."
      )
    }
    var resolvedKeyRing = keyRing
    if registration.keyBootstrapRequired == true {
      if resolvedKeyRing == nil {
        // Only the relay's explicit first-device admission may create a new
        // account key. Later approved devices must receive a wrapped key or a
        // recovery kit; silently generating one here would fork the account.
        let rootKey = try keyStore.createAccountRootKeyIfNeeded()
        resolvedKeyRing = try DayflowAccountKeyRing(rootKey: rootKey)
        try keyStore.storeAccountKeyRing(resolvedKeyRing!)
      }
      // Keep this durable across the relay consuming the one-time bootstrap
      // grant after the first accepted event. Without it, a valid first device
      // would be mistaken for an unadmitted key on its next restart.
      try keyStore.markAccountKeyAdmitted()
    }
    let wrappedKeys = try await client.wrappedAccountKeys(
      deviceID: deviceID,
      token: token,
      signingPrivateKey: deviceMaterial.signingPrivateKey
    )
    if resolvedKeyRing != nil,
      registration.keyBootstrapRequired != true,
      recoveryMode == false,
      keyStore.hasAccountKeyAdmission == false,
      wrappedKeys.isEmpty
    {
      throw DayflowSyncRelayClientError.server(
        status: 409,
        message: "This local account key was not admitted by the sync relay. Restore a recovery kit or receive an approved device key before syncing."
      )
    }
    for wrapped in wrappedKeys {
      guard let wrappedData = Data(base64Encoded: wrapped.wrappedAccountKey) else {
        throw DayflowSyncRelayClientError.invalidResponse
      }
      guard
        let wrappedDocument = try? JSONSerialization.jsonObject(with: wrappedData) as? [String: Any],
        let recipientDeviceID = wrappedDocument["recipient_device_id"] as? String,
        recipientDeviceID == deviceID
      else {
        throw DayflowSyncRelayClientError.invalidResponse
      }
      let unwrapped = try DayflowCoreBridge.shared.unwrapAccountKeyVersioned(
        wrappedKey: wrappedData,
        privateKey: deviceMaterial.privateKey
      )
      guard wrapped.deviceID == deviceID,
        unwrapped.keyVersion == wrapped.keyVersion
      else {
        throw DayflowSyncRelayClientError.invalidResponse
      }
      if let existing = resolvedKeyRing {
        if let existingKey = existing.keyData(for: unwrapped.keyVersion) {
          guard existingKey == unwrapped.rootKey else {
            throw DayflowSyncRelayClientError.invalidResponse
          }
        } else {
          resolvedKeyRing = try existing.adding(
            unwrapped.rootKey,
            version: unwrapped.keyVersion,
            active: unwrapped.keyVersion > existing.activeKeyVersion
          )
        }
      } else {
        resolvedKeyRing = try DayflowAccountKeyRing(
          activeKeyVersion: unwrapped.keyVersion,
          keyData: [unwrapped.keyVersion: unwrapped.rootKey]
        )
      }
      try keyStore.storeAccountKeyRing(resolvedKeyRing!)
      try keyStore.markAccountKeyAdmitted()
      if unwrapped.keyVersion == 1 {
        try keyStore.storeAccountRootKey(unwrapped.rootKey)
      }
    }
    guard let resolvedKeyRing else {
      throw DayflowSyncRelayClientError.server(
        status: 409,
        message: "This device is approved but its encrypted account key has not been delivered yet."
      )
    }
    if recoveryMode {
      try keyStore.markAccountKeyAdmitted()
    }

    let storage = StorageManager.shared
    try linkLocalWorkspace(accountID: accountID, destinationKeyRing: resolvedKeyRing)
    var pushed = 0
    while true {
      let pending = try storage.throwingPendingMultiDeviceEvents(limit: 100)
      guard pending.isEmpty == false else { break }
      let response = try await client.push(
        envelopes: pending,
        token: token,
        deviceID: deviceID,
        signingPrivateKey: deviceMaterial.signingPrivateKey
      )
      let acknowledgedIDs = response.acceptedEventIDs + response.duplicateEventIDs
      pushed += storage.acknowledgeMultiDeviceEvents(acknowledgedIDs)
      if acknowledgedIDs.isEmpty { break }
    }

    var cursor = try storage.multiDeviceRelayCursor()
    var pulled = 0
    while true {
      let response = try await client.pull(
        cursor: cursor,
        token: token,
        deviceID: deviceID,
        signingPrivateKey: deviceMaterial.signingPrivateKey
      )
      let envelopes = response.events.map(\.envelope)
      // Authenticate every newly pulled envelope before it reaches SQLite.
      // Projecting a single envelope makes duplicate delivery safe while still
      // rejecting a changed ciphertext for an existing event ID.
      for envelope in envelopes {
        _ = try DayflowCoreBridge.shared.project(
          envelopes: [envelope],
          keyRing: resolvedKeyRing
        )
      }
      pulled += try storage.mergeMultiDeviceEvents(envelopes)
      cursor = response.cursor
      try storage.setMultiDeviceRelayCursor(response.cursor)
      if response.events.isEmpty { break }
    }

    var notificationHintCount = 0
    do {
      let hintResponse = try await client.pullNotificationHints(
        cursor: storage.multiDeviceNotificationCursor(),
        token: token,
        deviceID: deviceID,
        signingPrivateKey: deviceMaterial.signingPrivateKey
      )
      notificationHintCount = hintResponse.hints.count
      try storage.setMultiDeviceNotificationCursor(hintResponse.cursor)
    } catch {
      // Hints are advisory wake signals. A failed hint pull must not make an
      // otherwise completed encrypted event sync look failed; leaving the
      // cursor unchanged causes the relay to return the hint on the next
      // foreground sync.
      print("⚠️ [MultiDevice] Notification hints unavailable: \(error)")
    }

    let allEnvelopes = try storage.throwingAllMultiDeviceEvents()
    let projection = try DayflowCoreBridge.shared.project(
      envelopes: allEnvelopes,
      keyRing: resolvedKeyRing
    )
    let appliedProjection = try storage.applyMultiDeviceProjection(projection)
    try storage.recordMultiDeviceSync(state: .synced)
    // Keep recovery registration enabled until the complete encrypted sync
    // succeeds. A network, projection, or local-write failure after device
    // registration must remain retryable as a recovery restore.
    if recoveryMode {
      UserDefaults.standard.removeObject(forKey: recoveryRestorePendingKey)
    }

    return DayflowSyncOutcome(
      status: "Synced locally",
      approvedDeviceCount: approvedCount,
      message: "Sync complete: pushed \(pushed) events, received \(pulled), and applied "
        + "\(appliedProjection.timelineCardCount) timeline cards, "
        + "\(appliedProjection.journalEntryCount) journal entries, "
        + "\(appliedProjection.priorityCount) priorities, and "
        + "\(appliedProjection.reflectionCount) reflections, and "
        + "\(appliedProjection.settingCount) settings locally; consumed "
        + "\(notificationHintCount) notification hints."
    )
  }

  /// Copies the signed-out Mac workspace into the admitted account outbox.
  /// The source mirror and key-ring remain untouched so a crash between the
  /// SQLite and Keychain writes can be retried safely.
  private func linkLocalWorkspace(
    accountID: String,
    destinationKeyRing: DayflowAccountKeyRing
  ) throws {
    guard accountID.isEmpty == false else {
      throw DayflowMigrationError.missingAccount
    }

    let localKeyRing = try keyStore.ensureLocalWorkspaceKeyRing()
    let storage = StorageManager.shared
    if let linkedAccount = storage.localWorkspaceLinkedAccountID(), linkedAccount != accountID {
      throw DayflowMigrationError.localDataBoundToAnotherAccount
    }

    let accountScope = DayflowMultiDeviceAccountScope.token(for: accountID)
    guard let accountScope else { throw DayflowMigrationError.missingAccount }
    let localEnvelopes = try storage.throwingAllMultiDeviceEvents(
      accountScope: DayflowMultiDeviceAccountScope.localWorkspace
    )

    for envelope in localEnvelopes {
      let candidate: DayflowEventEnvelope
      if let sourceKey = localKeyRing.keyData(for: envelope.keyVersion),
        let destinationKey = destinationKeyRing.keyData(for: envelope.keyVersion),
        sourceKey == destinationKey
      {
        candidate = envelope
      } else {
        guard let rekeyed = try DayflowCoreBridge.shared.rekey(
          envelopes: [envelope],
          sourceKeyRing: localKeyRing,
          destinationKeyRing: destinationKeyRing
        ).first else {
          throw DayflowCoreBridgeError.coreFailure("Rust returned no re-keyed envelope")
        }
        candidate = rekeyed
      }

      if let existing = try storage.throwingMultiDeviceEvent(
        eventID: envelope.eventID,
        accountScope: accountScope
      ) {
        if existing != candidate {
          let sourceProjection = try DayflowCoreBridge.shared.project(
            envelopes: [envelope],
            keyRing: localKeyRing
          )
          let destinationProjection = try DayflowCoreBridge.shared.project(
            envelopes: [existing],
            keyRing: destinationKeyRing
          )
          guard sourceProjection == destinationProjection else {
            throw DayflowLocalWorkspaceLinkError.conflictingEnvelope(envelope.eventID)
          }
        }
      } else if storage.enqueueMultiDeviceEvent(candidate, accountScope: accountScope) == false {
        throw DayflowLocalWorkspaceLinkError.enqueueFailed(envelope.eventID)
      }
    }

    if let maximumClock = localEnvelopes.map(\.logicalClock).max() {
      // The local and account stores share one physical device ID. Carry the
      // source clock forward before the next account event is allocated.
      try storage.ensureMultiDeviceLogicalClock(
        atLeast: maximumClock,
        accountScope: accountScope
      )
    }

    try storage.setLocalWorkspaceLinkedAccountID(accountID)
  }

  func approveDevice(_ targetDeviceID: String) {
    guard let baseURL = DayflowSyncRelayConfiguration.baseURL else {
      errorMessage = DayflowSyncRelayClientError.invalidBaseURL.localizedDescription
      return
    }
    guard DayflowAuthManager.shared.isSignedIn,
      let token = DayflowAuthManager.shared.sessionToken()
    else {
      errorMessage = "Sign in to Dayflow before approving another device."
      return
    }
    guard let keyRing = keyStore.loadAccountKeyRing()
    else {
      errorMessage = DayflowMigrationError.missingRootKey.localizedDescription
      return
    }
    guard let signingPrivateKey = keyStore.loadDeviceSigningPrivateKey(), signingPrivateKey.count == 32 else {
      errorMessage = "This Mac is missing its device signing key. Run sync again to repair device security."
      return
    }
    guard let target = devices.first(where: { $0.deviceID == targetDeviceID }),
      target.status == "pending",
      let publicKey = Data(base64Encoded: target.publicKey),
      publicKey.count == 32
    else {
      errorMessage = "That device is no longer waiting for approval. Refresh the device list."
      return
    }

    isBusy = true
    message = nil
    errorMessage = nil
    Task { [weak self] in
      do {
        let relay = DayflowSyncRelayClient(baseURL: baseURL)
        let versions = keyRing.keys.keys.compactMap(UInt32.init).sorted()
        guard versions.isEmpty == false else {
          throw DayflowMultiDeviceKeyStoreError.invalidKey
        }
        for version in versions {
          guard let rootKey = keyRing.keyData(for: version) else {
            throw DayflowMultiDeviceKeyStoreError.invalidKey
          }
          let wrapped = try DayflowCoreBridge.shared.wrapAccountKey(
            accountRootKey: rootKey,
            keyVersion: version,
            recipientDeviceID: target.deviceID,
            recipientPublicKey: publicKey
          )
          _ = try await relay.approveDevice(
            targetDeviceID: target.deviceID,
            keyVersion: version,
            wrappedAccountKey: wrapped,
            token: token,
            approverDeviceID: DayflowDeviceIdentity.currentID,
            signingPrivateKey: signingPrivateKey
          )
        }
        guard let self else { return }
        self.message = target.displayName + " is approved. It can now retrieve its encrypted account keys."
        self.isBusy = false
        self.refreshRemoteDevices()
      } catch {
        guard let self else { return }
        self.errorMessage = error.localizedDescription
        self.isBusy = false
      }
    }
  }

  func revokeDevice(_ targetDeviceID: String) {
    guard let baseURL = DayflowSyncRelayConfiguration.baseURL else {
      errorMessage = DayflowSyncRelayClientError.invalidBaseURL.localizedDescription
      return
    }
    guard DayflowAuthManager.shared.isSignedIn,
      let token = DayflowAuthManager.shared.sessionToken()
    else {
      errorMessage = "Sign in to Dayflow before revoking another device."
      return
    }
    guard targetDeviceID != DayflowDeviceIdentity.currentID else {
      errorMessage = "This Mac cannot revoke itself."
      return
    }
    guard let signingPrivateKey = keyStore.loadDeviceSigningPrivateKey(), signingPrivateKey.count == 32 else {
      errorMessage = "This Mac is missing its device signing key. Run sync again to repair device security."
      return
    }

    isBusy = true
    message = nil
    errorMessage = nil
    Task { [weak self] in
      do {
        _ = try await DayflowSyncRelayClient(baseURL: baseURL).revokeDevice(
          targetDeviceID: targetDeviceID,
          token: token,
          actorDeviceID: DayflowDeviceIdentity.currentID,
          signingPrivateKey: signingPrivateKey
        )
        guard let self else { return }
        self.message = "The device was revoked. Its existing local data remains on that device until removed there."
        self.isBusy = false
        self.refreshRemoteDevices()
      } catch {
        guard let self else { return }
        self.errorMessage = error.localizedDescription
        self.isBusy = false
      }
    }
  }

  /// Distribute a new key to every approved peer before making it active on
  /// this Mac. If any peer fails, the candidate remains inactive locally, so
  /// future events cannot strand a device that did not receive the key.
  func rotateEncryptionKey() {
    guard let baseURL = DayflowSyncRelayConfiguration.baseURL else {
      errorMessage = DayflowSyncRelayClientError.invalidBaseURL.localizedDescription
      return
    }
    guard DayflowAuthManager.shared.isSignedIn,
      let token = DayflowAuthManager.shared.sessionToken()
    else {
      errorMessage = "Sign in before rotating the account encryption key."
      return
    }
    guard let currentRing = keyStore.loadAccountKeyRing() else {
      errorMessage = DayflowMigrationError.missingRootKey.localizedDescription
      return
    }
    guard let signingPrivateKey = keyStore.loadDeviceSigningPrivateKey(), signingPrivateKey.count == 32 else {
      errorMessage = "This Mac is missing its device signing key. Run sync again before rotating encryption."
      return
    }

    isBusy = true
    message = nil
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        let candidate: DayflowAccountKeyRing
        if let pending = self.keyStore.loadPendingAccountKeyRing(),
          pending.activeKeyVersion > currentRing.activeKeyVersion
        {
          candidate = pending
        } else {
          self.keyStore.clearPendingAccountKeyRing()
          let currentVersion = currentRing.keys.keys.compactMap(UInt32.init).max() ?? 0
          guard currentVersion < UInt32.max else {
            throw DayflowMultiDeviceKeyStoreError.invalidKey
          }
          let nextVersion = currentVersion + 1
          let newRootKey = try DayflowCoreBridge.shared.generateAccountRootKey()
          candidate = try currentRing.adding(newRootKey, version: nextVersion, active: true)
          try self.keyStore.storePendingAccountKeyRing(candidate)
        }
        let nextVersion = candidate.activeKeyVersion
        guard let newRootKey = candidate.keyData(for: nextVersion) else {
          throw DayflowMultiDeviceKeyStoreError.invalidKey
        }
        let relay = DayflowSyncRelayClient(baseURL: baseURL)
        let peers = try await relay.listDevices(token: token).filter {
          $0.status == "approved" && $0.deviceID != DayflowDeviceIdentity.currentID
        }
        for peer in peers {
          guard let publicKey = Data(base64Encoded: peer.publicKey), publicKey.count == 32 else {
            throw DayflowSyncRelayClientError.invalidResponse
          }
          let wrapped = try DayflowCoreBridge.shared.wrapAccountKey(
            accountRootKey: newRootKey,
            keyVersion: nextVersion,
            recipientDeviceID: peer.deviceID,
            recipientPublicKey: publicKey
          )
          _ = try await relay.approveDevice(
            targetDeviceID: peer.deviceID,
            keyVersion: nextVersion,
            wrappedAccountKey: wrapped,
            token: token,
            approverDeviceID: DayflowDeviceIdentity.currentID,
            signingPrivateKey: signingPrivateKey
          )
        }
        try self.keyStore.storeAccountKeyRing(candidate)
        self.keyStore.clearPendingAccountKeyRing()
        self.message = "Encryption key rotated to version \(nextVersion). \(peers.count) approved device\(peers.count == 1 ? "" : "s") received it."
        self.isBusy = false
        self.refresh()
        self.refreshRemoteDevices()
      } catch {
        self.errorMessage = error.localizedDescription
        self.isBusy = false
      }
    }
  }

  private var recoveryRestorePendingKey: String {
    let accountScope = DayflowMultiDeviceAccountScope.current ?? "unscoped"
    return "dayflowMultiDeviceRecoveryRestorePending:\(accountScope)"
  }

  private var relayStatusForCurrentHealth: String {
    if isSyncing { return "Syncing encrypted events…" }
    switch syncStatus.lastSyncState {
    case .synced: return "Connected"
    case .waitingForApproval: return "Waiting for approval"
    case .failed: return "Sync needs attention"
    case .unknown: return "Ready to connect"
    }
  }

  private func syncFailureCode(for error: Error) -> String {
    if let relayError = error as? DayflowSyncRelayClientError {
      switch relayError {
      case .invalidBaseURL: return "relay_not_configured"
      case .invalidResponse: return "invalid_response"
      case .server(let status, _):
        if status == 401 || status == 403 { return "authentication" }
        if status == 409 { return "admission" }
        return "relay_server"
      }
    }
    if error is DayflowMigrationError { return "local_migration" }
    if error is DayflowCoreBridgeError { return "shared_core" }
    return "unknown"
  }

  private func currentCaptureStatus() -> String {
    guard CGPreflightScreenCaptureAccess() else {
      return "Screen recording permission is required"
    }
    if PauseManager.shared.isPaused {
      return PauseManager.shared.isPausedIndefinitely
        ? "Paused until you resume"
        : "Paused until \(PauseManager.shared.remainingTimeFormatted ?? "the timer expires")"
    }
    if AppState.shared.isRecording {
      return "Capturing locally on this Mac"
    }
    return "Ready; capture is currently off"
  }
}

private struct DayflowSyncOutcome: Sendable {
  let status: String
  let approvedDeviceCount: Int
  let message: String
}
