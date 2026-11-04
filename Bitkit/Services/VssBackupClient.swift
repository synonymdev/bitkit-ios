import Foundation
import VssRustClientFfi

/// Owns setup and calls until both native slots can be retired together.
/// Calls remain concurrent; reset closes admission and waits without holding a network lock.
actor VssClientCoordinator {
    enum Domain { case app, ldk }

    private struct Setup {
        let id = UUID()
        let task: Task<Void, Error>
    }

    private var generation = UUID()
    private var setups: [Domain: Setup] = [:]
    private var ready: Set<Domain> = []
    private var activeCalls = 0
    private var resetting = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var resetWaiters: [CheckedContinuation<Void, Never>] = []

    func withClient<T>(
        domain: Domain,
        setup: @escaping () async throws -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !resetting else { throw CancellationError() }
        let owner = generation
        activeCalls += 1
        defer { finishCall() }

        let result: Result<T, Error>
        do {
            try await awaitSetup(domain: domain, owner: owner, action: setup)
            try validate(owner)
            result = try await .success(operation())
        } catch {
            result = .failure(error)
        }
        try validate(owner)
        return try result.get()
    }

    /// Cancellation of the caller cannot abandon retirement. Native calls already
    /// admitted may finish, but their results cannot escape into the next owner.
    func reset(shutdown: () -> Void) async {
        if resetting {
            await withCheckedContinuation { resetWaiters.append($0) }
            return
        }
        await closeAdmission()
        shutdown()
        reopenAdmission()
    }

    /// Keep admission closed while the caller replaces or removes wallet credentials.
    func withSuspendedClients<T>(shutdown: () -> Void, operation: () async throws -> T) async throws -> T {
        while resetting {
            await withCheckedContinuation { resetWaiters.append($0) }
        }
        await closeAdmission()
        shutdown()
        defer { reopenAdmission() }
        return try await operation()
    }

    private func closeAdmission() async {
        resetting = true
        generation = UUID()
        setups.values.forEach { $0.task.cancel() }
        if activeCalls > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func reopenAdmission() {
        setups.removeAll()
        ready.removeAll()
        resetting = false
        let waiters = resetWaiters
        resetWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func awaitSetup(domain: Domain, owner: UUID, action: @escaping () async throws -> Void) async throws {
        if ready.contains(domain) {
            return
        }
        let setup: Setup
        if let existing = setups[domain] {
            setup = existing
        } else {
            setup = Setup(task: Task { try await action() })
            setups[domain] = setup
        }
        do {
            try await setup.task.value
            guard !resetting, generation == owner else { throw CancellationError() }
            if setups[domain]?.id == setup.id {
                ready.insert(domain)
                setups[domain] = nil
            }
        } catch {
            if generation == owner, setups[domain]?.id == setup.id {
                setups[domain] = nil
            }
            throw error
        }
    }

    private func validate(_ owner: UUID) throws {
        try Task.checkCancellation()
        guard !resetting, generation == owner else { throw CancellationError() }
    }

    private func finishCall() {
        activeCalls -= 1
        if activeCalls == 0 {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}

class VssBackupClient {
    static let shared = VssBackupClient()

    private let coordinator = VssClientCoordinator()

    private init() {}

    func reset() async {
        await coordinator.reset {
            vssShutdownClient()
            vssShutdownLdkClient()
        }
    }

    func withSuspendedClients<T>(_ operation: () async throws -> T) async throws -> T {
        try await coordinator.withSuspendedClients(shutdown: {
            vssShutdownClient()
            vssShutdownLdkClient()
        }, operation: operation)
    }

    /// Returns LNURL-auth params when configured. Callers fail closed if this returns nil.
    private func getLnurlAuthParams(walletIndex: Int) async throws
        -> (vssUrl: String, storeId: String, mnemonic: String, passphrase: String?, lnurlAuthServerUrl: String)?
    {
        let lnurlAuthServerUrl = Env.lnurlAuthServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lnurlAuthServerUrl.isEmpty else { return nil }
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphraseRaw = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        let passphrase = passphraseRaw?.isEmpty == true ? nil : passphraseRaw
        let storeId = try vssDeriveStoreId(
            prefix: Env.vssStoreIdPrefix,
            mnemonic: mnemonic,
            passphrase: passphrase
        )
        return (Env.vssServerUrl, storeId, mnemonic, passphrase, lnurlAuthServerUrl)
    }

    private func setup(walletIndex: Int = 0) async throws {
        do {
            try await withTimeout(seconds: 30) { [self] in
                Logger.debug("VSS client setting up…", context: "VssBackupClient")
                let vssUrl = Env.vssServerUrl
                Logger.debug("Building VSS client with vssUrl: '\(vssUrl)'", context: "VssBackupClient")

                guard let params = try await getLnurlAuthParams(walletIndex: walletIndex) else {
                    throw CustomServiceError.vssAuthRequired
                }
                try await vssNewClientWithLnurlAuth(
                    baseUrl: params.vssUrl,
                    storeId: params.storeId,
                    mnemonic: params.mnemonic,
                    passphrase: params.passphrase,
                    lnurlAuthServerUrl: params.lnurlAuthServerUrl
                )
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
            throw CustomServiceError.vssAuthRequired
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
        try await coordinator.withClient(domain: .app, setup: { [self] in try await setup() }) {
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
    }

    func getObject(key: String) async throws -> VssItem? {
        try await coordinator.withClient(domain: .app, setup: { [self] in try await setup() }) {
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
                Logger.warn("VSS 'getObject' error for '\(key)': \(error)", context: "VssBackupClient")
                throw error
            }
        }
    }

    func listKeys() async throws -> [String] {
        let versions = try await listKeyVersions()
        return versions.map(\.key)
    }

    /// Returns app-level keys with version info (for debug UI).
    func listKeyVersions() async throws -> [KeyVersion] {
        try await coordinator.withClient(domain: .app, setup: { [self] in try await setup() }) {
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
    }

    /// Deletes a single app-level key.
    func deleteKey(_ key: String) async throws -> Bool {
        try await coordinator.withClient(domain: .app, setup: { [self] in try await setup() }) {
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
    }

    /// Deletes all app-level keys (lists then deletes each).
    func deleteAllKeys() async throws {
        try await coordinator.withClient(domain: .app, setup: { [self] in try await setup() }) {
            let versions = try await vssListKeys(prefix: nil)
            for version in versions {
                _ = try await vssDelete(key: version.key)
            }
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
        try await coordinator.withClient(domain: .ldk, setup: { [self] in try await setupLdk() }) {
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
    }

    /// Gets a single LDK key value by key and namespace.
    func getObjectLdk(key: String, namespace: LdkNamespace) async throws -> VssItem? {
        try await coordinator.withClient(domain: .ldk, setup: { [self] in try await setupLdk() }) {
            Logger.debug("VSS 'getObjectLdk' call for '\(key)'", context: "VssBackupClient")
            do {
                return try await vssLdkGet(key: key, namespace: namespace)
            } catch {
                Logger.debug("VSS 'getObjectLdk' error for '\(key)': \(error)", context: "VssBackupClient")
                throw error
            }
        }
    }

    /// Deletes a single LDK key by key and namespace.
    func deleteObjectLdk(key: String, namespace: LdkNamespace) async throws -> Bool {
        try await coordinator.withClient(domain: .ldk, setup: { [self] in try await setupLdk() }) {
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
    }

    func deleteLdkScorerCache() async throws {
        try await coordinator.withClient(domain: .ldk, setup: { [self] in try await setupLdk() }) {
            _ = try await vssLdkDelete(key: "scorer", namespace: .default)
            _ = try await vssLdkDelete(key: "external_pathfinding_scores_cache", namespace: .default)
            Logger.info("Cleared LDK scorer cache from VSS", context: "VssBackupClient")
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
