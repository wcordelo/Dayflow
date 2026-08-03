#if os(iOS)
import UIKit
import UserNotifications

/// Bridges APNs' device lifecycle to the local-first app model. The relay
/// receives only the opaque platform token; a silent wake carries only
/// `kind = sync_available`, so encrypted event content is still pulled and
/// decrypted locally.
@MainActor
final class DayflowMobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var appModel: DayflowMobileAppModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func requestRemoteNotificationRegistration() {
        // Dayflow uses silent/content-free wakes, not user-visible alert
        // notifications. Do not ask for alert/badge/sound permission merely
        // to obtain an APNs token.
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        appModel?.setPushToken(token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // APNs registration is optional. The app remains useful offline and
        // foreground sync continues through the durable relay hint cursor.
        print("[DayflowMobile] APNs registration unavailable: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard DayflowMobilePushWakeContract.accepts(userInfo) else {
            completionHandler(.noData)
            return
        }

        Task { @MainActor [weak self] in
            await self?.appModel?.syncForPushWake()
            completionHandler(.newData)
        }
    }
}
#endif
