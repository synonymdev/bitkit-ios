//
//  Startup.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

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
        let mnemonic = generateEntropyMnemonic()
                
        try Keychain.saveString(key: .bip39Mnemonic(index: walletIndex), str: mnemonic)
        if let bip39Passphrase {
            try Keychain.saveString(key: .bip39Passphrase(index: walletIndex), str: bip39Passphrase)
        }
                
        return mnemonic
    }
    
    /// Restores a wallet from a mnemoni and, saves it to the keychain
    /// - Parameters:
    ///   - mnemonic: 12 or 24 word mnemonic
    ///   - bip39Passphrase: optional bip39 passphrase
    ///   - walletIndex: wallet index, defaults to zero for first
    static func restoreWallet(mnemonic: String, bip39Passphrase: String?, walletIndex: Int = 0) throws {
        // TODO: validate word count also?
                
        try Keychain.saveString(key: .bip39Mnemonic(index: walletIndex), str: mnemonic)
        if let bip39Passphrase {
            try Keychain.saveString(key: .bip39Passphrase(index: walletIndex), str: bip39Passphrase)
        }
    }
    
    @MainActor
    static func requestPushNotificationPermision(completionHandler: @escaping (Bool, Error?) -> Void) {
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(
            options: authOptions,
            completionHandler: completionHandler
        )
        UIApplication.shared.registerForRemoteNotifications()
    }
}
