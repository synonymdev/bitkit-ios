import Foundation
import Security

/// A source-owned interoperability mirror. The source app's private Keychain remains canonical.
enum SharedPubkyIdentityVault {
    static let service = "pubky.identity-sharing.v1"
    static let sharedAccessGroupInfoKey = "SharedPubkyKeychainAccessGroup"

    static func account(source: SharedPubkyIdentitySource, pubky: String) -> String {
        "\(source.rawValue):\(pubky)"
    }

    static func list(source: SharedPubkyIdentitySource) throws -> [SharedPubkyIdentityRefV1] {
        try references(accounts: allAccounts(), source: source)
    }

    static func allAccounts() throws -> [String] {
        let query: [String: Any] = try [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: sharedAccessGroup(),
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var rawResult: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
        if status == errSecItemNotFound {
            return []
        }
        try check(status)

        let attributes: [[String: Any]]
        if let all = rawResult as? [[String: Any]] {
            attributes = all
        } else if let one = rawResult as? [String: Any] {
            attributes = [one]
        } else {
            throw SharedPubkyIdentityError.invalidRecord
        }

        return attributes.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Loads secret data for one explicitly selected identity. Discovery never calls this.
    static func loadCredential(
        reference: SharedPubkyIdentityRefV1,
        derivePublicKey: (String) throws -> String = {
            try PubkyProfileManager.publicKeyFromSecretKey($0)
        }
    ) throws -> String {
        guard reference.version == SharedPubkyIdentityRefV1.currentVersion else {
            throw SharedPubkyIdentityError.invalidRecord
        }

        let query: [String: Any] = try [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(source: reference.sourceApp, pubky: reference.pubky),
            kSecAttrAccessGroup as String: sharedAccessGroup(),
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var rawResult: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
        if status == errSecItemNotFound {
            throw SharedPubkyIdentityError.sourceIdentityMissing
        }
        try check(status)

        guard let data = rawResult as? Data,
              let record = try? JSONDecoder().decode(SharedPubkyIdentityRecordV1.self, from: data)
        else {
            throw SharedPubkyIdentityError.invalidRecord
        }

        try validate(record: record, expected: reference, derivePublicKey: derivePublicKey)
        return record.secretKey
    }

    static func publishBitkitIdentity(pubky: String, secretKey: String) throws {
        let reference = try SharedPubkyIdentityRefV1(sourceApp: .bitkit, pubky: pubky)
        let record = SharedPubkyIdentityRecordV1(
            sourceApp: .bitkit,
            pubky: reference.pubky,
            secretKey: secretKey
        )
        try validate(
            record: record,
            expected: reference,
            derivePublicKey: { try PubkyProfileManager.publicKeyFromSecretKey($0) }
        )
        let payload = try JSONEncoder().encode(record)
        let accessGroup = try sharedAccessGroup()
        let itemAccount = account(source: .bitkit, pubky: reference.pubky)

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: itemAccount,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
        let updateStatus = SecItemUpdate(
            searchQuery as CFDictionary,
            [
                kSecValueData as String: payload,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addQuery[kSecValueData as String] = payload
            try check(SecItemAdd(addQuery as CFDictionary, nil))
        } else {
            try check(updateStatus)
        }

        let storedSecret = try loadCredential(reference: reference)
        guard storedSecret == secretKey else {
            throw SharedPubkyIdentityError.invalidRecord
        }

        // Bitkit owns exactly one local identity. Only prune stale Bitkit-owned
        // accounts after the current mirror has been written and verified.
        try pruneStaleBitkitIdentities(
            keeping: itemAccount,
            listAccounts: { try allAccounts() },
            deleteAccount: { try deleteOwnedAccount($0) }
        )
    }

    static func deleteBitkitIdentity(pubky: String) throws {
        guard let normalizedPubky = SharedPubkyKeyFormat.normalizedBare(pubky) else {
            throw SharedPubkyIdentityError.invalidPublicKey
        }

        let itemAccount = account(source: .bitkit, pubky: normalizedPubky)
        try deleteOwnedAccount(itemAccount)

        let remainingAccounts = try allAccounts()
        guard !remainingAccounts.contains(itemAccount) else {
            throw SharedPubkyIdentityError.invalidRecord
        }
    }

    static func deleteAllBitkitIdentities() throws {
        let accounts = try ownedAccounts(accounts: allAccounts(), source: .bitkit)
        for itemAccount in accounts {
            try deleteOwnedAccount(itemAccount)
        }

        guard try ownedAccounts(accounts: allAccounts(), source: .bitkit).isEmpty else {
            throw SharedPubkyIdentityError.invalidRecord
        }
    }

    static func pruneStaleBitkitIdentities(
        keeping currentAccount: String,
        listAccounts: () throws -> [String],
        deleteAccount: (String) throws -> Void
    ) throws {
        let ownedBeforePruning = try ownedAccounts(accounts: listAccounts(), source: .bitkit)
        guard ownedBeforePruning.contains(currentAccount) else {
            throw SharedPubkyIdentityError.invalidRecord
        }

        for staleAccount in ownedBeforePruning where staleAccount != currentAccount {
            try deleteAccount(staleAccount)
        }

        guard try ownedAccounts(accounts: listAccounts(), source: .bitkit) == [currentAccount] else {
            throw SharedPubkyIdentityError.invalidRecord
        }
    }

    static func ownedAccounts(
        accounts: [String],
        source: SharedPubkyIdentitySource
    ) -> [String] {
        let prefix = "\(source.rawValue):"
        return Array(Set(accounts.filter { $0.hasPrefix(prefix) })).sorted()
    }

    static func references(
        accounts: [String],
        source: SharedPubkyIdentitySource
    ) -> [SharedPubkyIdentityRefV1] {
        let prefix = "\(source.rawValue):"
        var seen = Set<String>()

        return ownedAccounts(accounts: accounts, source: source).compactMap { value -> SharedPubkyIdentityRefV1? in
            let wirePubky = String(value.dropFirst(prefix.count))
            guard SharedPubkyKeyFormat.normalizedBare(wirePubky) == wirePubky,
                  let reference = try? SharedPubkyIdentityRefV1(
                      sourceApp: source,
                      pubky: wirePubky
                  ),
                  seen.insert(reference.pubky).inserted
            else {
                return nil
            }
            return reference
        }
        .sorted { $0.pubky < $1.pubky }
    }

    static func validate(
        record: SharedPubkyIdentityRecordV1,
        expected: SharedPubkyIdentityRefV1,
        derivePublicKey: (String) throws -> String
    ) throws {
        guard record.version == SharedPubkyIdentityRecordV1.currentVersion,
              expected.version == SharedPubkyIdentityRefV1.currentVersion,
              record.sourceApp == expected.sourceApp,
              record.pubky == expected.pubky,
              SharedPubkyKeyFormat.isCanonicalSecretKey(record.secretKey)
        else {
            throw SharedPubkyIdentityError.invalidRecord
        }

        let derivedPubky: String
        do {
            derivedPubky = try derivePublicKey(record.secretKey)
        } catch {
            throw SharedPubkyIdentityError.invalidRecord
        }
        guard SharedPubkyKeyFormat.normalizedBare(derivedPubky) == expected.pubky else {
            throw SharedPubkyIdentityError.secretDoesNotMatchPublicKey
        }
    }

    static func sharedAccessGroup(bundle: Bundle = .main) throws -> String {
        guard let value = bundle.object(forInfoDictionaryKey: sharedAccessGroupInfoKey) as? String,
              !value.isEmpty,
              !value.contains("$(")
        else {
            throw SharedPubkyIdentityError.unavailable
        }
        return value
    }

    private static func check(_ status: OSStatus) throws {
        guard status != noErr else { return }
        if status == errSecMissingEntitlement {
            throw SharedPubkyIdentityError.missingEntitlement
        }

        Logger.warn("Shared Pubky Keychain operation failed with status \(status)", context: "SharedPubkyIdentityVault")
        throw SharedPubkyIdentityError.unavailable
    }

    private static func deleteOwnedAccount(_ itemAccount: String) throws {
        guard ownedAccounts(accounts: [itemAccount], source: .bitkit) == [itemAccount] else {
            throw SharedPubkyIdentityError.invalidRecord
        }

        let query: [String: Any] = try [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: itemAccount,
            kSecAttrAccessGroup as String: sharedAccessGroup(),
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == noErr || status == errSecItemNotFound else {
            try check(status)
            return
        }
    }
}

enum SharedPubkyIdentityReferenceStore {
    static func load() throws -> SharedPubkyIdentityRefV1? {
        guard let data = try Keychain.load(key: .sharedPubkyIdentityReference) else {
            return nil
        }

        guard let reference = try? JSONDecoder().decode(SharedPubkyIdentityRefV1.self, from: data),
              reference.version == SharedPubkyIdentityRefV1.currentVersion,
              SharedPubkyKeyFormat.normalizedBare(reference.pubky) == reference.pubky
        else {
            throw SharedPubkyIdentityError.invalidRecord
        }
        return reference
    }

    static func save(_ reference: SharedPubkyIdentityRefV1) throws {
        try Keychain.upsert(
            key: .sharedPubkyIdentityReference,
            data: JSONEncoder().encode(reference)
        )
    }

    static func delete() throws {
        try Keychain.delete(key: .sharedPubkyIdentityReference)
        guard try Keychain.load(key: .sharedPubkyIdentityReference) == nil else {
            throw KeychainError.failedToDelete
        }
    }
}
