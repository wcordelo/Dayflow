import Combine
import Foundation

#if os(iOS)
import ReplayKit
#endif

public enum ActivityCaptureState: Equatable, Sendable {
    case idle
    case unavailable(String)
    case requestingPermission
    case running
    case privacyPaused(String)
    case stopped(String)
}

public enum DayflowNativeStatusKey {
    public static let capturePermission = "capture_permission"
    public static let captureSession = "capture_session"
    public static let capturePaused = "capture_paused"
    public static let derivedSync = "derived_sync"
}

public struct ActivityCaptureStatusFields: Equatable, Sendable {
    public let capturePermission: String
    public let captureSession: String
    public let capturePaused: String
    public let derivedSync: String

    public func asDictionary() -> [String: String] {
        [
            DayflowNativeStatusKey.capturePermission: capturePermission,
            DayflowNativeStatusKey.captureSession: captureSession,
            DayflowNativeStatusKey.capturePaused: capturePaused,
            DayflowNativeStatusKey.derivedSync: derivedSync,
        ]
    }
}

@MainActor
public final class ActivityCaptureSession: ObservableObject {
    public static let sharedCapturePauseSetting = "dayflow.capture.paused"

    nonisolated public static func sharedCapturePauseEnabled(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "false":
            return false
        case "true":
            return true
        default:
            return true
        }
    }

    @Published public private(set) var state: ActivityCaptureState = .idle
    @Published public private(set) var samplesObserved = 0
    /// Receives low-frequency metadata after a frame passes the shared Rust
    /// privacy decision. Raw ReplayKit buffers never leave this object.
    public var onDerivedSample: (@MainActor @Sendable (Int64) -> Void)?
    private var privacyContext = PrivacyContext()
    private var lastDerivedSampleAt: Date?
    private var sessionGeneration = 0
    // ReplayKit invokes its sample handler off the main actor. The gate owns
    // its lock and is intentionally the only nonisolated state touched there.
    private let frameGate = CaptureFrameGate()

    #if os(iOS)
    private let recorder = RPScreenRecorder.shared()
    #endif

    public init() {}

    /// Provides the same four user-visible status fields as the desktop
    /// clients. The values are local diagnostics, not sync payloads.
    public func statusFields(
        sharedCapturePaused: Bool,
        derivedSync: String
    ) -> ActivityCaptureStatusFields {
        let permission: String
        switch state {
        case .requestingPermission:
            permission = "awaiting_consent"
        case .running:
            permission = "granted"
        case .unavailable:
            permission = "unavailable"
        case .privacyPaused, .idle, .stopped:
            permission = "not_active"
        }

        let session: String
        switch state {
        case .idle: session = "idle"
        case .unavailable: session = "unavailable"
        case .requestingPermission: session = "requesting_permission"
        case .running: session = "running"
        case .privacyPaused: session = "privacy_paused"
        case .stopped: session = "stopped"
        }

        return ActivityCaptureStatusFields(
            capturePermission: permission,
            captureSession: session,
            capturePaused: sharedCapturePaused || state.isPrivacyPaused ? "paused" : "not_paused",
            derivedSync: derivedSync.isEmpty ? "unknown" : derivedSync
        )
    }

    public func start() {
        // ReplayKit supports one explicit session per recorder. Guard the
        // requesting/running states so repeated taps cannot create competing
        // permission prompts or overlapping sample handlers.
        guard state != .requestingPermission, state != .running else { return }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        frameGate.reset()
        lastDerivedSampleAt = nil
        #if os(iOS)
        guard privacyContext.allowsCapture else {
            state = .privacyPaused("Dayflow privacy rules paused capture.")
            return
        }
        guard recorder.isAvailable else {
            state = .unavailable("ReplayKit is not available on this device or in the current app state.")
            return
        }

        state = .requestingPermission
        // ReplayKit invokes this callback outside the main actor. Capture the
        // explicitly sendable gate before registering it; the session itself
        // is only touched after the callback hops back to MainActor.
        let frameGate = self.frameGate
        recorder.startCapture(
            handler: { [weak self, frameGate, generation] _, sampleType, error in
                guard sampleType == .video else { return }
                // ReplayKit can deliver video callbacks at display rate. Only
                // schedule a bounded privacy decision/UI update; derived events
                // are independently limited to one per minute below.
                let now = Date().timeIntervalSince1970
                guard frameGate.shouldHandle(now: now) else { return }
                Task { @MainActor [weak self, generation] in
                    guard let self, self.sessionGeneration == generation else { return }
                    if let error {
                        self.state = .stopped("ReplayKit stopped: \(error.localizedDescription)")
                        return
                    }
                    guard self.privacyContext.allowsCapture else {
                        self.state = .privacyPaused("Dayflow privacy rules paused capture.")
                        self.recorder.stopCapture { _ in }
                        return
                    }
                    self.samplesObserved += 1
                    self.state = .running
                    let now = Date()
                    if self.lastDerivedSampleAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                        self.lastDerivedSampleAt = now
                        self.onDerivedSample?(Int64(now.timeIntervalSince1970))
                    }
                }
            },
            completionHandler: { [weak self, generation] error in
                Task { @MainActor [weak self, generation] in
                    guard let self, self.sessionGeneration == generation else { return }
                    if let error {
                        self.state = .stopped("ReplayKit could not start: \(error.localizedDescription)")
                    } else if self.privacyContext.allowsCapture {
                        // Mark the session active as soon as ReplayKit accepts
                        // it. Waiting for the first frame made a valid session
                        // look stuck while the system was still warming up.
                        self.state = .running
                    } else {
                        self.state = .privacyPaused("Dayflow privacy rules paused capture.")
                    }
                }
            }
        )
        #else
        state = .unavailable("ReplayKit is only available on an iOS target.")
        #endif
    }

    public func stop() {
        guard state == .requestingPermission || state == .running else { return }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        lastDerivedSampleAt = nil
        #if os(iOS)
        recorder.stopCapture { [weak self, generation] error in
            Task { @MainActor [weak self, generation] in
                guard let self, self.sessionGeneration == generation else { return }
                self.state = .stopped(error.map { "Capture stopped: \($0.localizedDescription)" } ?? "Capture stopped.")
            }
        }
        frameGate.reset()
        #else
        state = .stopped("Capture stopped.")
        #endif
    }

    public func updatePrivacyContext(
        userPaused: Bool,
        deviceLocked: Bool,
        sleeping: Bool,
        privateContext: Bool,
        drmContent: Bool,
        applicationID: String? = nil,
        windowTitle: String? = nil,
        blockedApplicationIDs: Set<String> = [],
        blockedWindowTitleFragments: [String] = []
    ) {
        privacyContext = PrivacyContext(
            userPaused: userPaused,
            deviceLocked: deviceLocked,
            sleeping: sleeping,
            privateContext: privateContext,
            drmContent: drmContent,
            applicationID: applicationID,
            windowTitle: windowTitle,
            blockedApplicationIDs: blockedApplicationIDs,
            blockedWindowTitleFragments: blockedWindowTitleFragments
        )
        guard privacyContext.allowsCapture == false else { return }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        frameGate.reset()
        #if os(iOS)
        recorder.stopCapture { [weak self, generation] _ in
            Task { @MainActor [weak self, generation] in
                guard let self, self.sessionGeneration == generation else { return }
                self.state = .privacyPaused("Dayflow privacy rules paused capture.")
            }
        }
        #else
        state = .privacyPaused("Dayflow privacy rules paused capture.")
        #endif
    }

    /// Applies the decrypted cross-device capture pause setting. Clearing it
    /// only permits a future explicit start; it never restarts ReplayKit.
    public func updateSharedCapturePause(_ value: String?) {
        let paused = Self.sharedCapturePauseEnabled(value)
        guard privacyContext.userPaused != paused else { return }
        updatePrivacyContext(
            userPaused: paused,
            deviceLocked: privacyContext.deviceLocked,
            sleeping: privacyContext.sleeping,
            privateContext: privacyContext.privateContext,
            drmContent: privacyContext.drmContent,
            applicationID: privacyContext.applicationID,
            windowTitle: privacyContext.windowTitle,
            blockedApplicationIDs: privacyContext.blockedApplicationIDs,
            blockedWindowTitleFragments: privacyContext.blockedWindowTitleFragments
        )
    }
}

