import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

struct RecordingPrivacyApplication: Identifiable, Equatable, Sendable {
  let name: String
  let bundleIdentifier: String
  let appURL: URL?

  var id: String { bundleIdentifier }

  init(name: String, bundleIdentifier: String, appURL: URL? = nil) {
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.appURL = appURL
  }
}

struct RecordingPrivacySignals: Equatable, Sendable {
  let applicationID: String?
  let applicationName: String?
  let windowTitle: String?
  let privateContext: Bool
  let drmContent: Bool
  let blockedApplication: RecordingPrivacyApplication?
}

// MARK: - Capture source selection

/// The persisted capture scope. IDs are intentionally platform-native and
/// opaque to the shared event model: raw screen content never leaves the Mac,
/// and a source selection is only used to build a local ScreenCaptureKit
/// filter.
enum RecordingCaptureSourceKind: String, CaseIterable, Codable, Identifiable, Sendable {
  case activeDisplay
  case display
  case application
  case window

  var id: String { rawValue }
}

struct RecordingCaptureSource: Codable, Equatable, Identifiable, Sendable {
  let kind: RecordingCaptureSourceKind
  let identifier: UInt32?
  let bundleIdentifier: String?
  let name: String?

  static let activeDisplay = RecordingCaptureSource(kind: .activeDisplay)

  init(
    kind: RecordingCaptureSourceKind,
    identifier: UInt32? = nil,
    bundleIdentifier: String? = nil,
    name: String? = nil
  ) {
    self.kind = kind
    self.identifier = identifier
    self.bundleIdentifier = bundleIdentifier
    self.name = name
  }

  var id: String {
    switch kind {
    case .activeDisplay:
      return "active-display"
    case .display:
      return "display:\(identifier ?? 0)"
    case .application:
      return "application:\(bundleIdentifier ?? name ?? "unknown")"
    case .window:
      return "window:\(identifier ?? 0)"
    }
  }

  var displayName: String {
    switch kind {
    case .activeDisplay:
      return "Active display"
    case .display:
      return name ?? "Display"
    case .application:
      return name ?? bundleIdentifier ?? "Application"
    case .window:
      return name ?? "Window"
    }
  }
}

struct RecordingCaptureOption: Equatable, Identifiable, Sendable {
  let source: RecordingCaptureSource
  let label: String
  let detail: String?

  var id: String { source.id }
}

enum RecordingCapturePreferences {
  static let didChangeNotification = Notification.Name(
    "Dayflow.RecordingCapturePreferences.didChange"
  )

  private static let sourceKey = "recordingCaptureSource"

  static func selectedSource(defaults: UserDefaults = .standard) -> RecordingCaptureSource {
    guard let data = defaults.data(forKey: sourceKey),
      let source = try? JSONDecoder().decode(RecordingCaptureSource.self, from: data)
    else {
      return .activeDisplay
    }

    return source
  }

  static func save(
    _ source: RecordingCaptureSource,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    guard let data = try? JSONEncoder().encode(source) else { return }
    defaults.set(data, forKey: sourceKey)
    notificationCenter.post(
      name: didChangeNotification,
      object: nil,
      userInfo: ["sourceID": source.id]
    )
  }

  static func reset(
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    save(.activeDisplay, defaults: defaults, notificationCenter: notificationCenter)
  }

  /// Returns the local sources that ScreenCaptureKit currently exposes. The
  /// list is a convenience for settings; the recorder resolves the persisted
  /// IDs again at capture time so stale windows/displays never get reused.
  static func availableOptions() async throws -> [RecordingCaptureOption] {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )

    var options: [RecordingCaptureOption] = [
      RecordingCaptureOption(
        source: .activeDisplay,
        label: "Active display",
        detail: "Follows the display under the pointer"
      )
    ]

    let displays = content.displays.sorted { $0.displayID < $1.displayID }
    for (index, display) in displays.enumerated() {
      options.append(
        RecordingCaptureOption(
          source: RecordingCaptureSource(
            kind: .display,
            identifier: display.displayID,
            name: "Display \(index + 1)"
          ),
          label: "Display \(index + 1)",
          detail: "\(display.width) × \(display.height)"
        )
      )
    }

