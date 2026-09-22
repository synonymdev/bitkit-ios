import Foundation
import Security

/// Cross-app pubky records in the `pubky.shared` keychain access group.
///
/// Every app on the Apple team owns the accounts carrying its own `<sourceApp>:` prefix: it writes and
/// deletes only those, always per account and never service-wide. Foreign records are read-only, and a
/// secret is loaded just-in-time for the one account being used, never enumerated.
enum SharedPubkyKeychain {
    static let service = "pubky.shared.v1"
    static let ringSourceApp = "app.pubkyring"
    static let ownSourceApp = "to.bitkit"

    private static let pubkyPrefix = "pubky"

    private static func account(sourceApp: String, pubky: String) -> String {
        "\(sourceApp):\(pubky)"
    }

    private static let baseQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccessGroup as String: Env.sharedKeychainGroup,
    ]

    private static func accounts(withPrefix prefix: String) -> [String] {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
    }

    /// Bare z32 pubkys published by Pubky Ring.
    static func listRingIdentities() -> [String] {
        let prefix = "\(ringSourceApp):"
        return accounts(withPrefix: prefix).map { String($0.dropFirst(prefix.count)) }
    }

    static func derivedPubky(fromSecretKeyHex secretKeyHex: String) throws -> String {
        let rawKey = try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
        return rawKey.hasPrefix(pubkyPrefix) ? String(rawKey.dropFirst(pubkyPrefix.count)) : rawKey
    }

    static func isValidSecret(_ hex: String, pubky: String) -> Bool {
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return false
        }
        return (try? derivedPubky(fromSecretKeyHex: hex)) == pubky
    }

    /// Reads one record's secret, returning it only when it really is the secret for `pubky`.
    static func loadSecret(sourceApp: String, pubky: String) -> String? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account(sourceApp: sourceApp, pubky: pubky)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let hex = String(data: data, encoding: .utf8),
              isValidSecret(hex, pubky: pubky)
        else {
            return nil
        }
        return hex
    }

    /// True only when the record is provably gone; a read error means "unknown", not "removed".
    static func isDefinitelyMissing(sourceApp: String, pubky: String) -> Bool {
        var query = baseQuery
        query[kSecAttrAccount as String] = account(sourceApp: sourceApp, pubky: pubky)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound
    }

    static func publishOwn(pubky: String, secretKeyHex: String) {
        var query = baseQuery
        query[kSecAttrAccount as String] = account(sourceApp: ownSourceApp, pubky: pubky)

        let data = Data(secretKeyHex.utf8)
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        item[kSecValueData as String] = data

        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }

        if status != errSecSuccess {
            Logger.error("Failed to publish shared pubky record. \(status.description)", context: "SharedPubkyKeychain")
        }
    }

    static func removeOwn(pubky: String) {
        var query = baseQuery
        query[kSecAttrAccount as String] = account(sourceApp: ownSourceApp, pubky: pubky)
        SecItemDelete(query as CFDictionary)
    }

    static func removeAllOwn() {
        for account in accounts(withPrefix: "\(ownSourceApp):") {
            var query = baseQuery
            query[kSecAttrAccount as String] = account
            SecItemDelete(query as CFDictionary)
        }
    }
}

/// The pubky Bitkit adopted from another app. Only the reference is stored; the secret stays in its owner's store.
enum AdoptedPubkyReference {
    private static let sourceAppKey = "adoptedPubkySourceApp"
    private static let pubkyKey = "adoptedPubkyPubky"

    static var current: (sourceApp: String, pubky: String)? {
        get {
            guard let sourceApp = UserDefaults.standard.string(forKey: sourceAppKey),
                  let pubky = UserDefaults.standard.string(forKey: pubkyKey)
            else {
                return nil
            }
            return (sourceApp, pubky)
        }
        set {
            UserDefaults.standard.set(newValue?.sourceApp, forKey: sourceAppKey)
            UserDefaults.standard.set(newValue?.pubky, forKey: pubkyKey)
        }
    }
}
