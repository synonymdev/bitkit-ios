import Foundation
import Security

enum KeychainEntryType {
    case bip39Mnemonic(index: Int)
    case bip39Passphrase(index: Int)
    case pushNotificationPrivateKey // For secp256k1 shared secret when decrypting push payload
    case securityPin
    case paykitSession
    case paykitPendingPaymentProofs
    case onchainSendAttempts
    case paykitUsdtPayments
    case paykitPresentedPaymentRequests
    case paykitAcceptedPaymentRequests
    case paykitSubscriptionState
    case paykitKeyGeneration(publicKey: String)
    case paykitRecoveryBackup
    case paykitPendingBackupRestore
    case usdtPendingBackupRestore
    case paykitAllowanceState
    case pubkySecretKey

    var storageKey: String {
        switch self {
        case let .bip39Mnemonic(index): "bip39_mnemonic_\(index)"
        case let .bip39Passphrase(index): "bip39_passphrase_\(index)"
        case .pushNotificationPrivateKey: "push_notification_private_key"
        case .securityPin: "security_pin"
        case .paykitSession: "paykit_session"
        case .paykitPendingPaymentProofs: "paykit_pending_payment_proofs"
        case .onchainSendAttempts: "onchain_send_attempts"
        case .paykitUsdtPayments: "paykit_usdt_payments"
        case .paykitPresentedPaymentRequests: "paykit_presented_payment_requests"
        case .paykitAcceptedPaymentRequests: "paykit_accepted_payment_requests"
        case .paykitSubscriptionState: "paykit_subscription_state"
        case let .paykitKeyGeneration(publicKey): "paykit_key_generation_\(publicKey)"
        case .paykitRecoveryBackup: "paykit_recovery_backup"
        case .paykitPendingBackupRestore: "paykit_pending_backup_restore"
        case .usdtPendingBackupRestore: "usdt_pending_backup_restore"
        case .paykitAllowanceState: "paykit_allowance_state"
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

        let query = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccount as String: account(for: key),
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ] as [String: Any]

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
        #if DEBUG
            try ProfileRemovalTestFault.check("\(key.storageKey):delete")
        #endif
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

    /// Atomically inserts or updates a keychain entry, avoiding the delete-then-save race window.
    class func upsert(key: KeychainEntryType, data: Data) throws {
        Logger.debug("Upserting \(key.storageKey)", context: "Keychain")

        let existingData = try load(key: key)

        if existingData != nil {
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
        } else {
            try save(key: key, data: data)
        }
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

    class func getAllKeyChainStorageKeys(
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    ) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrAccessGroup as String: Env.keychainGroup,
        ]
        var result: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            Logger.error("Failed to enumerate keychain accounts: \(status)", context: "Keychain")
            throw KeychainError.failedToLoad
        }
        return try items.map { item in
            guard let account = item[kSecAttrAccount as String] as? String else {
                throw KeychainError.failedToLoad
            }
            return account
        }
    }

    class func wipeEntireKeychain(
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching,
        delete: (CFDictionary) -> OSStatus = SecItemDelete
    ) throws {
        let keys = try getAllKeyChainStorageKeys(copyMatching: copyMatching)
        for key in keys {
            // Tests may erase only their own namespace, never a simulator's wallet or Ring credentials.
            if Env.isUnitTest, !key.hasPrefix(unitTestAccountPrefix) {
                continue
            }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecAttrAccessGroup as String: Env.keychainGroup,
            ]
            let status = delete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                Logger.error("Failed to delete a keychain account: \(status)", context: "Keychain")
                throw KeychainError.failedToDelete
            }
        }
    }
}

#if DEBUG
    /// Opt-in failures at real local teardown boundaries on a disposable regtest simulator.
    enum ProfileRemovalTestFault {
        static let allowed: Set<String> = [
            "paykit_session:delete", "pubky_secret_key:delete",
            "shared-own:enumerate", "shared-own:delete",
            "preferences:flush", "marker:persist", "marker:complete",
        ]

        private static func selected() -> String? {
            #if targetEnvironment(simulator)
                guard Env.isE2E, Env.network == .regtest, !Env.isUnitTest,
                      ProcessInfo.processInfo.arguments.contains("-E2E_PROFILE_REMOVAL_FAULTS") else { return nil }
                let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("profile-removal-test-fault")
                guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? file.close() }
                guard let data = try? file.read(upToCount: 129), data.count <= 128,
                      let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      allowed.contains(value) else { return nil }
                return value
            #else
                return nil
            #endif
        }

        static func check(_ point: String) throws {
            try check(point, selected: selected())
        }

        static func check(_ point: String, selected: String?) throws {
            guard allowed.contains(point), selected == point else { return }
            Logger.warn("Injected local profile cleanup failure: \(point)", context: "ProfileRemovalTestFault")
            throw NSError(
                domain: "ProfileRemovalTestFault",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Local profile cleanup storage unavailable (\(point))"]
            )
        }
    }
#endif
