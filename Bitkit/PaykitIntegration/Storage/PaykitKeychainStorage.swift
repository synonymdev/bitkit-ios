//
//  PaykitKeychainStorage.swift
//  Bitkit
//
//  Helper for storing Paykit data in Keychain using generic password items.
//

import Foundation

/// Helper class for storing Paykit-specific data in Keychain
/// Uses generic password items with custom account names
class PaykitKeychainStorage {
    
    private let serviceIdentifier = "to.bitkit.paykit"
    
    /// Store data in keychain
    func store(key: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        
        // Delete existing item if present
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != noErr {
            Logger.error("Failed to store Paykit keychain item: \(key), status: \(status)", context: "PaykitKeychainStorage")
            throw PaykitStorageError.saveFailed(key: key)
        }
        
        Logger.debug("Stored Paykit keychain item: \(key)", context: "PaykitKeychainStorage")
    }
    
    /// Retrieve data from keychain
    func retrieve(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecItemNotFound {
            Logger.debug("Paykit keychain item not found: \(key)", context: "PaykitKeychainStorage")
            return nil
        }
        
        if status != noErr {
            Logger.error("Failed to retrieve Paykit keychain item: \(key), status: \(status)", context: "PaykitKeychainStorage")
            throw PaykitStorageError.loadFailed(key: key)
        }
        
        Logger.debug("Retrieved Paykit keychain item: \(key)", context: "PaykitKeychainStorage")
        return dataTypeRef as? Data
    }
    
    /// Delete data from keychain
    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        if status != noErr && status != errSecItemNotFound {
            Logger.error("Failed to delete Paykit keychain item: \(key), status: \(status)", context: "PaykitKeychainStorage")
            throw PaykitStorageError.deleteFailed(key: key)
        }
        
        Logger.debug("Deleted Paykit keychain item: \(key)", context: "PaykitKeychainStorage")
    }
    
    /// Check if key exists
    func exists(key: String) -> Bool {
        do {
            return try retrieve(key: key) != nil
        } catch {
            return false
        }
    }
}

enum PaykitStorageError: LocalizedError {
    case saveFailed(key: String)
    case loadFailed(key: String)
    case deleteFailed(key: String)
    case encodingFailed
    case decodingFailed
    
    var errorDescription: String? {
        switch self {
        case .saveFailed(let key):
            return "Failed to save Paykit data: \(key)"
        case .loadFailed(let key):
            return "Failed to load Paykit data: \(key)"
        case .deleteFailed(let key):
            return "Failed to delete Paykit data: \(key)"
        case .encodingFailed:
            return "Failed to encode Paykit data"
        case .decodingFailed:
            return "Failed to decode Paykit data"
        }
    }
}

