import Foundation
import Security

enum KeychainEntryType {
    case bip39Mnemonic(index: Int)
    case bip39Passphrase(index: Int)
    case pushNotificationPrivateKey // For secp256k1 shared secret when decrypting push payload
    case securityPin
    case pinFailedAttempts
    case wipePending
    case paykitSession
    case paykitPendingPaymentProofs
    case onchainSendAttempts
    case onchainLightningHolds
    case paykitUsdtPayments
    case paykitPresentedPaymentRequests
    case paykitAcceptedPaymentRequests
    case paykitSubscriptionState
    case paykitKeyGeneration(publicKey: String)
    case paykitRecoveryBackup
    case paykitPendingBackupRestore
    case usdtPendingBackupRestore
    case paykitAllowanceState
    case paykitAllowancesPausedAfterRestore
    case pubkySecretKey

    var storageKey: String {
        switch self {
        case let .bip39Mnemonic(index): "bip39_mnemonic_\(index)"
        case let .bip39Passphrase(index): "bip39_passphrase_\(index)"
        case .pushNotificationPrivateKey: "push_notification_private_key"
        case .securityPin: "security_pin"
        case .pinFailedAttempts: "pin_failed_attempts"
        case .wipePending: "wipe_pending"
        case .paykitSession: "paykit_session"
        case .paykitPendingPaymentProofs: "paykit_pending_payment_proofs"
        case .onchainSendAttempts: "onchain_send_attempts"
        case .onchainLightningHolds: "onchain_lightning_holds"
        case .paykitUsdtPayments: "paykit_usdt_payments"
        case .paykitPresentedPaymentRequests: "paykit_presented_payment_requests"
        case .paykitAcceptedPaymentRequests: "paykit_accepted_payment_requests"
        case .paykitSubscriptionState: "paykit_subscription_state"
        case let .paykitKeyGeneration(publicKey): "paykit_key_generation_\(publicKey)"
        case .paykitRecoveryBackup: "paykit_recovery_backup"
        case .paykitPendingBackupRestore: "paykit_pending_backup_restore"
        case .usdtPendingBackupRestore: "usdt_pending_backup_restore"
        case .paykitAllowanceState: "paykit_allowance_state"
        case .paykitAllowancesPausedAfterRestore: "paykit_allowances_paused_after_restore"
        case .pubkySecretKey: "pubky_secret_key"
        }
    }
}

class Keychain {
    private static let unitTestAccountPrefix = "unit-tests."

    /// Under test, entries live under a prefixed account name so a suite cannot read, overwrite or
    /// delete the wallet belonging to whoever is running it. `BitkitTests` is hosted in the app and
    /// `Env.network` resolves to regtest for both, so tests and a Debug build otherwise share one
    /// keychain access group. This mirrors what `Env.appStorageUrl` already does for file storage,
    /// and only ever narrows what a process can see — the access group stays pinned either way.
    /// Internal rather than private so tests that build their own `SecItem` queries can address the
    /// same entry `save`/`load` use.
    class func account(for key: KeychainEntryType) -> String {
        Env.isUnitTest ? unitTestAccountPrefix + key.storageKey : key.storageKey
    }

    class func save(key: KeychainEntryType, data: Data) throws {
        Logger.debug("Saving \(key.storageKey)", context: "Keychain")

        let query = addQuery(key: key, data: data)

        // Don't allow accidentally overwriting keys
        guard try load(key: key) == nil else {
            Logger.error(
                "Key \(key.storageKey) already exists in keychain. Explicity delete key before attempting to update value.", context: "Keychain"
            )
            throw KeychainError.failedToSaveAlreadyExists
        }

        let status = SecItemAdd(query as CFDictionary, nil)

        if status != noErr {
            Logger.error("Failed to save \(key.storageKey) to keychain. \(status.description)", context: "Keychain")
            throw KeychainError.failedToSave
        }

        // Sanity check on save
        guard var storedValue = try load(key: key) else {
            Logger.error("Failed to load \(key.storageKey) after saving", context: "Keychain")
            throw KeychainError.failedToSave
        }

        guard storedValue == data else {
            Logger.error("Saved \(key.storageKey) does not match loaded value", context: "Keychain")
            throw KeychainError.failedToSave
        }
        storedValue = Data() // Clear memory

        Logger.info("Saved \(key.storageKey)", context: "Keychain")
    }

    private class func addQuery(key: KeychainEntryType, data: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccount as String: account(for: key),
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
    }

    class func saveString(key: KeychainEntryType, str: String) throws {
        guard let data = str.data(using: .utf8) else {
            throw KeychainError.failedToSave
        }

        try save(key: key, data: data)
    }

    class func update(key: KeychainEntryType, data: Data) throws {
        Logger.debug("Updating \(key.storageKey)", context: "Keychain")

        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: account(for: key),
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ] as [String: Any]

