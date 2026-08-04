import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsMultiDeviceSection: View {
  let isSignedIn: Bool
  let signInAction: () -> Void

  @StateObject private var viewModel = DayflowMultiDeviceViewModel.shared
  @State private var recoveryPassphrase = ""
  @State private var relayURL = ""
  @State private var showingRecoveryPrompt = false
  @State private var pendingRecoveryData: Data?

  var body: some View {
    SettingsSection(
      title: "Connected devices",
      subtitle: "One Dayflow record across native clients. Raw screenshots and recordings stay on their source device."
    ) {
      VStack(alignment: .leading, spacing: 0) {
        accountRow
        relayConfigurationRow
        deviceRow
        devicesRow
        captureRow
        syncRow
        migrationRow
        recoveryRow
        keyRotationRow

        if let message = viewModel.message {
          Text(message)
            .font(.custom("Figtree", size: 12))
            .foregroundColor(SettingsStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
        }
        if let errorMessage = viewModel.errorMessage {
          Text(errorMessage)
            .font(.custom("Figtree", size: 12))
            .foregroundColor(SettingsStyle.destructive)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
        }
      }
    }
    .onAppear {
      relayURL = DayflowSyncRelayConfiguration.baseURL?.absoluteString ?? ""
      viewModel.refresh()
      viewModel.refreshRemoteDevices()
      viewModel.syncIfConfigured()
    }
    .onChange(of: isSignedIn) { _, _ in
      viewModel.refresh()
      viewModel.refreshRemoteDevices()
      viewModel.syncIfConfigured()
    }
    .sheet(isPresented: $showingRecoveryPrompt) {
      recoveryPrompt
        .frame(width: 380)
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
    }
  }

  private var accountRow: some View {
    SettingsRow(
      label: "Dayflow account",
      subtitle: isSignedIn ? "Available for device approval and encrypted relay sync" : "Sign in to connect another device"
    ) {
      if isSignedIn {
        SettingsStatusDot(state: .good, label: "Signed in")
      } else {
        SettingsSecondaryButton(
          title: "Sign in",
          systemImage: "person.crop.circle",
          action: signInAction
        )
      }
    }
  }

  private var deviceRow: some View {
    SettingsRow(
      label: "This Mac",
      subtitle: "Device ID \(viewModel.shortDeviceID) · local-first"
    ) {
      SettingsStatusDot(
        state: viewModel.hasAccountRootKey ? .good : .idle,
        label: viewModel.hasAccountRootKey ? "Encrypted" : "Not connected"
      )
    }
  }

  private var relayConfigurationRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(
        label: "Sync relay",
        subtitle: "Use HTTPS for a deployed relay. HTTP is accepted only for localhost development."
      ) {
        SettingsStatusDot(
          state: DayflowSyncRelayConfiguration.baseURL == nil ? .idle : .good,
          label: DayflowSyncRelayConfiguration.baseURL == nil ? "Not configured" : "Configured"
        )
      }

      HStack(spacing: 10) {
        TextField("https://sync.example.com", text: $relayURL)
          .textFieldStyle(.roundedBorder)
          .font(.custom("Figtree", size: 13))
        SettingsSecondaryButton(title: "Save", systemImage: "checkmark") {
          DayflowSyncRelayConfiguration.setBaseURL(relayURL)
          viewModel.refresh()
          viewModel.refreshRemoteDevices()
        }
      }
      .padding(.top, 10)
    }
  }

  private var captureRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(
        label: "Capture source",
        subtitle: "The Mac captures through ScreenCaptureKit; synced data is derived locally."
      ) {
        SettingsStatusDot(
          state: viewModel.captureStatus.hasPrefix("Capturing") ? .good : .idle,
          label: viewModel.captureStatus
        )
      }

      SettingsRow(
        label: "Pause across devices",
        subtitle: "Stop capture on every connected Dayflow device. Clearing this does not start capture automatically."
      ) {
        SettingsToggle(
          isOn: Binding(
            get: { viewModel.isSharedCapturePaused },
            set: { viewModel.setSharedCapturePaused($0) }
          )
        )
      }

      SettingsMetadata(text: "Capture permission: \(viewModel.nativeStatusFields.capturePermission)")
        .padding(.top, 8)
      SettingsMetadata(text: "Capture session: \(viewModel.nativeStatusFields.captureSession)")
      SettingsMetadata(text: "Capture paused: \(viewModel.nativeStatusFields.capturePaused)")
      SettingsMetadata(text: "Derived sync: \(viewModel.nativeStatusFields.derivedSync)")
    }
  }

  private var devicesRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(
        label: "Device approvals",
        subtitle: "A new device receives the account key only after an existing trusted device approves it."
      ) {
        if viewModel.isRefreshingDevices {
          ProgressView()
            .controlSize(.small)
        } else {
          SettingsMetadata(
            text: viewModel.devices.isEmpty ? "No relay record yet" : deviceCountLabel
          )
        }
      }

      if viewModel.devices.isEmpty {
        Text("Connect this Mac once to register it. Pending devices will appear here for approval.")
          .font(.custom("Figtree", size: 12))
          .foregroundColor(SettingsStyle.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.vertical, 12)
      } else {
        ForEach(viewModel.devices, id: \.deviceID) { device in
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
              Text(device.displayName)
                .font(.custom("Figtree", size: 13))
                .fontWeight(.semibold)
                .foregroundColor(SettingsStyle.text)
              Text("\(device.platform) · \(String(device.deviceID.prefix(8)))")
                .font(.custom("Figtree", size: 11))
                .foregroundColor(SettingsStyle.meta)
            }
            Spacer(minLength: 8)
            if device.status == "pending" {
              SettingsSecondaryButton(
                title: "Approve",
                systemImage: "checkmark.shield",
                isDisabled: !viewModel.hasAccountRootKey || viewModel.isBusy
              ) {
                viewModel.approveDevice(device.deviceID)
              }
            } else if device.status == "approved", device.deviceID != viewModel.deviceID {
              SettingsSecondaryButton(
                title: "Revoke",
                systemImage: "xmark.shield",
                isDisabled: viewModel.isBusy
              ) {
                viewModel.revokeDevice(device.deviceID)
              }
            } else {
              SettingsStatusDot(
                state: deviceStatusState(device.status),
                label: device.deviceID == viewModel.deviceID ? "This Mac" : device.status.capitalized
              )
            }
          }
          .padding(.vertical, 10)
          .overlay(alignment: .bottom) {
            Rectangle()
              .fill(SettingsStyle.divider)
              .frame(height: 1)
          }
        }
      }

      SettingsLinkButton(
        title: viewModel.isRefreshingDevices ? "Refreshing…" : "Refresh devices",
        systemImage: "arrow.clockwise"
      ) {
        viewModel.refreshRemoteDevices()
      }
      .padding(.top, 12)
    }
  }

  private func deviceStatusState(_ status: String) -> SettingsStatusDot.State {
    switch status {
    case "approved": return .good
    case "pending": return .warn
    case "revoked": return .bad
    default: return .idle
    }
  }

  private var deviceCountLabel: String {
    "\(viewModel.devices.count) device\(viewModel.devices.count == 1 ? "" : "s")"
  }

  private var syncRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(
        label: "Encrypted sync",
        subtitle: "The relay stores opaque envelopes only; local projections are rebuilt on-device. A trusted device can deliver this Mac's encrypted account key after approval."
      ) {
        SettingsStatusDot(
          state: syncStatusState,
          label: viewModel.relayStatus
        )
      }

      HStack(spacing: 12) {
        SettingsPrimaryButton(
          title: viewModel.isSyncing ? "Syncing…" : "Sync now",
          systemImage: "arrow.triangle.2.circlepath",
          isLoading: viewModel.isSyncing,
          isDisabled: !isSignedIn || DayflowSyncRelayConfiguration.baseURL == nil,
          action: viewModel.syncNow
        )
        if viewModel.approvedDeviceCount > 0 {
          SettingsMetadata(text: "\(viewModel.approvedDeviceCount) approved device\(viewModel.approvedDeviceCount == 1 ? "" : "s")")
        }
      }
      .padding(.top, 14)

      SettingsMetadata(text: viewModel.syncHealthSummary)
        .padding(.top, 8)
    }
  }

  private var syncStatusState: SettingsStatusDot.State {
    switch viewModel.syncStatus.lastSyncState {
    case .synced: return .good
    case .waitingForApproval: return .warn
    case .failed: return .bad
    case .unknown: return .idle
    }
  }

  private var migrationRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(
        label: "Local record",
        subtitle: viewModel.hasAccountRootKey
          ? migrationSubtitle
          : "On a new device, use Sync now to receive an approved account key before creating a new local one."
      ) {
        SettingsStatusDot(
          state: migrationStatusState,
          label: migrationStatusLabel
        )
      }

      HStack(spacing: 12) {
        if !viewModel.hasAccountRootKey {
          SettingsPrimaryButton(
            title: "Enable encryption",
            systemImage: "lock.shield",
            isLoading: viewModel.isBusy,
            isDisabled: !isSignedIn,
            action: viewModel.enableEncryptedSync
          )
        } else {
          SettingsPrimaryButton(
            title: viewModel.isBusy ? "Preparing…" : "Prepare local data",
            systemImage: "arrow.triangle.2.circlepath",
            isLoading: viewModel.isBusy,
            action: viewModel.migrateExistingData
          )
        }

        SettingsLinkButton(title: "Refresh", systemImage: "arrow.clockwise") {
          viewModel.refresh()
        }
      }
      .padding(.top, 14)
    }
  }

  private var recoveryRow: some View {
    SettingsRow(
      label: "Recovery kit",
      subtitle: "Export an encrypted key backup. The passphrase is never stored by Dayflow."
    ) {
      HStack(spacing: 8) {
        SettingsSecondaryButton(
          title: "Export",
          systemImage: "square.and.arrow.up",
          isDisabled: !viewModel.hasAccountRootKey,
          action: { showingRecoveryPrompt = true }
        )
        SettingsLinkButton(title: "Restore", systemImage: "arrow.down.doc") {
          restoreRecoveryKit()
        }
      }
    }
  }

  private var keyRotationRow: some View {
    SettingsRow(
      label: "Encryption key",
      subtitle: "Rotate only when all currently approved devices can receive the new key. Previous versions stay locally available for historical replay."
    ) {
      SettingsSecondaryButton(
        title: viewModel.isBusy ? "Rotating…" : "Rotate key",
        systemImage: "arrow.triangle.2.circlepath.circle",
        isDisabled: !isSignedIn || DayflowSyncRelayConfiguration.baseURL == nil || !viewModel.hasAccountRootKey || viewModel.isBusy,
        action: viewModel.rotateEncryptionKey
      )
    }
  }

  private var migrationSubtitle: String {
    let preview = viewModel.preview
    if preview.totalRecordCount == 0 {
      return "No existing timeline, journal, standup, priority, or daily-goal records need preparation."
    }
    return "\(preview.migratedRecordCount) of \(preview.totalRecordCount) records prepared · \(viewModel.syncStatus.pendingCount) encrypted events waiting locally"
  }

  private var migrationStatusLabel: String {
    let preview = viewModel.preview
    if preview.totalRecordCount == 0 { return "Ready" }
    if preview.remainingRecordCount == 0 { return "Prepared" }
    return "Local only"
  }

  private var migrationStatusState: SettingsStatusDot.State {
    let preview = viewModel.preview
    if preview.totalRecordCount > 0, preview.remainingRecordCount == 0 { return .good }
    return .idle
  }

  private var recoveryPrompt: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(isRestoringRecovery ? "Restore recovery kit" : "Export recovery kit")
        .font(.custom("Figtree", size: 20))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.text)

      Text(recoveryPromptDescription)
        .font(.custom("Figtree", size: 13))
        .foregroundColor(SettingsStyle.secondary)
        .fixedSize(horizontal: false, vertical: true)

      SecureField("Recovery passphrase", text: $recoveryPassphrase)
        .textFieldStyle(.roundedBorder)

      HStack {
        SettingsLinkButton(title: "Cancel") {
          showingRecoveryPrompt = false
          pendingRecoveryData = nil
          recoveryPassphrase = ""
        }
        Spacer()
        SettingsPrimaryButton(
          title: isRestoringRecovery ? "Restore on this Mac" : "Save recovery kit",
          systemImage: isRestoringRecovery ? "arrow.down.doc" : "square.and.arrow.down",
          isDisabled: recoveryPassphrase.count < 8,
          action: completeRecoveryAction
        )
      }
    }
    .padding(24)
  }

  private var isRestoringRecovery: Bool {
    pendingRecoveryData != nil
  }

  private var recoveryPromptDescription: String {
    if isRestoringRecovery {
      return "Enter the passphrase for this recovery kit. The key will be stored in this Mac's secure Keychain and the passphrase will be discarded."
    }
    return "Choose a passphrase you can keep safe. Anyone with both the downloaded file and this passphrase can restore your Dayflow encryption key."
  }

  private func completeRecoveryAction() {
    if let pendingRecoveryData {
      do {
        try viewModel.restoreRecoveryKit(pendingRecoveryData, passphrase: recoveryPassphrase)
        self.pendingRecoveryData = nil
        recoveryPassphrase = ""
        showingRecoveryPrompt = false
      } catch {
        viewModel.errorMessage = error.localizedDescription
      }
      return
    }
    exportRecoveryKit()
  }

  private func exportRecoveryKit() {
    do {
      let data = try viewModel.exportRecoveryKit(passphrase: recoveryPassphrase)
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = "dayflow-recovery-kit.json"
      panel.begin { response in
        guard response == .OK, let url = panel.url else { return }
        do {
          try data.write(to: url, options: [.atomic])
          Task { @MainActor in
            showingRecoveryPrompt = false
            recoveryPassphrase = ""
            viewModel.message = "Recovery kit saved. Keep it and the passphrase together in a safe place."
          }
        } catch {
          Task { @MainActor in
            viewModel.errorMessage = "Could not save the recovery kit: \(error.localizedDescription)"
          }
        }
      }
    } catch {
      viewModel.errorMessage = error.localizedDescription
    }
  }

  private func restoreRecoveryKit() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      let data: Data
      do {
        data = try Data(contentsOf: url)
      } catch {
        Task { @MainActor in
          viewModel.errorMessage = "Could not read the recovery kit: \(error.localizedDescription)"
        }
        return
      }

      Task { @MainActor in
        recoveryPassphrase = ""
        showingRecoveryPrompt = true
        // The prompt is reused for export, so restoring is completed from the
        // passphrase field's submit action below after the file is held.
        pendingRecoveryData = data
      }
    }
  }

}
