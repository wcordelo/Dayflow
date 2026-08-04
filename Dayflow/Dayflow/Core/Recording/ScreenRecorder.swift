//
//  ScreenRecorder.swift
//  Dayflow
//
//  Rewritten to use SCScreenshotManager for periodic screenshots
//  instead of continuous video capture. This eliminates the screen
//  recording indicator while maintaining the same data flow.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import Sentry

// MARK: - Configuration

/// Global screenshot configuration accessible throughout the app
enum ScreenshotConfig {
  /// Screenshot interval in seconds. Can be changed via UserDefaults.
  /// Used by: ScreenRecorder (capture), VideoProcessingService (compression), LLM providers (timestamp expansion)
  static var interval: TimeInterval {
    let stored = UserDefaults.standard.double(forKey: "screenshotIntervalSeconds")
    return stored > 0 ? stored : 10.0  // Default: 10 seconds
  }
}

private enum Config {
  static let targetHeight: CGFloat = 1080  // Scale screenshots to ~1080p
  static let jpegQuality: CGFloat = 0.85  // Balance quality vs file size

  /// Screenshot interval - references the global config
  static var screenshotInterval: TimeInterval {
    ScreenshotConfig.interval
  }
}

private enum InputIdleSnapshot {
  // Bridge kCGAnyInputEventType into Swift without relying on a generated symbol name.
  static let anyInputEventType = CGEventType(rawValue: UInt32.max)!

  static func currentIdleSeconds() -> Int? {
    // Prefer the HID state table so the signal reflects hardware-originated user input.
    let idleSeconds = CGEventSource.secondsSinceLastEventType(
      .hidSystemState,
      eventType: anyInputEventType
    )
    guard idleSeconds.isFinite, idleSeconds >= 0 else { return nil }
    return Int(idleSeconds.rounded(.down))
  }
}

// MARK: - Debug Logging

private let recorderDebugLogging = false
@inline(__always) func dbg(_ msg: @autoclosure () -> String) {
  guard recorderDebugLogging else { return }
  print("[Recorder] \(msg())")
}

// MARK: - State Machine

/// Explicit state machine for the recorder lifecycle
private enum RecorderState: Equatable {
  case idle  // Not capturing
  case starting  // Initiating capture setup
  case capturing  // Active screenshot timer running
  case paused  // System event pause (sleep/lock), will auto-resume

  var description: String {
    switch self {
    case .idle: return "idle"
    case .starting: return "starting"
    case .capturing: return "capturing"
    case .paused: return "paused"
    }
  }

  var canStart: Bool {
    switch self {
    case .idle, .paused: return true
    case .starting, .capturing: return false
    }
  }
}

// MARK: - Errors

private enum ScreenRecorderError: Error {
  case noDisplay
  case captureSourceUnavailable
  case screenshotFailed
  case imageConversionFailed
}

private enum ResolvedCaptureSource {
  case display(SCDisplay)
  case application(display: SCDisplay, application: SCRunningApplication)
  case window(SCWindow)

  var display: SCDisplay? {
    switch self {
    case .display(let display), .application(let display, _):
      return display
    case .window:
      return nil
    }
  }

  var displayID: CGDirectDisplayID? {
    display?.displayID
  }
}

// MARK: - ScreenRecorder

final class ScreenRecorder: NSObject, @unchecked Sendable {

  // MARK: - Initialization

