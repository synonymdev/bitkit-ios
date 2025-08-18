import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
    {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Unlock so LDK can run in the background
        try? StateLocker.unlock(.lightning)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        Logger.debug(userInfo, context: "push notification received while app is in the foreground")

        // If we want to display the native notification to the user while the app is open we need to call this with options
        // Unlikely we will need to as the background operation would have been aborted and we would have nothint to show
        completionHandler([])
        //        completionHandler([[.banner, .badge, .sound]])
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Convert token to hex string and register immediately with server
        let tokenString = deviceToken.map { String(format: "%02hhx", $0) }.joined()

        // Register with server immediately when we get a new token
        Task {
            do {
                try await NotificationService.shared.registerDeviceForNotifications(deviceToken: tokenString)
            } catch {
                Logger.error("Failed to register device token with server: \(error)")
                // Notify via callback that registration failed
                await MainActor.run {
                    NotificationService.shared.onRegistrationStatusChanged?(false)
                    NotificationService.shared.onRegistrationFailed?(error)
                }
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger.error(error)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        Logger.debug(userInfo, context: "app opened from push notification")
        // TODO: if user tapped on an incoming tx we should open it on that tx view
        completionHandler()
    }
}

@main
struct BitkitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Set dark mode as default
        UIWindow.appearance().overrideUserInterfaceStyle = .dark

        // Initialize toast window manager early
        _ = ToastWindowManager.shared
    }

    var body: some Scene {
        WindowGroup {
            if Env.isUnitTest {
                Text("Running tests...")
            } else {
                ContentView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}
