import Combine
import Foundation

private actor PrivatePaykitPublicationLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        return try await operation()
    }

    private func lock() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        waiters.removeFirst().resume()
    }
}

// MARK: - Core Actor

actor PrivatePaykitService {
    static let shared = PrivatePaykitService()

    private static let walletBackupDataChangedSubject = PassthroughSubject<Void, Never>()

    nonisolated static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        walletBackupDataChangedSubject.eraseToAnyPublisher()
    }

    static let invoiceRefreshBufferSeconds: TimeInterval = 30 * 60
    static let maxReceivedInvoicePaymentHashesPerContact = 100
    static let publishingEnabledKey = "sharesPrivatePaykitEndpoints"
    static let cleanupPendingKey = "paykitContactSharingCleanupPending"
    static let deletedContactCleanupKeysKey = "privatePaykitDeletedContactCleanupKeys"
    static let cacheStateKey = "privatePaykitCacheState"
    /// Private links can finish after a contact is added on the other device; keep draining long enough for staggered mutual adds.
    static let privateMessageDrainRetryDelays: [UInt64] = [
        1_000_000_000,
        3_000_000_000,
        8_000_000_000,
        20_000_000_000,
        45_000_000_000,
        90_000_000_000,
    ]

    var state: PrivatePaykitState
    var knownSavedContactKeys: Set<String> = []
    var pendingMessageDrainRetryTask: Task<Void, Never>?
    private let publicationLock = PrivatePaykitPublicationLock()

    init() {
        state = UserDefaults.standard.data(forKey: Self.cacheStateKey)
            .flatMap { try? JSONDecoder().decode(PrivatePaykitState.self, from: $0) } ?? PrivatePaykitState(contacts: [:])
    }

    func withPublicationLock<T>(_ operation: () async throws -> T) async throws -> T {
        try await publicationLock.withLock(operation)
    }

    func markWalletBackupDataChanged() {
        Self.walletBackupDataChangedSubject.send()
    }

    static func setContactSharingCleanupPending(_ isPending: Bool) {
        UserDefaults.standard.set(isPending, forKey: cleanupPendingKey)
    }

    static func pendingDeletedContactCleanupKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: deletedContactCleanupKeysKey) ?? [])
    }

    static func markDeletedContactCleanupPending(_ publicKeys: [String]) {
        let normalizedKeys = publicKeys.compactMap(PubkyPublicKeyFormat.normalized)
        guard !normalizedKeys.isEmpty else { return }

        let keys = pendingDeletedContactCleanupKeys().union(normalizedKeys)
        UserDefaults.standard.set(Array(keys).sorted(), forKey: deletedContactCleanupKeysKey)
    }

    static func clearDeletedContactCleanupPending(_ publicKeys: [String]) {
        var keys = pendingDeletedContactCleanupKeys()
        keys.subtract(publicKeys.compactMap(PubkyPublicKeyFormat.normalized))
        if keys.isEmpty {
            UserDefaults.standard.removeObject(forKey: deletedContactCleanupKeysKey)
        } else {
            UserDefaults.standard.set(Array(keys).sorted(), forKey: deletedContactCleanupKeysKey)
        }
    }

    static func clearDeletedContactCleanupPending() {
        UserDefaults.standard.removeObject(forKey: deletedContactCleanupKeysKey)
    }
}
