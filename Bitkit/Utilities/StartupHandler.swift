import LDKNode
import SwiftUI

class StartupHandler {
    private init() {}

    /// Creates a new mnemonic and saves it to the keychain
    /// - Parameters:
    ///  - bip39Passphrase: optional bip39 passphrase
    ///  - walletIndex: wallet index, defaults to zero for first entry
    ///  - Returns: The generated mnemonic
    static func createNewWallet(bip39Passphrase: String?, walletIndex: Int = 0) throws -> String {
        let mnemonic = generateEntropyMnemonic(wordCount: .words12)

        try Keychain.saveString(key: .bip39Mnemonic(index: walletIndex), str: mnemonic)

        // Normalize empty strings to nil - empty passphrase should be treated as no passphrase
        if let bip39Passphrase, !bip39Passphrase.isEmpty {
            try Keychain.saveString(key: .bip39Passphrase(index: walletIndex), str: bip39Passphrase)
        }

        return mnemonic
    }

    /// Restores a wallet from a mnemonic and saves it to the keychain
    /// - Parameters:
    ///   - mnemonic: 12 or 24 word mnemonic
    ///   - bip39Passphrase: optional bip39 passphrase
    ///   - walletIndex: wallet index, defaults to zero for first
    static func restoreWallet(mnemonic: String, bip39Passphrase: String?, walletIndex: Int = 0) throws {
        let words = mnemonic.split(separator: " ")
        guard words.count == 12 || words.count == 24 else {
            throw AppError(message: "Mnemonic must be either 12 or 24 words", debugMessage: nil)
        }

        try Keychain.saveString(key: .bip39Mnemonic(index: walletIndex), str: mnemonic)

        // Normalize empty strings to nil - empty passphrase should be treated as no passphrase
        if let bip39Passphrase, !bip39Passphrase.isEmpty {
            try Keychain.saveString(key: .bip39Passphrase(index: walletIndex), str: bip39Passphrase)
        }
    }
}