  @MainActor
  init(autoStart: Bool = true) {
    super.init()
    dbg("init – autoStart = \(autoStart)")

    wantsRecording = AppState.shared.isRecording

    // Observe the app-wide recording flag
    sub = AppState.shared.$isRecording
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] rec in
        self?.q.async { [weak self] in
          guard let self else { return }
          self.wantsRecording = rec

          // Clear paused state when user disables recording
          if !rec && self.state == .paused {
            self.transition(to: .idle, context: "user disabled recording")
          }

          rec ? self.start() : self.stop()
        }
      }

    // Active display tracking
    tracker = ActiveDisplayTracker()
    activeDisplaySub = tracker.$activeDisplayID
      .removeDuplicates()
      .sink { [weak self] newID in
        guard let self, let newID else { return }
        self.q.async { [weak self] in self?.handleActiveDisplayChange(newID) }
      }

    captureSourceSub = NotificationCenter.default.addObserver(
      forName: RecordingCapturePreferences.didChangeNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.q.async { [weak self] in
        self?.handleCaptureSourceChange()
      }
    }

    sharedCapturePauseSub = NotificationCenter.default.addObserver(
      forName: .dayflowSharedCapturePauseChanged,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      let paused = notification.userInfo?["paused"] as? Bool ?? true
      self?.q.async { [weak self] in
        guard let self else { return }
        self.sharedCapturePaused = paused
        if paused {
          self.stop()
        }
      }
    }

    // Honor the current flag once (after subscriptions exist)
    if autoStart, AppState.shared.isRecording { start() }

    registerForSleepAndLock()
  }

  deinit {
    sub?.cancel()
    activeDisplaySub?.cancel()
    if let captureSourceSub {
      NotificationCenter.default.removeObserver(captureSourceSub)
    }
    if let sharedCapturePauseSub {
      NotificationCenter.default.removeObserver(sharedCapturePauseSub)
    }
    dbg("deinit")
  }

  // MARK: - Properties

  private let q = DispatchQueue(label: "com.dayflow.recorder", qos: .userInitiated)
  private var captureTimer: DispatchSourceTimer?
  private var sub: AnyCancellable?
  private var activeDisplaySub: AnyCancellable?
  private var captureSourceSub: NSObjectProtocol?
  private var sharedCapturePauseSub: NSObjectProtocol?
  private var state: RecorderState = .idle
  private var wantsRecording = false
  private var sharedCapturePaused = false
  private var deviceLocked = false
  private var sleeping = false
  private var tracker: ActiveDisplayTracker!
  private var currentDisplayID: CGDirectDisplayID?
  private var requestedCaptureSource = RecordingCaptureSource.activeDisplay
  private var cachedCaptureSource: ResolvedCaptureSource?

  // ScreenCaptureKit objects (refreshed on each capture cycle)
  private var cachedContent: SCShareableContent?

  // MARK: - State Transitions

  private func transition(to newState: RecorderState, context: String? = nil) {
    let oldState = state
    state = newState

    let message =
      context.map { "\(oldState.description) → \(newState.description) (\($0))" }
      ?? "\(oldState.description) → \(newState.description)"
    dbg("State: \(message)")

    let breadcrumb = Breadcrumb(level: .info, category: "recorder_state")
    breadcrumb.message = message
    breadcrumb.data = [
      "old_state": oldState.description,
      "new_state": newState.description,
    ]
    if let ctx = context {
      breadcrumb.data?["context"] = ctx
    }
    SentryHelper.addBreadcrumb(breadcrumb)
  }

  // MARK: - Start/Stop

  func start() {
    q.async { [weak self] in
      guard let self else { return }
      guard self.wantsRecording else {
        dbg("start – suppressed (recording disabled)")
        return
      }
      guard !self.sharedCapturePaused else {
        dbg("start – suppressed (shared capture pause)")
        return
      }
      guard self.state.canStart else {
        dbg("start – invalid state: \(self.state.description)")
        return
      }

      self.transition(to: .starting, context: "user/system start")
      Task { await self.setupCapture() }
    }
  }

  func stop() {
    q.async { [weak self] in
      guard let self else { return }
      self.stopCaptureTimer()
      self.cachedContent = nil
      self.cachedCaptureSource = nil
      self.currentDisplayID = nil

      if self.state != .paused {
        self.transition(to: .idle, context: "stopped")
      }
      dbg("capture stopped")
    }
  }

  // MARK: - Capture Setup

  private func setupCapture(attempt: Int = 1, maxAttempts: Int = 4) async {
    guard ScreenRecordingPermissionNotice.isGranted else {
      handleMissingScreenRecordingPermission(reason: "setupCapture")
      return
    }

    do {
      // 1. Get shareable content (requires screen recording permission)
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      cachedContent = content

      // 2. Resolve the persisted source against this fresh snapshot. A
      // window or application is never silently replaced with another source
      // when it disappears; setup fails explicitly until the user chooses a
      // valid source again.
      let trackerID: CGDirectDisplayID? = await MainActor.run { [weak tracker] in
        tracker?.activeDisplayID
      }
      requestedCaptureSource = RecordingCapturePreferences.selectedSource()
      let resolvedSource = try resolveCaptureSource(
        requestedCaptureSource,
        in: content,
        trackerID: trackerID
      )

      cachedCaptureSource = resolvedSource
      currentDisplayID = resolvedSource.displayID

      switch resolvedSource {
      case .display(let display):
        dbg("Setup complete - display \(display.displayID) (\(display.width)x\(display.height))")
      case .application(let display, let application):
        dbg(
          "Setup complete - application \(application.applicationName) on display "
            + "\(display.displayID)"
        )
      case .window(let window):
        dbg("Setup complete - window \(window.windowID) (\(window.title ?? "untitled"))")
      }

      // 3. Start capture timer
      q.async { [weak self] in
        guard let self else { return }
        guard self.state == .starting else {
          dbg("setupCapture completed but state changed to \(self.state.description), ignoring")
          return
        }
        self.startCaptureTimer()
        self.transition(to: .capturing, context: "capture started")

        // Take first screenshot immediately
        Task { await self.captureScreenshot() }
      }

      Task { @MainActor in
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture("recording_started", ["mode": "screenshot"])
        }
      }

    } catch {
      dbg("setupCapture failed [attempt \(attempt)] – \(error.localizedDescription)")

      if !ScreenRecordingPermissionNotice.isGranted {
        handleMissingScreenRecordingPermission(reason: "setupCapture_failed_permission")
        return
      }

      q.async { [weak self] in
        self?.transition(to: .idle, context: "setupCapture failed")
      }

      let nsError = error as NSError
      let isNoDisplay = (error as? ScreenRecorderError) == .noDisplay

      if isNoDisplay && attempt < maxAttempts {
        let delay = Double(attempt)
        dbg("retrying in \(delay)s")
        q.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
      } else {
        Task { @MainActor in
          AnalyticsService.shared.capture(
            "recording_startup_failed",
            [
              "attempt": attempt,
              "error_domain": nsError.domain,
              "error_code": nsError.code,
            ])
        }
      }
    }
  }

  private func resolveCaptureSource(
    _ source: RecordingCaptureSource,
    in content: SCShareableContent,
    trackerID: CGDirectDisplayID?
  ) throws -> ResolvedCaptureSource {
    let displaysByID = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })

    switch source.kind {
    case .activeDisplay:
      let display = trackerID.flatMap { displaysByID[$0] } ?? content.displays.first
      guard let display else { throw ScreenRecorderError.noDisplay }
      return .display(display)

    case .display:
      guard let identifier = source.identifier, let display = displaysByID[identifier] else {
        throw ScreenRecorderError.captureSourceUnavailable
      }
      return .display(display)

    case .application:
      guard let bundleIdentifier = source.bundleIdentifier,
        let application = content.applications.first(where: {
          $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        })
      else {
        throw ScreenRecorderError.captureSourceUnavailable
      }

      let applicationWindows = content.windows.filter {
        $0.owningApplication?.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier)
          == .orderedSame
      }
      let appDisplay = applicationWindows
        .sorted { $0.isActive && !$1.isActive }
        .compactMap { window in
          content.displays.first { $0.frame.intersects(window.frame) }
        }
        .first
      let display = appDisplay
        ?? trackerID.flatMap { displaysByID[$0] }
        ?? content.displays.first
      guard let display else { throw ScreenRecorderError.noDisplay }
      return .application(display: display, application: application)

    case .window:
      guard let identifier = source.identifier,
        let window = content.windows.first(where: { $0.windowID == identifier }),
        window.isOnScreen,
        window.windowLayer == 0
      else {
        throw ScreenRecorderError.captureSourceUnavailable
      }
      return .window(window)
    }
  }

  // MARK: - Capture Timer

  private func startCaptureTimer() {
    stopCaptureTimer()

    let interval = Config.screenshotInterval
    let timer = DispatchSource.makeTimerSource(queue: q)
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler { [weak self] in
      Task { await self?.captureScreenshot() }
    }
    timer.resume()
    captureTimer = timer

    dbg("Capture timer started (interval: \(interval)s)")
  }

  private func stopCaptureTimer() {
    captureTimer?.cancel()
    captureTimer = nil
  }

  // MARK: - Screenshot Capture

  private func captureScreenshot() async {
    guard state == .capturing else {
      dbg("captureScreenshot skipped - state: \(state.description)")
      return
    }

    // Settings can change while recording. Resolve the new source before the
    // next frame rather than allowing one frame from the old surface through.
    let configuredSource = RecordingCapturePreferences.selectedSource()
    if configuredSource != requestedCaptureSource {
      requestedCaptureSource = configuredSource
      await refreshCaptureSource()
    }

    guard let captureSource = cachedCaptureSource else {
      dbg("captureScreenshot skipped - selected source is unavailable")
      return
    }
    guard ScreenRecordingPermissionNotice.isGranted else {
      handleMissingScreenRecordingPermission(reason: "captureScreenshot")
      return
    }

    let captureTime = Date()
    let idleSecondsAtCapture = InputIdleSnapshot.currentIdleSeconds()

    let frontmost = await MainActor.run {
      RecordingPrivacyPreferences.frontmostCaptureSignals()
    }
    let privacySignals = privacySignals(for: captureSource, fallback: frontmost)
    let privacyDecision: DayflowCaptureDecision
    do {
      privacyDecision = try DayflowCoreBridge.shared.captureDecision(
        context: DayflowCaptureContext(
          permissionGranted: true,
          userPaused: !wantsRecording || sharedCapturePaused,
          deviceLocked: deviceLocked,
          sleeping: sleeping,
          privateContext: privacySignals.privateContext,
          drmContent: privacySignals.drmContent,
          applicationID: privacySignals.applicationID,
          windowTitle: privacySignals.windowTitle
        ),
        policy: DayflowPrivacyPolicy(
          ignorePrivateContext: true,
          pauseOnDRM: true,
          blockedApplicationIDs: RecordingPrivacyPreferences.blockedApplicationIdentifiers(),
          blockedWindowTitleFragments: RecordingPrivacyPreferences.blockedWindowTitleFragments()
        )
      )
    } catch {
      dbg("captureScreenshot paused - shared privacy decision unavailable")
      return
    }
    guard privacyDecision.allowed || privacyDecision.reason == "blocked_application" else {
      dbg("captureScreenshot paused - privacy decision: \(privacyDecision.reason)")
      return
    }

    do {
      let filter: SCContentFilter
      switch captureSource {
      case .display(let display):
        let excludedApplications = cachedContent.map {
          RecordingPrivacyPreferences.blockedScreenCaptureApplications(in: $0)
        } ?? []
        filter = excludedApplications.isEmpty
          ? SCContentFilter(display: display, excludingWindows: [])
          : SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
          )

      case .application(let display, let application):
        filter = SCContentFilter(
          display: display,
          including: [application],
          exceptingWindows: []
        )

      case .window(let window):
        filter = SCContentFilter(desktopIndependentWindow: window)
      }

      let captureSize = scaledCaptureSize(for: captureSource, filter: filter)
      if let blockedApplication = privacySignals.blockedApplication {
        guard
          let jpegData = await MainActor.run(body: {
            RecordingPrivacyPlaceholder.jpegData(
              size: CGSize(width: captureSize.width, height: captureSize.height),
              quality: Config.jpegQuality,
              applicationName: blockedApplication.name
            )
          })
        else {
          throw ScreenRecorderError.imageConversionFailed
        }
        _ = try saveScreenshotData(
          jpegData,
          capturedAt: captureTime,
          idleSecondsAtCapture: idleSecondsAtCapture
        )
        dbg("🔒 Screenshot redacted for blocked foreground application")
        return
      }

      // Configure screenshot
      let config = SCStreamConfiguration()

      config.width = captureSize.width
      config.height = captureSize.height
      config.scalesToFit = true
      config.showsCursor = true

      // Capture screenshot
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: config
      )

      // Convert to JPEG
      guard let jpegData = jpegData(from: image, quality: Config.jpegQuality) else {
        throw ScreenRecorderError.imageConversionFailed
      }

      // Save to disk and register in the database
      let fileURL = try saveScreenshotData(
        jpegData,
        capturedAt: captureTime,
        idleSecondsAtCapture: idleSecondsAtCapture
      )

      dbg("📸 Screenshot saved: \(fileURL.lastPathComponent) (\(jpegData.count / 1024)KB)")

    } catch {
      dbg("❌ Screenshot capture failed: \(error.localizedDescription)")

      if !ScreenRecordingPermissionNotice.isGranted {
        handleMissingScreenRecordingPermission(reason: "captureScreenshot_failed_permission")
        return
      }

      // If the selected source became unavailable, try to refresh it.
      if (error as NSError).domain == SCStreamErrorDomain {
        dbg("SCStream error - will refresh capture source on next capture")
        Task { await refreshCaptureSource() }
      }
    }
  }

  private func privacySignals(
    for source: ResolvedCaptureSource,
    fallback: RecordingPrivacySignals
  ) -> RecordingPrivacySignals {
    switch source {
    case .display:
      return fallback

    case .application(_, let application):
      let windows = cachedContent?.windows
        .filter {
          $0.owningApplication?.bundleIdentifier.caseInsensitiveCompare(
            application.bundleIdentifier
          ) == .orderedSame
        }
        .sorted { $0.isActive && !$1.isActive } ?? []
      let protectedTitle = windows
        .compactMap(\.title)
        .first { title in
          RecordingPrivacyPreferences.inferredPrivateContext(
            applicationID: application.bundleIdentifier,
            applicationName: application.applicationName,
            windowTitle: title
          )
            || RecordingPrivacyPreferences.inferredDRMContent(
              applicationID: application.bundleIdentifier,
              applicationName: application.applicationName,
              windowTitle: title
            )
        }
      let title = protectedTitle ?? windows.first?.title
      return RecordingPrivacyPreferences.captureSignals(
        applicationID: application.bundleIdentifier,
        applicationName: application.applicationName,
        windowTitle: title
      )

    case .window(let window):
      return RecordingPrivacyPreferences.captureSignals(
        applicationID: window.owningApplication?.bundleIdentifier,
        applicationName: window.owningApplication?.applicationName,
        windowTitle: window.title
      )
    }
  }

  private func scaledCaptureSize(for display: SCDisplay) -> (width: Int, height: Int) {
    let aspectRatio = Double(display.width) / Double(display.height)
    var targetWidth = Int(Double(Config.targetHeight) * aspectRatio)
    if targetWidth % 2 != 0 { targetWidth += 1 }
    var targetHeight = Int(Config.targetHeight)
    if targetHeight % 2 != 0 { targetHeight += 1 }
    return (targetWidth, targetHeight)
  }

  private func scaledCaptureSize(
    for source: ResolvedCaptureSource,
    filter: SCContentFilter
  ) -> (width: Int, height: Int) {
    if let display = source.display {
      return scaledCaptureSize(for: display)
    }

    let rect = filter.contentRect
    let scale = CGFloat(filter.pointPixelScale)
    let width = abs(rect.width) * scale
    let height = abs(rect.height) * scale
    guard width.isFinite, height.isFinite, width > 1, height > 1 else {
      let fallback = Int(Config.targetHeight)
      return (fallback, fallback)
    }

    let aspectRatio = width / height
    var targetWidth = Int(Double(Config.targetHeight) * aspectRatio)
    if targetWidth % 2 != 0 { targetWidth += 1 }
    var targetHeight = Int(Config.targetHeight)
    if targetHeight % 2 != 0 { targetHeight += 1 }
    return (max(2, targetWidth), max(2, targetHeight))
  }

  private func saveScreenshotData(
    _ jpegData: Data,
    capturedAt: Date,
    idleSecondsAtCapture: Int?
  ) throws -> URL {
    let fileURL = StorageManager.shared.nextScreenshotURL()
    try jpegData.write(to: fileURL)

    _ = StorageManager.shared.saveScreenshot(
      url: fileURL,
      capturedAt: capturedAt,
      idleSecondsAtCapture: idleSecondsAtCapture
    )
    return fileURL
  }

  private func refreshCaptureSource() async {
    guard ScreenRecordingPermissionNotice.isGranted else {
      handleMissingScreenRecordingPermission(reason: "refreshCaptureSource")
      return
    }

    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      cachedContent = content

      requestedCaptureSource = RecordingCapturePreferences.selectedSource()
      let trackerID: CGDirectDisplayID? = await MainActor.run { [weak tracker] in
        tracker?.activeDisplayID
      }
      let resolvedSource = try resolveCaptureSource(
        requestedCaptureSource,
        in: content,
        trackerID: trackerID
      )
      cachedCaptureSource = resolvedSource
      currentDisplayID = resolvedSource.displayID
      dbg("Refreshed capture source: \(requestedCaptureSource.displayName)")
    } catch ScreenRecorderError.captureSourceUnavailable {
      cachedCaptureSource = nil
      currentDisplayID = nil
      dbg("Selected capture source is unavailable: \(requestedCaptureSource.displayName)")
    } catch {
      if !ScreenRecordingPermissionNotice.isGranted {
        handleMissingScreenRecordingPermission(reason: "refreshCaptureSource_failed_permission")
        return
      }

      dbg("Failed to refresh capture source: \(error)")
    }
  }

  private func handleMissingScreenRecordingPermission(reason: String) {
    q.async { [weak self] in
      guard let self else { return }
      self.stopCaptureTimer()
      self.cachedContent = nil
      self.cachedCaptureSource = nil
      self.currentDisplayID = nil
      if self.state != .idle {
        self.transition(to: .idle, context: "missing screen recording permission")
      }
      self.wantsRecording = false
    }

    Task { @MainActor in
      if AppState.shared.isRecording {
        AppState.shared.setRecording(
          false,
          analyticsReason: "permission_missing",
          persistPreference: false
        )
      }
      ScreenRecordingPermissionNotice.post(reason: reason)
    }
  }

  // MARK: - Image Conversion

  private func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, "public.jpeg" as CFString, 1, nil)
    else {
      return nil
    }
    CGImageDestinationAddImage(
      destination, cgImage,
      [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  // MARK: - Display Change Handling

  private func handleActiveDisplayChange(_ newID: CGDirectDisplayID) {
    guard RecordingCapturePreferences.selectedSource().kind == .activeDisplay else {
      dbg("Active display changed – selected source is not active display")
      return
    }

    guard wantsRecording else {
      dbg("Active display changed – recording disabled, deferring switch")
      return
    }

    guard state == .capturing else {
      dbg("Active display changed while not capturing – will switch on next start")
      return
    }
    guard newID != currentDisplayID else { return }

    dbg("Active display changed → switching: \(String(describing: currentDisplayID)) → \(newID)")

    // Refresh the active-display source for the next screenshot.
    Task { await refreshCaptureSource() }
  }

  private func handleCaptureSourceChange() {
    requestedCaptureSource = RecordingCapturePreferences.selectedSource()
    cachedCaptureSource = nil
    currentDisplayID = nil

    guard wantsRecording, state == .capturing else { return }
    dbg("Capture source changed – resolving \(requestedCaptureSource.displayName)")
    Task { await refreshCaptureSource() }
  }

  // MARK: - System Events (Sleep/Lock)

  private func registerForSleepAndLock() {
    let nc = NSWorkspace.shared.notificationCenter
    let dnc = DistributedNotificationCenter.default()

    // Screen configuration changed — recover a selected display, app, or window.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: nil
    ) { [weak self] _ in
      self?.q.async { [weak self] in
        guard let self, self.state == .capturing else { return }
        dbg("didChangeScreenParameters – refreshing capture source")
        Task { await self.refreshCaptureSource() }
      }
    }

    // System will sleep
    nc.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("willSleep – pausing")

      self.q.async { [weak self] in
        guard let self else { return }
        self.sleeping = true
        Task { @MainActor in
          if AppState.shared.isRecording {
            self.q.async { [weak self] in
              self?.transition(to: .paused, context: "system sleep")
            }
          }
        }
      }
      self.stop()
      Task { @MainActor in
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture("recording_stopped", ["stop_reason": "system_sleep"])
        }
      }
    }

    // System did wake
    nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("didWake – checking flag")

      self.q.async { [weak self] in
        guard let self else { return }
        self.sleeping = false
        guard self.state == .paused else { return }
        self.resumeRecording(after: 5, context: "didWake")
      }
    }

    // Screen locked
    dnc.addObserver(
      forName: .init("com.apple.screenIsLocked"),
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("screen locked – pausing")

      self.q.async { [weak self] in
        guard let self else { return }
        self.deviceLocked = true
        Task { @MainActor in
          if AppState.shared.isRecording {
            self.q.async { [weak self] in
              self?.transition(to: .paused, context: "screen locked")
            }
          }
        }
      }
      self.stop()
      Task { @MainActor in
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture("recording_stopped", ["stop_reason": "lock"])
        }
      }
    }

    // Screen unlocked
    dnc.addObserver(
      forName: .init("com.apple.screenIsUnlocked"),
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("screen unlocked – checking flag")

      self.q.async { [weak self] in
        guard let self else { return }
        self.deviceLocked = false
        guard self.state == .paused else { return }
        self.resumeRecording(after: 0.5, context: "screen unlock")
      }
    }

    // Screensaver started
    dnc.addObserver(
      forName: .init("com.apple.screensaver.didstart"),
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("screensaver started – pausing")

      self.q.async { [weak self] in
        guard let self else { return }
        self.deviceLocked = true
        Task { @MainActor in
          if AppState.shared.isRecording {
            self.q.async { [weak self] in
              self?.transition(to: .paused, context: "screensaver started")
            }
          }
        }
      }
      self.stop()
      Task { @MainActor in
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture("recording_stopped", ["stop_reason": "screensaver"])
        }
      }
    }

    // Screensaver stopped
    dnc.addObserver(
      forName: .init("com.apple.screensaver.didstop"),
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("screensaver stopped – checking flag")

      self.q.async { [weak self] in
        guard let self else { return }
        self.deviceLocked = false
        guard self.state == .paused else { return }
        self.resumeRecording(after: 0.5, context: "screensaver stop")
      }
    }
  }

  private func resumeRecording(after delay: TimeInterval, context: String) {
    q.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        guard AppState.shared.isRecording else {
          dbg("\(context) – skip auto-resume (recording disabled)")
          return
        }
        self.start()
      }
    }
  }
}
