import Foundation
import VssRustClientFfi

class VssBackupClient {
    static let shared = VssBackupClient()

    private var isSetup: Task<Void, Error>?

    private init() {}

    func reset() {
        isSetup = nil
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

    func list(prefix: String? = nil) async throws -> [VssItem] {
        try await awaitSetup()

        Logger.debug("VSS 'list' call with prefix: \(prefix ?? "nil")", context: "VssBackupClient")

        do {
            let items = try await vssList(prefix: prefix)
            Logger.debug("VSS 'list' success - found \(items.count) item(s) with prefix: \(prefix ?? "nil")", context: "VssBackupClient")
            return items
        } catch {
            Logger.debug("VSS 'list' error with prefix: \(prefix ?? "nil") - \(error)", context: "VssBackupClient")
            throw error
        }
    }

    func listKeys(prefix: String? = nil) async throws -> [KeyVersion] {
        try await awaitSetup()

        Logger.debug("VSS 'listKeys' call with prefix: \(prefix ?? "nil")", context: "VssBackupClient")

        do {
            let keys = try await vssListKeys(prefix: prefix)
            Logger.debug("VSS 'listKeys' success - found \(keys.count) key(s)", context: "VssBackupClient")
            return keys
        } catch {
            Logger.debug("VSS 'listKeys' error: \(error)", context: "VssBackupClient")
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

    func deleteObject(key: String) async throws -> Bool {
        try await awaitSetup()

        Logger.debug("VSS 'deleteObject' call for '\(key)'", context: "VssBackupClient")

        do {
            let wasDeleted = try await vssDelete(key: key)
            if wasDeleted {
                Logger.debug("VSS 'deleteObject' success for '\(key)' - key was found and deleted", context: "VssBackupClient")
            } else {
                Logger.debug("VSS 'deleteObject' success for '\(key)' - key did not exist", context: "VssBackupClient")
            }
            return wasDeleted
        } catch {
            Logger.debug("VSS 'deleteObject' error for '\(key)': \(error)", context: "VssBackupClient")
            throw error
        }
    }

    func deleteAllKeys() async throws {
        try await awaitSetup()

        Logger.debug("VSS 'deleteAllKeys' call", context: "VssBackupClient")

        do {
            let keys = try await vssListKeys(prefix: nil)
            for keyVersion in keys {
                try await vssDelete(key: keyVersion.key)
            }
            Logger.debug("VSS 'deleteAllKeys' success", context: "VssBackupClient")
        } catch {
            Logger.debug("VSS 'deleteAllKeys' error: \(error)", context: "VssBackupClient")
            throw error
        }
    }

    func deobfuscateKey(key: String) async throws -> String {
        try await awaitSetup()

        Logger.debug("VSS 'deobfuscateKey' call for '\(key)'", context: "VssBackupClient")

        do {
            let deobfuscatedKey = try await vssDeobfuscateKey(storageKey: key)
            Logger.debug("VSS 'deobfuscateKey' success for '\(key)' - deobfuscated key: '\(deobfuscatedKey)'", context: "VssBackupClient")
            return deobfuscatedKey
        } catch {
            Logger.debug("VSS 'deobfuscateKey' error for '\(key)': \(error)", context: "VssBackupClient")
            throw error
        }
    }

    private func awaitSetup() async throws {
        if let existingSetup = isSetup {
            do {
                try await existingSetup.value
            } catch let error as CancellationError {
                isSetup = nil
                throw error
            }
        }

        let setupTask = Task {
            try await setup()
        }
        isSetup = setupTask

        do {
            try await setupTask.value
        } catch let error as CancellationError {
            isSetup = nil
            throw error
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
