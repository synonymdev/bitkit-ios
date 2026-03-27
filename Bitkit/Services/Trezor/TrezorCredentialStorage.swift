import Foundation
import Security

/// Keychain storage for Trezor THP (Trezor Host Protocol) credentials
/// These credentials allow reconnection to BLE devices without re-pairing
enum TrezorCredentialStorage {
    // MARK: - Keychain Configuration

    /// Keychain service identifier for Trezor credentials
    private static let serviceName = "to.bitkit.trezor.thp"

    // MARK: - Public API

    /// Save THP credential for a device
    /// - Parameters:
    ///   - deviceId: Device identifier (MAC address or UUID)
    ///   - json: JSON string containing credential data
    /// - Returns: True if save was successful
    static func save(deviceId: String, json: String) -> Bool {
        let key = sanitizeDeviceId(deviceId)

        guard let data = json.data(using: .utf8) else {
            Logger.error("Failed to convert credential to data", context: "TrezorCredentialStorage")
            return false
        }

        // Delete existing credential first
        delete(deviceId: deviceId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecSuccess {
            Logger.info("Saved THP credential for device: \(key)", context: "TrezorCredentialStorage")
            return true
        } else {
            Logger.error("Failed to save THP credential: \(status)", context: "TrezorCredentialStorage")
            return false
        }
    }

    /// Load THP credential for a device
    /// - Parameter deviceId: Device identifier
    /// - Returns: JSON string containing credential data, or nil if not found
    static func load(deviceId: String) -> String? {
        let key = sanitizeDeviceId(deviceId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var dataRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataRef)

        if status == errSecSuccess, let data = dataRef as? Data {
            if let json = String(data: data, encoding: .utf8) {
                Logger.debug("Loaded THP credential for device: \(key)", context: "TrezorCredentialStorage")
                return json
            }
        } else if status == errSecItemNotFound {
            Logger.debug("No THP credential found for device: \(key)", context: "TrezorCredentialStorage")
        } else {
            Logger.error("Failed to load THP credential: \(status)", context: "TrezorCredentialStorage")
        }

        return nil
    }

    /// Delete THP credential for a device
    /// - Parameter deviceId: Device identifier
    static func delete(deviceId: String) {
        let key = sanitizeDeviceId(deviceId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess {
            Logger.info("Deleted THP credential for device: \(key)", context: "TrezorCredentialStorage")
        } else if status != errSecItemNotFound {
            Logger.warn("Failed to delete THP credential: \(status)", context: "TrezorCredentialStorage")
        }
    }

    /// List all device IDs with stored credentials
    /// - Returns: Array of device IDs (sanitized form)
    static func listAllDeviceIds() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let items = result as? [[String: Any]] {
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        }

        return []
    }

    // MARK: - Private Helpers

    /// Sanitize device ID for use as keychain account key
    /// Replaces characters that may cause issues in keychain
    private static func sanitizeDeviceId(_ deviceId: String) -> String {
        return deviceId
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
