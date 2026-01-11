import Foundation
import VssRustClientFfi

/// Actor to coordinate VSS client setup (ensures only one setup runs at a time)
private actor VssSetupCoordinator {
    private var setupTask: Task<Void, Error>?

    func awaitSetup(setupAction: @escaping () async throws -> Void) async throws {
        // If setup is already in progress or completed, wait for it
        if let existingTask = setupTask {
            try await existingTask.value
            return
        }

        // Create and store the setup task
        let task = Task {
            try await setupAction()
        }
        setupTask = task

        do {
            try await task.value
        } catch {
            // Reset on any error to allow retry attempts
            setupTask = nil
            throw error
        }
    }

    func reset() {
        setupTask?.cancel()
        setupTask = nil
    }
}

class VssBackupClient {
    static let shared = VssBackupClient()

    private let setupCoordinator = VssSetupCoordinator()

    private init() {}

    func reset() async {
        await setupCoordinator.reset()
    }

    func setup(walletIndex: Int = 0) async throws {
        do {
            try await withTimeout(seconds: 30) {
                Logger.debug("VSS client setting up…", context: "VssBackupClient")

                let vssUrl = Env.vssServerUrl
                let lnurlAuthServerUrl = Env.lnurlAuthServerUrl
                Logger.debug("Building VSS client with vssUrl: '\(vssUrl)'", context: "VssBackupClient")
                Logger.debug("Building VSS client with lnurlAuthServerUrl: '\(lnurlAuthServerUrl)'", context: "VssBackupClient")

                let storeId = try await VssStoreIdProvider.shared.getVssStoreId(walletIndex: walletIndex)

                if !lnurlAuthServerUrl.isEmpty {
                    guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
                        throw CustomServiceError.mnemonicNotFound
                    }
                    let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))

                    try await vssNewClientWithLnurlAuth(
                        baseUrl: vssUrl,
                        storeId: storeId,
                        mnemonic: mnemonic,
                        passphrase: passphrase,
                        lnurlAuthServerUrl: lnurlAuthServerUrl
                    )
                } else {
                    try await vssNewClient(
                        baseUrl: vssUrl,
                        storeId: storeId
                    )
                }

                Logger.info("VSS client setup with server: '\(vssUrl)'", context: "VssBackupClient")
            }
        } catch {
            Logger.error("VSS client setup error: \(error)", context: "VssBackupClient")
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
            let item = try await vssGet(key: key)
            if let item {
                Logger.debug("VSS 'getObject' success for '\(key)'", context: "VssBackupClient")
            } else {
                Logger.debug("VSS 'getObject' success null for '\(key)'", context: "VssBackupClient")
            }
            return item
        } catch {
            Logger.debug("VSS 'getObject' error for '\(key)': \(error)", context: "VssBackupClient")
            throw error
        }
    }

    private func awaitSetup() async throws {
        try await setupCoordinator.awaitSetup { [self] in
            try await setup()
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
