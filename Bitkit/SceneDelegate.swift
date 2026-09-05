import SwiftUI
import UIKit

final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    private var pendingURL: URL?

    func retain(_ url: URL) {
        pendingURL = url
    }

    func consume() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }
}

// MARK: - Scene Delegate for Quick Actions

/// Handles scene lifecycle and quick actions for SwiftUI apps
class SceneDelegate: NSObject, UIWindowSceneDelegate {
    // MARK: - Quick Action State

    var savedShortCutItem: UIApplicationShortcutItem?
    var savedDeepLinkURL: URL?

    // MARK: - Scene Connection

    /// Save quick action when scene is created
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcutItem = connectionOptions.shortcutItem {
            savedShortCutItem = shortcutItem
        }
        savedDeepLinkURL = connectionOptions.urlContexts.first?.url
    }

    // MARK: - Scene Activation

    /// Handle saved quick action when scene becomes active
    func sceneDidBecomeActive(_ scene: UIScene) {
        if let shortcutItem = savedShortCutItem {
            handleQuickAction(shortcutItem)
            savedShortCutItem = nil
        }
        if let url = savedDeepLinkURL {
            forwardDeepLink(url)
            savedDeepLinkURL = nil
        }
    }

    // MARK: - Quick Action Handling (App Running)

    /// Handle quick action when app is already running
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        handleQuickAction(shortcutItem)
        completionHandler(true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            forwardDeepLink(context.url)
        }
    }

    // MARK: - Quick Action Processing

    /// Process quick action and notify SwiftUI views
    private func handleQuickAction(_ shortcutItem: UIApplicationShortcutItem) {
        let userInfo = ["shortcutType": shortcutItem.type]
        NotificationCenter.default.post(name: .quickActionSelected, object: nil, userInfo: userInfo)
    }

    func forwardDeepLink(_ url: URL) {
        DeepLinkRouter.shared.retain(url)
        NotificationCenter.default.post(name: .deepLinkReceived, object: url)
    }
}
