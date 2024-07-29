//
//  Keychain.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/29.
//

import Foundation
import Security

class KeyChain {
    enum KeyChainKey {
        case mnemonic(index: Int)
        
        var storageKey: String {
            switch self {
            case .mnemonic(let index):
                return "mnemonic_\(index)"
            }
        }
    }
    
    class func save(key: KeyChainKey, data: Data) throws {
        Logger.debug("Saving \(key.storageKey)", context: "Keychain")
        
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock as String,
            kSecAttrAccount as String: key.storageKey,
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: Env.keychainGroup
        ] as [String : Any]
        
        //Don't allow accidentally overwriting keys
        guard try load(key: key) == nil else {
            Logger.error("Key \(key.storageKey) already exists in keychain. Explicity delete key before attempting to update value.", context: "Keychain")
            throw KeychainError.failedToSaveAlreadyExists
        }
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != noErr {
            Logger.error("Failed to save \(key.storageKey) to keychain. \(status.description)", context: "Keychain")
            throw KeychainError.failedToSave
        }
        
        Logger.info("Saved \(key.storageKey)", context: "Keychain")
    }
    
    class func saveString(key: KeyChainKey, str: String) throws {
        guard let data = str.data(using: .utf8) else {
            throw KeychainError.failedToSave
        }
        
        try save(key: key, data: data)
    }
    
    class func delete(key: KeyChainKey) throws {
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key.storageKey,
            kSecAttrAccessGroup as String: Env.keychainGroup
        ] as [String : Any]
        
        let status = SecItemDelete(query as CFDictionary)
        
        if status != noErr {
            Logger.error("Failed to delete \(key.storageKey) from keychain. \(status.description)", context: "Keychain")
            throw KeychainError.failedToDelete
        }
        
        Logger.debug("Deleted \(key.storageKey)", context: "Keychain")
    }
    
    //TODO throws if fails but return nil if not found
    class func load(key: KeyChainKey) throws -> Data? {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.storageKey,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: Env.keychainGroup
        ] as [String : Any]
        
        var dataTypeRef: AnyObject? = nil
        
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status != noErr {
            Logger.error("Failed to load \(key.storageKey) from keychain. \(status.description)", context: "Keychain")
            throw KeychainError.failedToLoad
        }
        
        Logger.debug("\(key.storageKey) loaded from keychain")
        return dataTypeRef as! Data?
    }
    
    class func loadString(key: KeyChainKey) throws -> String? {
        if let data = try load(key: key), let str = String(data: data, encoding: .utf8) {
            return str
        }
        
        return nil
    }
    
    class func getAllKeyChainStorageKeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecReturnRef as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: AnyObject?
        let lastResultCode = withUnsafeMutablePointer(to: &result) {
            SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
        }
        
        var storageKeys = [String]()
        if lastResultCode == noErr {
            let array = result as? Array<Dictionary<String, Any>>
            for item in array! {
                if let key = item[kSecAttrAccount as String] as? String {
                    storageKeys.append(key)
                }
            }
        }
        
        return storageKeys
    }
    
    class func wipeEntireKeychain() throws {
        guard Env.isDebug && Env.network == .regtest else {
            Logger.error("Wiping keychain is only allowed in debug mode for regtest", context: "Keychain")
            throw KeychainError.keychainWipeNotAllowed
        }
        
        let keys = getAllKeyChainStorageKeys()
        for key in keys {
            let query = [
                kSecClass as String: kSecClassGenericPassword as String,
                kSecAttrAccount as String: key,
                kSecAttrAccessGroup as String: Env.keychainGroup
            ] as [String : Any]
            SecItemDelete(query as CFDictionary)
        }
    }
}
