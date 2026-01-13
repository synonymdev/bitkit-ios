import BitkitCore
import SwiftUI

enum AppReset {
    @MainActor
    static func wipe(
        app: AppViewModel,
        wallet: WalletViewModel,
        session: SessionManager,
        toastType: Toast.ToastType = .success
    ) async throws {
        // Set wiping flag to prevent backups during wipe operations
        BackupService.shared.setWiping(true)
        defer {
            BackupService.shared.setWiping(false)
        }

        // Stop backup observers and reset VSS client
        await BackupService.shared.stopObservingBackups()
        VssBackupClient.shared.reset()

        // Stop node and wipe LDK persistence via the wallet API.
        try await wallet.wipe()

        // Wipe bitkit-core DB
        let coreWipeResult = try await wipeAllDatabases()
        Logger.info("Core DB wipe: \(coreWipeResult)")

        // Wipe keychain
        try Keychain.wipeEntireKeychain()

        // Delete installation marker so next install can detect orphaned keychain
        try? InstallationMarker.delete()

        // Wipe user defaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // Prevent RN migration from triggering after wipe
        MigrationsService.shared.markMigrationChecked()

        // Wipe logs
        if Env.network == .regtest {
            try wipeLogs()
        }

        // Recreate the entire app state tree to guarantee clean defaults for all @StateObject VMs.
        // Avoid showing splash during when app is reset
        session.skipSplashOnce = true
        session.bump()

        // Show toast
        app.toast(
            type: toastType,
            title: t("security__wiped_title"),
            description: t("security__wiped_message")
        )
    }

    private static func wipeLogs() throws {
        let path = Env.logDirectory
        if FileManager.default.fileExists(atPath: path) {
            Logger.warn("Wiping entire logs directory...")
            try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        } else {
            Logger.warn("No logs directory found to wipe: \(path)")
        }
    }
}