        let attributes = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            kSecAttrSynchronizable as String: false,
        ] as [String: Any]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status != noErr {
            Logger.error("Failed to update \(key.storageKey) in keychain. \(status.description)", context: "Keychain")
            throw KeychainError.failedToSave
        }

        // Sanity check on update
        guard var storedValue = try load(key: key) else {
            Logger.error("Failed to load \(key.storageKey) after updating", context: "Keychain")
            throw KeychainError.failedToSave
        }

        guard storedValue == data else {
            Logger.error("Updated \(key.storageKey) does not match loaded value", context: "Keychain")
            throw KeychainError.failedToSave
        }
        storedValue = Data() // Clear memory

        Logger.info("Updated \(key.storageKey)", context: "Keychain")
    }

    class func updateString(key: KeychainEntryType, str: String) throws {
        guard let data = str.data(using: .utf8) else {
            throw KeychainError.failedToSave
        }

        try update(key: key, data: data)
    }

    class func delete(key: KeychainEntryType) throws {
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: account(for: key),
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ] as [String: Any]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecItemNotFound {
            Logger.debug("\(key.storageKey) not found in keychain, nothing to delete", context: "Keychain")
            return
        }

        if status != noErr {
            Logger.error("Failed to delete \(key.storageKey) from keychain. \(status.description)", context: "Keychain")
            throw KeychainError.failedToDelete
        }

        Logger.debug("Deleted \(key.storageKey)", context: "Keychain")
    }

    /// Inserts or updates a keychain entry in one keychain call each, with no delete in between, so the entry never goes missing.
    class func upsert(key: KeychainEntryType, data: Data) throws {
        Logger.debug("Upserting \(key.storageKey)", context: "Keychain")

        let addStatus = SecItemAdd(addQuery(key: key, data: data) as CFDictionary, nil)
        if addStatus == noErr {
            Logger.info("Saved \(key.storageKey)", context: "Keychain")
            return
        }
        guard addStatus == errSecDuplicateItem else {
            Logger.error("Failed to save \(key.storageKey) to keychain. \(addStatus.description)", context: "Keychain")
            throw KeychainError.failedToSave
        }

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(for: key),
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        if status != noErr {
            Logger.error("Failed to update \(key.storageKey) in keychain. \(status.description)", context: "Keychain")
            throw KeychainError.failedToSave
        }

        Logger.info("Updated \(key.storageKey)", context: "Keychain")
    }

    class func exists(key: KeychainEntryType) throws -> Bool {
        var value = try load(key: key)
        let exists = value != nil
        value = Data() // Clear memory
        return exists
    }

    /// NOTE: throws if fails but return nil if not found
    class func load(key: KeychainEntryType) throws -> Data? {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account(for: key),
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ] as [String: Any]

        var dataTypeRef: AnyObject?

        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecItemNotFound {
            Logger.debug("\(key.storageKey) not found in keychain")
            return nil
        }

        if status != noErr {
            Logger.error("Failed to load \(key.storageKey) from keychain. \(status.description)", context: "Keychain")
            throw KeychainError.failedToLoad
        }

        Logger.debug("\(key.storageKey) loaded from keychain")
        return dataTypeRef as! Data?
    }

    class func loadString(key: KeychainEntryType) throws -> String? {
        if let data = try load(key: key), let str = String(data: data, encoding: .utf8) {
            return str
        }

        return nil
    }

    /// Throws rather than returning an empty list when the keychain cannot be read (before first unlock, for one), so a
    /// wipe never mistakes an unreadable keychain for an empty one.
    private class func storedAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == noErr, let items = result as? [[String: Any]] else {
            Logger.error("Failed to list keychain entries. \(status.description)", context: "Keychain")
            throw KeychainError.failedToLoad
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Deletes every entry in the access group except `retained`. One that cannot be deleted does not stop the others of its
    /// stage: it throws once all of them have been tried.
    class func wipeEntireKeychain(retaining retained: [KeychainEntryType] = []) throws {
        try wipe(
            accounts: storedAccounts(),
            retaining: Set(retained.map(account(for:))),
            delete: deleteItem(account:),
            remainingAccounts: storedAccounts
        )
    }

    /// The seeds go first and must be proven gone before anything else is deleted, so a failure never leaves a seed on the
    /// device without the PIN that locks it. A listing that cannot be read is not proof, so it throws too.
    static func wipe(
        accounts: [String],
        retaining retained: Set<String>,
        delete: (String) -> OSStatus,
        remainingAccounts: () throws -> [String]
    ) throws {
        // A test run must only ever clear its own namespaced entries. Deleting an un-prefixed
        // account here is what destroys the wallet on the simulator the suite runs against.
        let targets = accounts.filter { !retained.contains($0) && (!Env.isUnitTest || $0.hasPrefix(unitTestAccountPrefix)) }
        let seeds = targets.filter(isSeedAccount)
        let others = targets.filter { !isSeedAccount($0) }

        for stage in [seeds, others] where !stage.isEmpty {
            var hasFailedDelete = false
            for account in stage {
                let status = delete(account)
                guard status == noErr || status == errSecItemNotFound else {
                    Logger.error("Failed to delete \(account) from keychain. \(status.description)", context: "Keychain")
                    hasFailedDelete = true
                    continue
                }
                Logger.info("Deleted \(account) from keychain", context: "Keychain")
            }
            if hasFailedDelete {
                throw KeychainError.failedToDelete
            }
            let remaining = try Set(remainingAccounts()).intersection(stage)
            guard remaining.isEmpty else {
                Logger.error("Keychain still holds \(remaining.sorted()) after deleting them", context: "Keychain")
                throw KeychainError.failedToDelete
            }
        }
    }

    private static func isSeedAccount(_ account: String) -> Bool {
        let key = account.hasPrefix(unitTestAccountPrefix) ? String(account.dropFirst(unitTestAccountPrefix.count)) : account
        return key.hasPrefix("bip39_mnemonic_") || key.hasPrefix("bip39_passphrase_")
    }

    private class func deleteItem(account: String) -> OSStatus {
        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ] as [String: Any]
        return SecItemDelete(query as CFDictionary)
    }
}