    var seenApplications = Set<String>()
    let applications = content.applications.sorted {
      $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName)
        == .orderedAscending
    }
    for application in applications {
      let bundleIdentifier = application.bundleIdentifier.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      guard !bundleIdentifier.isEmpty, seenApplications.insert(bundleIdentifier).inserted else {
        continue
      }

      options.append(
        RecordingCaptureOption(
          source: RecordingCaptureSource(
            kind: .application,
            bundleIdentifier: bundleIdentifier,
            name: application.applicationName
          ),
          label: application.applicationName,
          detail: "Application"
        )
      )
    }

    let windows = content.windows
      .filter { window in
        window.isOnScreen && window.windowLayer == 0 && window.owningApplication != nil
      }
      .sorted { first, second in
        let firstApp = first.owningApplication?.applicationName ?? ""
        let secondApp = second.owningApplication?.applicationName ?? ""
        let appOrder = firstApp.localizedCaseInsensitiveCompare(secondApp)
        if appOrder != .orderedSame { return appOrder == .orderedAscending }
        return (first.title ?? "Window").localizedCaseInsensitiveCompare(second.title ?? "Window")
          == .orderedAscending
      }

    for window in windows {
      let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let applicationName = window.owningApplication?.applicationName ?? "Application"
      let label = title?.isEmpty == false ? title! : applicationName
      options.append(
        RecordingCaptureOption(
          source: RecordingCaptureSource(
            kind: .window,
            identifier: window.windowID,
            bundleIdentifier: window.owningApplication?.bundleIdentifier,
            name: label
          ),
          label: label,
          detail: "Window · \(applicationName)"
        )
      )
    }

    return options
  }
}

enum RecordingPrivacyPreferences {
  private static let blockedApplicationIdentifiersKey =
    "recordingPrivacyBlockedApplicationIdentifiers"
  private static let blockedWindowTitleFragmentsKey =
    "recordingPrivacyBlockedWindowTitleFragments"
  private static let didSeedDefaultSecretAppsKey = "recordingPrivacyDidSeedDefaultSecretApps"

  /// These are conservative, title-based signals. They are evaluated before
  /// a screenshot is persisted, and they do not claim that every browser or
  /// media window can be identified perfectly by macOS.
  private static let defaultProtectedWindowTitleFragments = [
    "incognito",
    "private browsing",
    "private window",
    "inprivate",
    "guest profile",
    "zoom meeting",
    "google meet",
    "microsoft teams",
    "webex",
    "slack huddle",
    "protected content",
    "drm",
    "netflix",
    "prime video",
    "disney+",
    "hulu",
    "apple tv",
    "hbo max",
    "password",
    "one-time code",
    "verification code",
    "security code",
  ]

  private static let browserBundleIdentifiers: Set<String> = [
    "com.apple.safari",
    "com.google.chrome",
    "com.google.chrome.canary",
    "com.brave.browser",
    "com.microsoft.edgemac",
    "org.mozilla.firefox",
    "com.vivaldi.vivaldi",
    "com.operasoftware.opera",
    "company.thebrowser.browser",
  ]

  private static let privateContextTitleFragments = [
    "incognito",
    "private browsing",
    "private window",
    "inprivate",
    "guest profile",
    "zoom meeting",
    "google meet",
    "microsoft teams",
    "webex",
    "slack huddle",
  ]

  private static let drmTitleFragments = [
    "protected content",
    "drm",
  ]

  private static let defaultSecretAppNames: Set<String> = [
    "1password",
    "authy",
    "bitwarden",
    "dashlane",
    "enpass",
    "keeper",
    "keepassxc",
    "keychain access",
    "lastpass",
    "ledger live",
    "nordpass",
    "passwords",
    "proton pass",
    "secrets",
    "trezor suite",
    "yubico authenticator",
  ]

  private static let defaultSecretBundleHints = [
    "1password",
    "authy",
    "bitwarden",
    "dashlane",
    "enpass",
    "keeper",
    "keepass",
    "keychainaccess",
    "lastpass",
    "ledger",
    "nordpass",
    "passwords",
    "protonpass",
    "secrets",
    "trezor",
    "yubico",
  ]

  static func blockedApplicationIdentifiers(defaults: UserDefaults = .standard) -> [String] {
    let stored = defaults.stringArray(forKey: blockedApplicationIdentifiersKey) ?? []
    return normalizedIdentifiers(from: stored)
  }

  static func blockedApplicationsText(defaults: UserDefaults = .standard) -> String {
    blockedApplicationIdentifiers(defaults: defaults).joined(separator: "\n")
  }

  static func saveBlockedApplicationsText(
    _ text: String,
    defaults: UserDefaults = .standard
  ) {
    saveBlockedApplicationIdentifiers(identifiers(from: text), defaults: defaults)
  }

  static func saveBlockedApplicationIdentifiers(
    _ identifiers: [String],
    defaults: UserDefaults = .standard
  ) {
    defaults.set(normalizedIdentifiers(from: identifiers), forKey: blockedApplicationIdentifiersKey)
  }

