import SwiftUI

#if os(iOS)
public struct DayflowMobileApp: App {
    @StateObject private var captureSession = ActivityCaptureSession()
    @StateObject private var appModel = DayflowMobileAppModel()
    @UIApplicationDelegateAdaptor(DayflowMobileAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            DayflowRootView(captureSession: captureSession, appModel: appModel)
                .task {
                    appDelegate.appModel = appModel
                    appDelegate.requestRemoteNotificationRegistration()
                    captureSession.onDerivedSample = { timestamp in
                        appModel.recordCaptureSample(at: timestamp)
                    }
                    appModel.syncIfConfigured()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        appModel.syncIfConfigured()
                    } else if phase == .background {
                        // ReplayKit capture is an explicit foreground user
                        // session on iOS. Stop it before the app loses its
                        // foreground execution budget instead of implying
                        // unattended OS-wide capture is available.
                        captureSession.stop()
                    }
                }
        }
    }
}
#endif
