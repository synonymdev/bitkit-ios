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
        try await PubkyProfileManager.withIdentityLifecycleLock {
            try await wipeLocked(
                app: app,
                wallet: wallet,
                session: session,
                toastType: toastType
            )
        }
    }

    @MainActor
    private static func wipeLocked(
        app: AppViewModel,
        wallet: WalletViewModel,
        session: SessionManager,
        toastType: Toast.ToastType
    ) async throws {
        // Shared mirrors must be gone before any server or canonical private source is cleared.
        try SharedPubkyIdentityVault.deleteAllBitkitIdentities()

        await PubkyProfileManager.removePublicPaykitEndpointsBestEffort(context: "AppReset.wipe")
        await PubkyProfileManager.removePrivatePaykitEndpointsBestEffort(context: "AppReset.wipe")

        // Set wiping flag to prevent backups during wipe operations
        BackupService.shared.setWiping(true)
        defer {
            BackupService.shared.setWiping(false)
        }

        // Stop backup observers and reset VSS client
        await BackupService.shared.stopObservingBackups()
        await VssBackupClient.shared.reset()
        VssStoreIdProvider.shared.clearCache()

        OnChainHwService.shared.stopAllWatchers()

        // Stop node and wipe LDK persistence via the wallet API.
        try await wallet.wipe()

        // Wipe bitkit-core DB
        let coreWipeResult = try await wipeAllDatabases()
        Logger.info("Core DB wipe: \(coreWipeResult)")

        // Clear any live Pubky runtime state and cached profile images.
        await PubkyProfileManager.clearLocalState()
        await PrivatePaykitAddressReservationStore.shared.clear()

        // Wipe keychain
        try Keychain.wipeEntireKeychain()

        // Delete installation marker so next install can detect orphaned keychain
        try? InstallationMarker.delete()

        // Wipe user defaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // Singleton retains stale @AppStorage values after removePersistentDomain
        SettingsViewModel.shared.resetToDefaults()

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

        // Re-verify while the identity lifecycle gate still excludes reconciliation.
        try SharedPubkyIdentityVault.deleteAllBitkitIdentities()
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