private extension ActivityCaptureState {
    var isPrivacyPaused: Bool {
        if case .privacyPaused = self { return true }
        return false
    }
}

private final class CaptureFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastHandledAt: TimeInterval = 0

    func shouldHandle(now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastHandledAt >= 0.25 else { return false }
        lastHandledAt = now
        return true
    }

    func reset() {
        lock.lock()
        lastHandledAt = 0
        lock.unlock()
    }
}

private struct PrivacyContext {
    var userPaused = false
    var deviceLocked = false
    var sleeping = false
    var privateContext = false
    var drmContent = false
    var applicationID: String? = nil
    var windowTitle: String? = nil
    var blockedApplicationIDs: Set<String> = []
    var blockedWindowTitleFragments: [String] = []

    var allowsCapture: Bool {
        guard let contextJSON = json(
            [
                "permission_granted": true,
                "user_paused": userPaused,
                "device_locked": deviceLocked,
                "sleeping": sleeping,
                "private_context": privateContext,
                "drm_content": drmContent,
                "application_id": applicationID ?? NSNull(),
                "window_title": windowTitle ?? NSNull(),
            ]
        ), let policyJSON = json(
            [
                "ignore_private_context": true,
                "pause_on_drm": true,
                "blocked_application_ids": Array(blockedApplicationIDs).sorted(),
                "blocked_window_title_fragments": blockedWindowTitleFragments,
            ]
        ) else {
            return false
        }
        return (try? UniFFIDayflowCoreBridge().captureDecision(
            contextJSON: contextJSON,
            policyJSON: policyJSON
        ).allowed) == true
    }

    private func json(_ value: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
