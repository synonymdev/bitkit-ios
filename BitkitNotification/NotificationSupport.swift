import Foundation
import Security

enum NotificationKeychain {
    static func loadPrivateKey() throws -> Data {
        #if DEBUG
            let accessGroup = "KYH47R284B.to.bitkit.regtest"
        #else
            let accessGroup = "KYH47R284B.to.bitkit"
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "push_notification_private_key",
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let privateKey = result as? Data else {
            throw NSError(domain: "NotificationKeychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not load notification key"])
        }
        return privateKey
    }
}

enum NotificationLock {
    private struct Content: Decodable {
        let environment: String
        let date: Date

        var expiryTime: TimeInterval? {
            switch environment {
            case "foregroundApp": 5 * 60
            case "pushNotificationExtension": 35
            default: nil
            }
        }
    }

    static func isLocked() -> Bool {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.bitkit") else { return false }
        let lockFile = container.appendingPathComponent("lightning.lock")
        guard let data = try? Data(contentsOf: lockFile),
              let lock = try? JSONDecoder().decode(Content.self, from: data),
              let expiryTime = lock.expiryTime
        else { return false }

        return Date().timeIntervalSince(lock.date) <= expiryTime
    }
}
