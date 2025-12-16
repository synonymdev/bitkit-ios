//
//  PaykitKeychainStorage.swift
//  Bitkit
//
//  Helper for storing Paykit data in Keychain using generic password items.
//

import Foundation

/// Helper class for storing Paykit-specific data in Keychain
/// Uses generic password items with custom account names
public class PaykitKeychainStorage {
    
    public static let shared = PaykitKeychainStorage()
    
    private let serviceIdentifier = "to.bitkit.paykit"
    
    public init() {}
    
    /// Store data in keychain
    public func store(key: String, data: Data) throws {
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
    
    // MARK: - Convenience Methods
    
    /// Store data using set/get naming convention
    public func set(key: String, value: Data) {
        do {
            try store(key: key, data: value)
        } catch {
            Logger.error("Failed to set keychain value: \(error)", context: "PaykitKeychainStorage")
        }
    }
    
    /// Get data using set/get naming convention
    public func get(key: String) -> Data? {
        do {
            return try retrieve(key: key)
        } catch {
            Logger.error("Failed to get keychain value: \(error)", context: "PaykitKeychainStorage")
            return nil
        }
    }
    
    /// Delete without throwing (convenience method)
    public func deleteQuietly(key: String) {
        do {
            try delete(key: key) as Void
        } catch {
            Logger.error("Failed to delete keychain value: \(error)", context: "PaykitKeychainStorage")
        }
    }
    
    /// List all keys with a given prefix
    /// - Parameter prefix: The key prefix to filter by
    /// - Returns: Array of matching keys
    public func listKeys(withPrefix prefix: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == noErr else {
            if status == errSecItemNotFound {
                return []
            }
            Logger.error("Failed to list keychain items, status: \(status)", context: "PaykitKeychainStorage")
            return []
        }
        
        guard let items = result as? [[String: Any]] else {
            return []
        }
        
        return items.compactMap { item -> String? in
            guard let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            return account.hasPrefix(prefix) ? account : nil
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

