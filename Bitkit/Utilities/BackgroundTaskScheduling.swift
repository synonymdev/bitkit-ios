import UIKit

/// The time the system grants the app to finish work after it leaves the foreground.
@MainActor
protocol BackgroundTaskScheduling {
    /// Seconds left before the app is suspended; very large while it is in the foreground.
    var backgroundTimeRemaining: TimeInterval { get }
    /// Starts a background task. `expiration` runs on the main thread when the time is nearly up, and
    /// must end the task quickly.
    func beginBackgroundTask(named name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

@MainActor
struct UIApplicationBackgroundTasks: BackgroundTaskScheduling {
    var backgroundTimeRemaining: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }

    func beginBackgroundTask(named name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name) {
            // UIKit calls the expiration handler on the main thread.
            MainActor.assumeIsolated { expiration() }
        }
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
