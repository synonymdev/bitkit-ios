import BitkitCore
import SwiftUI

/// Runs the steps of a wallet wipe against the live app state tree. `WipeCoordinator` owns the intent, the order and the
/// retries.
@MainActor
final class AppReset: WipeStepExecutor {
    /// The live app state tree, registered by `AppScene`, which owns it. A wipe starts from screens and from launch, which
    /// have no other way to reach it. Weak, so it never keeps a replaced app state tree alive.
    private weak static var liveApp: AppViewModel?
    private weak static var liveWallet: WalletViewModel?
    private weak static var liveSession: SessionManager?
    private weak static var hardwareWallets: HwWalletManager?

    private let app: AppViewModel
    private let wallet: WalletViewModel
    private let session: SessionManager
    private var usdtCleanupError: Error?

    private init(app: AppViewModel, wallet: WalletViewModel, session: SessionManager) {
        self.app = app
        self.wallet = wallet
        self.session = session
    }

    static func register(app: AppViewModel, wallet: WalletViewModel, session: SessionManager, hardwareWallets: HwWalletManager) {
        liveApp = app
        liveWallet = wallet
        liveSession = session
        self.hardwareWallets = hardwareWallets
    }

    static func attached() -> WipeStepExecutor? {
        guard let liveApp, let liveWallet, let liveSession else { return nil }
        return AppReset(app: liveApp, wallet: liveWallet, session: liveSession)
    }

    /// Starts a wipe the user asked for, or tells them nothing was deleted when it could not start.
    static func begin(_ reason: WipeReason, app: AppViewModel) {
        do {
            try WipeCoordinator.shared.begin(reason)
        } catch {
            Logger.error("Failed to start wallet wipe: \(error)", context: "AppReset")
            app.toast(type: .error, title: t("common__error"), description: t("security__wipe_not_started"))
        }
    }

    func withWipeScope(_ steps: () async throws -> Void) async throws {
        // Before waiting for Paykit work to drain, so nothing uploads or starts the node meanwhile.
        BackupService.shared.setWiping(true)
        wallet.closeStartAdmissionForWipe()
        try await PaykitSdkService.shared.withWalletWipe {
            // A server switch restarts the node, so one under way finishes first, and no new one starts until the wipe ends.
            await SettingsViewModel.shared.beginServerSettingsWipe()
            defer { SettingsViewModel.shared.endServerSettingsWipe() }
            try await steps()
        }
    }

    func run(_ step: WipeStep) async throws {
        switch step {
        case .quiesce:
            await BackupService.shared.stopObservingBackups()
            await app.cancelMigrationSyncForWipe()
        case .stopNode:
            try await wallet.stopForWipe()
        case .removeRemoteEndpoints:
            await Self.runRemoteCleanup {
                await PubkyProfileManager.removePublicPaykitEndpointsForWipe(context: "AppReset.wipe")
            }
            await Self.runRemoteCleanup {
                await PubkyProfileManager.removePrivatePaykitEndpointsForWipe(context: "AppReset.wipe")
            }
        case .resetLocalServices:
            await VssBackupClient.shared.reset()
            VssStoreIdProvider.shared.clearCache()
            OnChainHwService.shared.stopAllWatchers()
            // Before the paired devices are wiped, so a reconnect still running cannot save one back.
            await Self.hardwareWallets?.resetForWipe()
            do {
                try await wallet.usdtWallet.wipe()
                usdtCleanupError = nil
            } catch {
                usdtCleanupError = error
            }
        case .wipeLightningStorage:
            try await wallet.wipe()
        case .wipeDatabases:
            // bitkit-core wipes only databases it has opened, which `CoreService` does when it is created.
            _ = CoreService.shared
            let coreWipeResult = try await wipeAllDatabases()
            Logger.info("Core DB wipe: \(coreWipeResult)")
        case .clearPubkyState:
            // Clear any live Pubky runtime state and cached profile images.
            await PubkyProfileManager.clearLocalState()
            await PrivatePaykitAddressReservationStore.shared.clear()
        case .wipeKeychain:
            try Self.wipeKeychain()
            PaykitUsdtPaymentService.shared.resetForWipe()
        case .resetSettings:
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
            try await WatchOnlyAccountManager.shared.clear()
            // Singleton retains stale @AppStorage values after removePersistentDomain
            SettingsViewModel.shared.resetToDefaults()
            // Prevent RN migration from triggering after wipe
            MigrationsService.shared.markMigrationChecked()
            if Env.network == .regtest {
                try Self.wipeLogs()
            }
        case .deletePin:
            try Keychain.delete(key: .securityPin)
            try Keychain.delete(key: .pinFailedAttempts)
        case .deleteInstallationMarker:
            // So the next install can detect an orphaned keychain
            try? InstallationMarker.delete()
        case .commit:
            try Keychain.delete(key: .wipePending)
        }
    }

    func finish(reason: WipeReason?) {
        BackupService.shared.setWiping(false)

        // Recreate the entire app state tree to guarantee clean defaults for all @StateObject VMs.
        // Avoid showing splash during when app is reset
        session.skipSplashOnce = true
        session.bump()

        if let usdtCleanupError {
            app.toast(type: .warning, title: t("security__wiped_title"), description: usdtCleanupError.localizedDescription)
        } else {
            app.toast(
                type: reason == .pinAttemptsExceeded ? .warning : .success,
                title: t("security__wiped_title"),
                description: t("security__wiped_message")
            )
        }
    }

    /// A hung remote cleanup must not hold the wipe; what it leaves behind is recoverable from the seed.
    static func runRemoteCleanup(timeout: Duration = .seconds(15), _ cleanup: @escaping () async -> Void) async {
        guard await withDeadline(timeout, cleanup) == nil else { return }
        Logger.warn("Remote cleanup timed out, continuing the wipe", context: "AppReset")
    }

    /// The PIN, its counter and the intent outlive the wallet data, so a relaunch until the wipe ends is gated. The Trezor
    /// pairing credentials follow the seeds, as they are saved outside the access group the keychain wipe clears, so a failure
    /// to clear them keeps the wipe pending without keeping a seed.
    static func wipeKeychain() throws {
        try Keychain.wipeEntireKeychain(retaining: [.securityPin, .pinFailedAttempts, .wipePending])
        try TrezorCredentialStorage.deleteAll()
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
