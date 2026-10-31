import BitkitCore
import SwiftUI

enum AppReset {
    /// The live hardware wallet layer, registered by `AppScene`, which owns it. The wipe starts from
    /// screens that have no other use for it, so it is not passed in. Weak, so it never keeps a replaced
    /// app state tree alive.
    @MainActor weak static var hardwareWallets: HwWalletManager?

    @MainActor
    static func wipe(
        app: AppViewModel,
        wallet: WalletViewModel,
        session: SessionManager,
        toastType: Toast.ToastType = .success,
        expectedPendingID: UUID? = nil
    ) async throws {
        try await withWipeAdmission(expectedPendingID: expectedPendingID) { permitsRemoteCleanup in
            BackupService.shared.setWiping(true)
            defer { BackupService.shared.setWiping(false) }
            try await app.withMigrationSyncPausedForWipe {
                await SettingsViewModel.shared.beginServerSettingsWipe()
                defer { SettingsViewModel.shared.endServerSettingsWipe() }
                try await wipeLocal(app: app, wallet: wallet, permitsRemoteCleanup: permitsRemoteCleanup)
            }
        }
        // Required cleanup and the exact marker are acknowledged before any success or replacement tree.
        session.skipSplashOnce = true
        session.bump()
        app.toast(type: toastType, title: t("security__wiped_title"), description: t("security__wiped_message"))
    }

    @MainActor
    static func withWipeAdmission(
        admission: ProfileOperationAdmission = .shared,
        sdkService: PaykitSdkService = .shared,
        expectedPendingID: UUID? = nil,
        pause: ((UUID) async -> Void)? = nil,
        resume: ((UUID) async -> Void)? = nil,
        cleanup: (Bool) async throws -> Void
    ) async throws {
        let id = UUID()
        let scope = try admission.reserve(kind: .walletWipe, id: id, requiredPendingID: expectedPendingID)
        defer { admission.release(scope) }
        if let pause {
            await pause(id)
        } else {
            await PrivatePaykitService.shared.beginProfileDeletion(id: id)
        }
        @MainActor func resumeWork() async {
            if let resume {
                await resume(id)
            } else {
                await PrivatePaykitService.shared.endProfileDeletion(id: id)
            }
        }
        var completed = false
        do {
            try await admission.withScope(scope, access: .control) {
                try await admission.drain(before: scope)
                try admission.persist(scope)
                let permitsRemoteCleanup = try admission.permitsRemoteCleanup(scope)
                try await sdkService.withWalletWipe {
                    try await cleanup(permitsRemoteCleanup)
                }
                try admission.complete(scope)
                completed = true
            }
        } catch {
            await resumeWork()
            // Cancellation immediately after acknowledged completion cannot turn it into pending work.
            if completed {
                return
            }
            throw error
        }
        await resumeWork()
    }

    @MainActor
    private static func wipeLocal(
        app: AppViewModel,
        wallet: WalletViewModel,
        permitsRemoteCleanup: Bool
    ) async throws {
        if permitsRemoteCleanup {
            await PubkyProfileManager.removePublicPaykitEndpointsBestEffort(context: "AppReset.wipe")
            await PubkyProfileManager.removePrivatePaykitEndpointsBestEffort(context: "AppReset.wipe")
        }
        guard let scope = ProfileOperationAdmission.current else { throw ProfileRemovalStore.StoreError.changed }
        try ProfileOperationAdmission.shared.requireLocalOnly(scope)

        // Stop backup observers and reset VSS client
        await BackupService.shared.stopObservingBackups()
        await VssBackupClient.shared.reset()
        VssStoreIdProvider.shared.clearCache()

        OnChainHwService.shared.stopAllWatchers()
        // Before the paired devices are wiped, so a reconnect still running cannot save one back.
        await hardwareWallets?.resetForWipe()

        try await wallet.usdtWallet.wipe()

        // Credentials must be durably absent before any consumed-payment watermark is cleared.
        try Keychain.wipeEntireKeychain()
        try SharedPubkyKeychain.removeAllOwnOrThrow()

        // Stop node and wipe LDK persistence via the wallet API.
        try await wallet.wipe()

        // Wipe bitkit-core DB
        let coreWipeResult = try await wipeAllDatabases()
        Logger.info("Core DB wipe: \(coreWipeResult)")

        // Clear any live Pubky runtime state and cached profile images.
        await PrivatePaykitAddressReservationStore.shared.clear()
        try await PubkyProfileManager.clearLocalState()
        PaykitUsdtPaymentService.shared.resetForWipe()

        // Delete installation marker so next install can detect orphaned keychain
        try InstallationMarker.delete()

        // Wipe user defaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        try await WatchOnlyAccountManager.shared.clear()

        // Singleton retains stale @AppStorage values after removePersistentDomain
        SettingsViewModel.shared.resetToDefaults()

        // Prevent RN migration from triggering after wipe
        MigrationsService.shared.markMigrationChecked()

        // Wipe logs
        if Env.network == .regtest {
            try wipeLogs()
        }

        guard let domain = Bundle.main.bundleIdentifier,
              let expected = UserDefaults.standard.persistentDomain(forName: domain),
              UserDefaults.standard.synchronize(),
              let persisted = UserDefaults.standard.persistentDomain(forName: domain),
              NSDictionary(dictionary: expected).isEqual(to: persisted)
        else { throw ProfileRemovalStore.StoreError.unavailable }
        try await PrivatePaykitService.shared.validateWipedState()
        try await PrivatePaykitAddressReservationStore.shared.validateWipedState()
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
