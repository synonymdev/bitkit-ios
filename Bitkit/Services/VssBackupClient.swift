import Foundation
import VssRustClientFfi

/// Actor to coordinate VSS client setup (ensures only one setup runs at a time)
private actor VssSetupCoordinator {
    private enum SetupState {
        case idle
        case inProgress(Task<Void, Error>)
        case completed
    }

    private var state: SetupState = .idle

    func awaitSetup(setupAction: @escaping () async throws -> Void) async throws {
        switch state {
        case .completed:
            Logger.debug("VssSetupCoordinator: already completed, returning", context: "VssBackupClient")
            return

        case let .inProgress(existingTask):
            Logger.debug("VssSetupCoordinator: setup in progress, waiting for existing task", context: "VssBackupClient")
            try await existingTask.value
            Logger.debug("VssSetupCoordinator: existing task completed", context: "VssBackupClient")
            return

        case .idle:
            Logger.debug("VssSetupCoordinator: idle, starting new setup", context: "VssBackupClient")
            let task = Task {
                try await setupAction()
            }
            state = .inProgress(task)

            do {
                try await task.value
                state = .completed
                Logger.debug("VssSetupCoordinator: setup completed successfully", context: "VssBackupClient")
            } catch {
                // Reset on any error to allow retry attempts
                state = .idle
                Logger.debug("VssSetupCoordinator: setup failed, resetting to idle", context: "VssBackupClient")
                throw error
            }
        }
    }

    func reset() {
        Logger.debug("VssSetupCoordinator: reset called", context: "VssBackupClient")
        if case let .inProgress(task) = state {
            task.cancel()
        }
        state = .idle
    }
}

class VssBackupClient {
    static let shared = VssBackupClient()

    private let setupCoordinator = VssSetupCoordinator()
    private let ldkSetupCoordinator = VssSetupCoordinator()

    private init() {}

    func reset() async {
        await setupCoordinator.reset()
        await ldkSetupCoordinator.reset()
    }

    /// Returns lnurl auth params when lnurl is configured; nil otherwise.
    private func getLnurlAuthParams(walletIndex: Int) async throws
        -> (vssUrl: String, storeId: String, mnemonic: String, passphrase: String?, lnurlAuthServerUrl: String)?
    {
        let lnurlAuthServerUrl = Env.lnurlAuthServerUrl
        guard !lnurlAuthServerUrl.isEmpty else { return nil }
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphraseRaw = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        let passphrase = passphraseRaw?.isEmpty == true ? nil : passphraseRaw
        let storeId = try await VssStoreIdProvider.shared.getVssStoreId(walletIndex: walletIndex)
        return (Env.vssServerUrl, storeId, mnemonic, passphrase, lnurlAuthServerUrl)
    }

    private func setup(walletIndex: Int = 0) async throws {
        do {
            try await withTimeout(seconds: 30) { [self] in
                Logger.debug("VSS client setting up…", context: "VssBackupClient")
                let vssUrl = Env.vssServerUrl
                Logger.debug("Building VSS client with vssUrl: '\(vssUrl)'", context: "VssBackupClient")

                if let params = try await getLnurlAuthParams(walletIndex: walletIndex) {
                    try await vssNewClientWithLnurlAuth(
                        baseUrl: params.vssUrl,
                        storeId: params.storeId,
                        mnemonic: params.mnemonic,
                        passphrase: params.passphrase,
                        lnurlAuthServerUrl: params.lnurlAuthServerUrl
                    )
                } else {
                    let storeId = try await VssStoreIdProvider.shared.getVssStoreId(walletIndex: walletIndex)
                    try await vssNewClient(baseUrl: vssUrl, storeId: storeId)
                }
                Logger.info("VSS client setup with server: '\(vssUrl)'", context: "VssBackupClient")
            }
        } catch {
            Logger.error("VSS client setup error: \(error)", context: "VssBackupClient")
            throw error
        }
    }

    /// Lazily initializes the LDK VSS client (used only by the debug screen). Only runs when lnurl auth is configured.
    private func setupLdk(walletIndex: Int = 0) async throws {
        guard let params = try await getLnurlAuthParams(walletIndex: walletIndex) else {
            throw AppError(message: "LDK VSS requires lnurl auth", debugMessage: "lnurlAuthServerUrl is not set")
        }
        do {
            try await withTimeout(seconds: 30) {
                Logger.debug("VSS LDK client setting up…", context: "VssBackupClient")
                try await vssNewLdkClientWithLnurlAuth(
                    baseUrl: params.vssUrl,
                    storeId: params.storeId,
                    mnemonic: params.mnemonic,
                    passphrase: params.passphrase,
                    lnurlAuthServerUrl: params.lnurlAuthServerUrl
                )
                Logger.info("VSS LDK client setup with server: '\(params.vssUrl)'", context: "VssBackupClient")
            }
        } catch {
            Logger.error("VSS LDK client setup error: \(error)", context: "VssBackupClient")
            throw error
        }
    }