  static func blockedWindowTitleFragments(defaults: UserDefaults = .standard) -> [String] {
    normalizedFragments(
      defaultProtectedWindowTitleFragments
        + (defaults.stringArray(forKey: blockedWindowTitleFragmentsKey) ?? [])
    )
  }

  static func saveBlockedWindowTitleFragments(
    _ fragments: [String],
    defaults: UserDefaults = .standard
  ) {
    defaults.set(normalizedFragments(fragments), forKey: blockedWindowTitleFragmentsKey)
  }

  @MainActor
  static func frontmostCaptureSignals(
    defaults: UserDefaults = .standard
  ) -> RecordingPrivacySignals {
    let application = NSWorkspace.shared.frontmostApplication
    return captureSignals(
      applicationID: application?.bundleIdentifier,
      applicationName: application?.localizedName,
      windowTitle: frontmostWindowTitle(for: application?.processIdentifier),
      defaults: defaults
    )
  }

  static func captureSignals(
    applicationID: String?,
    applicationName: String?,
    windowTitle: String?,
    defaults: UserDefaults = .standard
  ) -> RecordingPrivacySignals {
    let blockedApplication: RecordingPrivacyApplication?
    if isApplicationBlocked(
        bundleIdentifier: applicationID,
        applicationName: applicationName,
        defaults: defaults
      )
    {
      blockedApplication = RecordingPrivacyApplication(
        name: applicationName ?? applicationID ?? "Private app",
        bundleIdentifier: applicationID ?? applicationName ?? "private-app"
      )
    } else {
      blockedApplication = nil
    }

    return RecordingPrivacySignals(
      applicationID: applicationID?.lowercased(),
      applicationName: applicationName,
      windowTitle: windowTitle,
      privateContext: inferredPrivateContext(
        applicationID: applicationID,
        applicationName: applicationName,
        windowTitle: windowTitle
      ),
      drmContent: inferredDRMContent(
        applicationID: applicationID,
        applicationName: applicationName,
        windowTitle: windowTitle
      ),
      blockedApplication: blockedApplication
    )
  }

  static func inferredPrivateContext(
    applicationID: String?,
    applicationName: String?,
    windowTitle: String?
  ) -> Bool {
    let applicationMatches = [applicationID, applicationName]
      .compactMap { normalizedIdentifier($0) }
      .contains { browserBundleIdentifiers.contains($0) }
    guard applicationMatches else { return false }
    return containsAnyFragment(windowTitle, fragments: privateContextTitleFragments)
  }

  static func inferredDRMContent(
    applicationID: String?,
    applicationName: String?,
    windowTitle: String?
  ) -> Bool {
    let application = [applicationID, applicationName]
      .compactMap { normalizedIdentifier($0) }
      .joined(separator: " ")
    let looksLikeMediaApplication = browserBundleIdentifiers.contains {
      application.contains($0)
    } || application.contains("player") || application.contains("tv")
    return looksLikeMediaApplication
      && containsAnyFragment(windowTitle, fragments: drmTitleFragments)
  }

  static func seedDefaultSecretApplicationsIfNeeded(
    from applications: [RecordingPrivacyApplication],
    defaults: UserDefaults = .standard
  ) {
    guard !defaults.bool(forKey: didSeedDefaultSecretAppsKey) else { return }

    let defaultIdentifiers = defaultSecretApplicationIdentifiers(in: applications)
    if !defaultIdentifiers.isEmpty {
      saveBlockedApplicationIdentifiers(
        blockedApplicationIdentifiers(defaults: defaults) + defaultIdentifiers,
        defaults: defaults
      )
    }
    defaults.set(true, forKey: didSeedDefaultSecretAppsKey)
  }

  static func identifiers(from text: String) -> [String] {
    normalizedIdentifiers(from: text.components(separatedBy: .newlines))
  }

  static func isApplicationBlocked(
    bundleIdentifier: String?,
    applicationName: String?,
    defaults: UserDefaults = .standard
  ) -> Bool {
    let blocked = Set(blockedApplicationIdentifiers(defaults: defaults))
    guard !blocked.isEmpty else { return false }

    let candidates = [
      normalizedIdentifier(bundleIdentifier),
      normalizedIdentifier(applicationName),
    ].compactMap { $0 }

    return candidates.contains { blocked.contains($0) }
  }

  @MainActor
  static func frontmostBlockedApplication(
    defaults: UserDefaults = .standard
  ) -> RecordingPrivacyApplication? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    guard
      isApplicationBlocked(
        bundleIdentifier: app.bundleIdentifier,
        applicationName: app.localizedName,
        defaults: defaults
      )
    else {
      return nil
    }

