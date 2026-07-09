import Foundation
import Security

/// A pubky identity as stored in the keychain access group shared with Pubky Ring.
struct SharedPubkyRecord: Equatable {
    /// Canonical bare z-base32 public key (no `pubky`/`pubky://` prefix), used as the record id.
    let pubky: String
    /// Hex-encoded 32-byte Ed25519 secret key (interchangeable between BitkitCore and react-native-pubky).
    let secretKeyHex: String
    /// BIP39 recovery phrase when the origin app has one, otherwise empty.
    /// Bitkit-origin records are ALWAYS empty here: the wallet mnemonic controls Bitcoin funds and must never be shared.
    let mnemonic: String
}

/// Cross-app pubky identity vault backed by the `Env.sharedPubkyKeychainGroup` keychain access group.
///
/// Deliberately separate from `Keychain`: it sets `kSecAttrService` (which `Keychain` never does), stores
/// Pubky Ring's `IKeychainData` JSON payload verbatim, and enumerates records scoped to the shared group.
/// Both apps mirror their own identities in and read the union to offer cross-app reuse.
enum SharedPubkyVault {
    private static let accessGroup = Env.sharedPubkyKeychainGroup
    private static let context = "SharedPubkyVault"

    /// On-disk payload. Codable keys match Pubky Ring's `IKeychainData` exactly.
    private struct Payload: Codable {
        let secretKey: String
        let mnemonic: String
    }

    /// Length of a bare z-base32 Ed25519 public key (32 bytes → ceil(256/5) chars).
    private static let bareZ32Length = 52

    /// Strip Bitkit's display prefix so the id matches Pubky Ring's bare z-base32 form.
    static func canonicalPubky(_ raw: String) -> String {
        if raw.hasPrefix("pubky://") {
            return String(raw.dropFirst("pubky://".count))
        }
        // Bitkit's display form prefixes the bare z32 with "pubky". Strip it only when the remainder is a
        // full-length bare z32, so a genuine z32 that happens to start with the letters "pubky" (all valid
        // z-base32 symbols) is never truncated.
        if raw.hasPrefix("pubky") {
            let stripped = String(raw.dropFirst("pubky".count))
            if stripped.count == bareZ32Length {
                return stripped
            }
        }
        return raw
    }

    static func list() -> [SharedPubkyRecord] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: accessGroup,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecReturnData as String: kCFBooleanTrue!,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            Logger.debug("Shared pubky vault: no items (errSecItemNotFound)", context: context)
            return []
        }
        guard status == noErr, let items = result as? [[String: Any]] else {
            Logger.error("Failed to enumerate shared pubky vault. \(status.description)", context: context)
            return []
        }

        Logger.debug("Shared pubky vault: SecItemCopyMatching returned \(items.count) raw item(s)", context: context)

        return items.compactMap { item -> SharedPubkyRecord? in
            guard let service = item[kSecAttrService as String] as? String else {
                Logger.warn("Shared vault item missing/invalid service attribute (type: \(type(of: item[kSecAttrService as String])))", context: context)
                return nil
            }
            guard let data = item[kSecValueData as String] as? Data else {
                Logger.warn("Shared vault item \(service) missing data", context: context)
                return nil
            }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                Logger.warn("Shared vault item \(service) failed JSON decode", context: context)
                return nil
            }
            return SharedPubkyRecord(pubky: service, secretKeyHex: payload.secretKey, mnemonic: payload.mnemonic)
        }
    }

    static func read(pubky: String) -> SharedPubkyRecord? {
        let service = canonicalPubky(pubky)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue!,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == noErr,
              let data = result as? Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return nil
        }
        return SharedPubkyRecord(pubky: service, secretKeyHex: payload.secretKey, mnemonic: payload.mnemonic)
    }

    /// Insert or update a record. Non-destructive merge: never replaces an existing non-empty mnemonic
    /// with an empty one, so the richer recovery-phrase-bearing copy always wins.
    static func upsert(pubky: String, secretKeyHex: String, mnemonic: String) {
        let service = canonicalPubky(pubky)

        var mnemonicToStore = mnemonic
        if mnemonic.isEmpty, let existing = read(pubky: service), !existing.mnemonic.isEmpty {
            mnemonicToStore = existing.mnemonic
        }

        guard let data = try? JSONEncoder().encode(Payload(secretKey: secretKeyHex, mnemonic: mnemonicToStore)) else {
            Logger.error("Failed to encode shared pubky payload", context: context)
            return
        }

        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        if itemExists(service: service) {
            let status = SecItemUpdate(matchQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status != noErr {
                Logger.error("Failed to update shared pubky \(service). \(status.description)", context: context)
                return
            }
            Logger.info("Updated shared pubky \(service)", context: context)
        } else {
            var addQuery = matchQuery
            addQuery[kSecAttrAccount as String] = service
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecAttrSynchronizable as String] = false
            addQuery[kSecValueData as String] = data

            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != noErr {
                Logger.error("Failed to add shared pubky \(service). \(status.description)", context: context)
                return
            }
            Logger.info("Mirrored pubky \(service) into shared vault", context: context)
        }
    }

    static func delete(pubky: String) {
        let service = canonicalPubky(pubky)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != noErr, status != errSecItemNotFound {
            Logger.error("Failed to delete shared pubky \(service). \(status.description)", context: context)
        }
    }

    private static func itemExists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == noErr
    }
}