    func putObject(key: String, data: Data) async throws -> VssItem {
        try await awaitSetup()

        Logger.debug("VSS 'putObject' call for '\(key)'", context: "VssBackupClient")

        do {
            let item = try await vssStore(key: key, value: data)
            Logger.debug("VSS 'putObject' success for '\(key)' at version: \(item.version)", context: "VssBackupClient")
            return item
        } catch {
            Logger.debug("VSS 'putObject' error for '\(key)': \(error)", context: "VssBackupClient")
            throw error
        }
    }

    func getObject(key: String) async throws -> VssItem? {
        try await awaitSetup()

        Logger.debug("VSS 'getObject' call for '\(key)'", context: "VssBackupClient")

        do {
            if let item = try await vssGet(key: key) {
                Logger.debug("VSS 'getObject' success for '\(key)' at version \(item.version)", context: "VssBackupClient")
                return item
            } else {
                Logger.debug("VSS 'getObject' success null for '\(key)'", context: "VssBackupClient")
                return nil
            }
        } catch {
            Logger.debug("VSS 'getObject' error for '\(key)': \(error)", context: "VssBackupClient")
            throw error
        }
    }

    func listKeys() async throws -> [String] {
        let versions = try await listKeyVersions()
        return versions.map(\.key)
    }

    /// Returns app-level keys with version info (for debug UI).
    func listKeyVersions() async throws -> [KeyVersion] {
        try await awaitSetup()
        Logger.debug("VSS 'listKeyVersions' call", context: "VssBackupClient")
        do {
            let versions = try await vssListKeys(prefix: nil)
            Logger.debug("VSS 'listKeyVersions' success: \(versions.count) key(s)", context: "VssBackupClient")
            return versions
        } catch {
            Logger.debug("VSS 'listKeyVersions' error: \(error)", context: "VssBackupClient")
            throw error
        }
    }

    /// Deletes a single app-level key.
    func deleteKey(_ key: String) async throws -> Bool {
        try await awaitSetup()
        Logger.debug("VSS 'deleteKey' call for '\(key)'", context: "VssBackupClient")
        do {
            let wasDeleted = try await vssDelete(key: key)
            Logger.debug("VSS 'deleteKey' success for '\(key)': \(wasDeleted)", context: "VssBackupClient")
            return wasDeleted
        } catch {
            Logger.debug("VSS 'deleteKey' error for '\(key)': \(error)", context: "VssBackupClient")
            throw error
        }
    }

    /// Deletes all app-level keys (lists then deletes each).
    func deleteAllKeys() async throws {
        let versions = try await listKeyVersions()
        for kv in versions {
            _ = try await deleteKey(kv.key)
        }
    }

    // MARK: - LDK namespace keys (for debug; requires FFI with LdkNamespace support)

    private static let ldkNamespacesForList: [LdkNamespace] = [
        .default,
        .monitors,
        .archivedMonitors,
    ]

    /// Returns all LDK keys across default, monitors, and archivedMonitors namespaces.
    func listAllKeysTaggedLdk() async throws -> [(LdkNamespace, KeyVersion)] {
        try await awaitLdkSetup()
        Logger.debug("VSS 'listAllKeysTaggedLdk' call", context: "VssBackupClient")
        var result: [(LdkNamespace, KeyVersion)] = []
        for ns in Self.ldkNamespacesForList {
            do {
                let keys = try await vssLdkListKeys(namespace: ns)
                result.append(contentsOf: keys.map { (ns, $0) })
            } catch {
                Logger.debug("VSS 'listAllKeysTaggedLdk' error for namespace \(ns): \(error)", context: "VssBackupClient")
                throw error
            }
        }
        Logger.debug("VSS 'listAllKeysTaggedLdk' success: \(result.count) key(s)", context: "VssBackupClient")
        return result
    }

    /// Gets a single LDK key value by key and namespace.
    func getObjectLdk(key: String, namespace: LdkNamespace) async throws -> VssItem? {
        try await awaitLdkSetup()
        Logger.debug("VSS 'getObjectLdk' call for '\(key)'", context: "VssBackupClient")
        do {
            let item = try await vssLdkGet(key: key, namespace: namespace)
            return item
        } catch {
            Logger.debug("VSS 'getObjectLdk' error for '\(key)': \(error)", context: "VssBackupClient")
            throw error
        }
    }

    /// Deletes a single LDK key by key and namespace.
    func deleteObjectLdk(key: String, namespace: LdkNamespace) async throws -> Bool {
        try await awaitLdkSetup()
        Logger.debug("VSS 'deleteObjectLdk' call for '\(key)'", context: "VssBackupClient")
        do {
            let wasDeleted = try await vssLdkDelete(key: key, namespace: namespace)
            Logger.debug("VSS 'deleteObjectLdk' success for '\(key)': \(wasDeleted)", context: "VssBackupClient")
            return wasDeleted
        } catch {
            Logger.debug("VSS 'deleteObjectLdk' error for '\(key)': \(error)", context: "VssBackupClient")
            throw error
        }
    }

    private func awaitSetup() async throws {
        try await setupCoordinator.awaitSetup { [self] in
            try await setup()
        }
    }

    /// Lazily sets up the LDK client when first needed (debug screen). Independent of the app client.
    private func awaitLdkSetup() async throws {
        try await ldkSetupCoordinator.awaitSetup { [self] in
            try await setupLdk()
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AppError(message: "Operation timed out", debugMessage: "Timeout after \(seconds) seconds")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
