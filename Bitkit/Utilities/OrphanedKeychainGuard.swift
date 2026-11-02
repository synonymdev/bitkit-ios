import Foundation

/// Wipes keychain entries left behind by an uninstalled copy of the app. The keychain outlives the app, while the
/// installation marker is deleted with it.
struct OrphanedKeychainGuard {
    /// The orphaned keychain still holds a seed, or could not be read, so the launch must not start a wallet until a retry wipes
    /// it.
    struct WipeFailed: Error {
        let underlying: Error
    }

    var hasInstallationMarker: () -> Bool
    var createInstallationMarker: () throws -> Void
    var hasNativeMnemonic: () throws -> Bool
    /// Whether the Lightning storage folder exists, which node setup creates and a reinstall never has.
    var hasWalletStorage: () -> Bool
    var hasOrphanedRNKeychain: () -> Bool
    var hasRNMnemonic: () throws -> Bool
    var wipeKeychain: () throws -> Void
    var removeRNKeychain: () -> Void

    static let live = OrphanedKeychainGuard(
        hasInstallationMarker: { InstallationMarker.exists() },
        createInstallationMarker: { try InstallationMarker.create() },
        hasNativeMnemonic: { try Keychain.exists(key: .bip39Mnemonic(index: 0)) },
        hasWalletStorage: { FileManager.default.fileExists(atPath: Env.ldkStorage(walletIndex: 0).path) },
        hasOrphanedRNKeychain: { MigrationsService.shared.hasOrphanedRNKeychain() },
        hasRNMnemonic: { try MigrationsService.shared.hasRNMnemonic() },
        wipeKeychain: {
            SharedPubkyKeychain.removeAllOwn()
            try Keychain.wipeEntireKeychain()
        },
        removeRNKeychain: { MigrationsService.shared.cleanupRNKeychain() }
    )

    /// Throws `WipeFailed` when a seed of the orphaned keychain could not be wiped, or the keychain could not be read. The
    /// marker stays unwritten then, so the next run checks again.
    func run() throws {
        if hasInstallationMarker() {
            Logger.debug("Installation marker exists, skipping orphaned keychain check", context: "OrphanedKeychainGuard")
            return
        }

        let hasNativeKeychain: Bool
        do {
            hasNativeKeychain = try hasNativeMnemonic()
        } catch {
            // An orphaned seed may be behind the read, and a wallet started on it would look like this install's
            Logger.error("Failed to read the keychain for the orphaned keychain check: \(error)", context: "OrphanedKeychainGuard")
            throw WipeFailed(underlying: error)
        }
        let hasOrphanedRNKeychain = hasOrphanedRNKeychain()
        var isRNKeychainRemoved = false

        if hasNativeKeychain || hasOrphanedRNKeychain {
            Logger.warn("Orphaned keychain detected, wiping", context: "OrphanedKeychainGuard")
            do {
                try wipeKeychain()
            } catch {
                Logger.error("Failed to wipe the orphaned keychain: \(error)", context: "OrphanedKeychainGuard")
                // The wipe reaches only this app's own access group, so an RN seed elsewhere, or a synchronizable one, would
                // outlast every retry. On a fresh install it is as orphaned as when the wipe succeeds.
                if hasOrphanedRNKeychain, !hasWalletStorage() {
                    removeRNKeychain()
                    isRNKeychainRemoved = true
                }
                // A node set up on a seed left behind would make it look like this install's. The wipe deletes the seeds
                // before anything else, so a failure that leaves none needs no hold, which a retry could never lift.
                guard !hasRemainingSeed() else { throw WipeFailed(underlying: error) }
                Logger.warn("No seed remains after the failed wipe, continuing", context: "OrphanedKeychainGuard")
            }
        }

        if hasOrphanedRNKeychain, !isRNKeychainRemoved {
            removeRNKeychain()
        }

        do {
            try createInstallationMarker()
        } catch {
            Logger.error("Failed to create installation marker: \(error)", context: "OrphanedKeychainGuard")
        }
    }

    /// A keychain that cannot be read is treated as still holding the seed.
    private func hasRemainingSeed() -> Bool {
        let hasNativeSeed = (try? hasNativeMnemonic()) ?? true
        let hasRNSeed = (try? hasRNMnemonic()) ?? true
        return hasNativeSeed || hasRNSeed
    }
}
