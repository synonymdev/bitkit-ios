import Foundation
import VssRustClientFfi

private actor VssStoreIdCache {
    private var cachedStoreIds: [Int: String] = [:]

    func get(walletIndex: Int) -> String? {
        return cachedStoreIds[walletIndex]
    }

    func set(_ storeId: String, for walletIndex: Int) {
        cachedStoreIds[walletIndex] = storeId
    }

    func clear() {
        cachedStoreIds.removeAll()
    }

    func clear(walletIndex: Int) {
        cachedStoreIds.removeValue(forKey: walletIndex)
    }
}

class VssStoreIdProvider {
    static let shared = VssStoreIdProvider()

    private let cache = VssStoreIdCache()

    private init() {}

    func getVssStoreId(walletIndex: Int) async throws -> String {
        if let cached = await cache.get(walletIndex: walletIndex) {
            Logger.info("VSS store id: '\(cached)' (cached)", context: "VssStoreIdProvider")
            return cached
        }

        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }

        // Normalize empty strings to nil - empty passphrase should be treated as no passphrase
        let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        let normalizedPassphrase = passphrase?.isEmpty == true ? nil : passphrase

        let storeId = try vssDeriveStoreId(
            prefix: Env.vssStoreIdPrefix,
            mnemonic: mnemonic,
            passphrase: normalizedPassphrase
        )

        await cache.set(storeId, for: walletIndex)

        Logger.info("VSS store id: '\(storeId)'", context: "VssStoreIdProvider")
        return storeId
    }

    func clearCache() {
        Task {
            await cache.clear()
        }
    }

    func clearCache(walletIndex: Int) {
        Task {
            await cache.clear(walletIndex: walletIndex)
        }
    }
}
