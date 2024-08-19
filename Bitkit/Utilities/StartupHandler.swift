//
//  Startup.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

import SwiftUI
import BitcoinDevKit

class StartupHandler {
    private init() {}
    
    static func startAllServices() {
        Logger.debug("Spinning up services...")
        Task {
            do {
                try await OnChainViewModel.shared.start()
            } catch {
                Logger.error(error, context: "Failed to start on chain service")
            }
        }
        
        Task {
            do {
                try await LightningViewModel.shared.start()
            } catch {
                Logger.error(error, context: "Failed to start lightning service")
            }
        }
    }
    
    /// Creates a new mnemonic and saves it to the keychain
    /// - Parameters:
    ///  - bip39Passphrase: optional bip39 passphrase
    ///  - walletIndex: wallet index, defaults to zero for first entry
    ///  - Returns: The generated mnemonic
    static func createNewWallet(bip39Passphrase: String?, walletIndex: Int = 0) throws -> String {
        let mnemonic = Mnemonic(wordCount: Env.defaultWalletWordCount).asString()
                
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
        _ = try Mnemonic.fromString(mnemonic: mnemonic) //Check it's valid
        
        //TODO validate word count also?
                
        try Keychain.saveString(key: .bip39Mnemonic(index: walletIndex), str: mnemonic)
        if let bip39Passphrase {
            try Keychain.saveString(key: .bip39Passphrase(index: walletIndex), str: bip39Passphrase)
        }
    }
    
    static func requestPushNotificationPermision(completionHandler: @escaping (Bool, Error?) -> Void) {
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(
            options: authOptions,
            completionHandler: completionHandler
        )
        UIApplication.shared.registerForRemoteNotifications()
    }
}