    return RecordingPrivacyApplication(
      name: app.localizedName ?? app.bundleIdentifier ?? "Private app",
      bundleIdentifier: app.bundleIdentifier ?? app.localizedName ?? "private-app"
    )
  }

  private static func frontmostWindowTitle(for processID: pid_t?) -> String? {
    guard let processID,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
      else {
      return nil
    }

    for window in windows {
      let ownerID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
      let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
      guard ownerID == processID, layer == 0,
        let title = window[kCGWindowName as String] as? String,
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      else {
        continue
      }
      return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  static func blockedScreenCaptureApplications(
    in content: SCShareableContent,
    defaults: UserDefaults = .standard
  ) -> [SCRunningApplication] {
    content.applications.filter { app in
      isApplicationBlocked(
        bundleIdentifier: app.bundleIdentifier,
        applicationName: app.applicationName,
        defaults: defaults
      )
    }
  }

  @MainActor
  static func runningApplications() -> [RecordingPrivacyApplication] {
    let apps = NSWorkspace.shared.runningApplications.compactMap {
      app -> RecordingPrivacyApplication? in
      guard app.activationPolicy == .regular else { return nil }
      guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else {
        return nil
      }

      return RecordingPrivacyApplication(
        name: app.localizedName ?? bundleIdentifier,
        bundleIdentifier: bundleIdentifier
      )
    }

    var seen = Set<String>()
    return
      apps
      .filter { app in
        let key = normalizedIdentifier(app.bundleIdentifier) ?? app.bundleIdentifier
        return seen.insert(key).inserted
      }
      .sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  static func installedApplications() -> [RecordingPrivacyApplication] {
    let fileManager = FileManager.default
    let roots = applicationSearchRoots(fileManager: fileManager)
    var apps: [RecordingPrivacyApplication] = []

    for root in roots {
      guard
        let enumerator = fileManager.enumerator(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else {
        continue
      }

      for case let url as URL in enumerator {
        guard url.pathExtension == "app" else { continue }
        enumerator.skipDescendants()

        guard let app = installedApplication(from: url) else { continue }
        apps.append(app)
      }
    }

    var seen = Set<String>()
    return
      apps
      .filter { app in
        let key = normalizedIdentifier(app.bundleIdentifier) ?? app.bundleIdentifier
        return seen.insert(key).inserted
      }
      .sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  static func defaultSecretApplicationIdentifiers(
    in applications: [RecordingPrivacyApplication]
  ) -> [String] {
    applications.compactMap { app in
      let name = normalizedIdentifier(app.name) ?? ""
      let compactBundle = (normalizedIdentifier(app.bundleIdentifier) ?? "")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")

      if defaultSecretAppNames.contains(name) {
        return app.bundleIdentifier
      }
      if defaultSecretBundleHints.contains(where: { compactBundle.contains($0) }) {
        return app.bundleIdentifier
      }
      return nil
    }
  }

  private static func normalizedIdentifiers(from values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      guard let normalized = normalizedIdentifier(value) else { return nil }
      return seen.insert(normalized).inserted ? normalized : nil
    }
  }

  private static func normalizedFragments(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      guard let normalized = normalizedIdentifier(value) else { return nil }
      return seen.insert(normalized).inserted ? normalized : nil
    }
  }

  private static func containsAnyFragment(_ value: String?, fragments: [String]) -> Bool {
    guard let normalized = normalizedIdentifier(value) else { return false }
    return fragments.contains { normalized.contains($0) }
  }

  private static func normalizedIdentifier(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed.lowercased()
  }

  private static func applicationSearchRoots(fileManager: FileManager) -> [URL] {
    let paths = [
      "/Applications",
      "/System/Applications",
      NSHomeDirectory() + "/Applications",
    ]

    var seen = Set<String>()
    return paths.compactMap { path in
      let url = URL(fileURLWithPath: path, isDirectory: true)
      guard fileManager.fileExists(atPath: url.path) else { return nil }
      let standardizedPath = url.standardizedFileURL.path
      return seen.insert(standardizedPath).inserted ? url : nil
    }
  }

  private static func installedApplication(from url: URL) -> RecordingPrivacyApplication? {
    guard let bundle = Bundle(url: url),
      let bundleIdentifier = bundle.bundleIdentifier,
      !bundleIdentifier.isEmpty
    else {
      return nil
    }

    let displayName =
      bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
      ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
      ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
      ?? bundle.infoDictionary?["CFBundleName"] as? String
      ?? url.deletingPathExtension().lastPathComponent

    return RecordingPrivacyApplication(
      name: displayName,
      bundleIdentifier: bundleIdentifier,
      appURL: url
    )
  }
}
