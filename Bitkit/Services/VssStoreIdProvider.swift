import Foundation
import VssRustClientFfi

class VssStoreIdProvider {
    static let shared = VssStoreIdProvider()
    
    private var cachedStoreId: String?
    
    private init() {}
    
    func getVssStoreId(walletIndex: Int) throws -> String {
        if let cached = cachedStoreId {
            return cached
        }

        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        
        let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        
        let storeId = try vssDeriveStoreId(
            prefix: Env.vssStoreIdPrefix,
            mnemonic: mnemonic,
            passphrase: passphrase
        )
        
        cachedStoreId = storeId
        Logger.info("VSS store id: '\(storeId)'", context: "VssStoreIdProvider")
        return storeId
    }
    
    func clearCache() {
        cachedStoreId = nil
    }
}

