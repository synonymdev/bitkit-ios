import SwiftUI

enum AppReset {
    @MainActor
    static func wipe(
        app: AppViewModel,
        wallet: WalletViewModel,
        session: SessionManager,
        toastType: Toast.ToastType = .success
    ) async throws {
        // 1) Stop node and wipe LDK/core persistence via the wallet API.
        try await wallet.wipe()

        // 2) Wipe persistence
        try Keychain.wipeEntireKeychain()

        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // 3) Recreate the entire app state tree to guarantee clean defaults for all @StateObject VMs.
        // Avoid showing splash during when app is reset
        session.skipSplashOnce = true
        session.bump()

        // 4) Show toast
        app.toast(
            type: toastType,
            title: localizedString("security__wiped_title"),
            description: localizedString("security__wiped_message")
        )
    }
}
