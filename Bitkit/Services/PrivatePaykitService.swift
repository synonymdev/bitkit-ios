import Combine
import Foundation

// MARK: - Core Actor

actor PrivatePaykitService {
    static let shared = PrivatePaykitService()

    static let walletBackupDataChangedSubject = PassthroughSubject<Void, Never>()

    nonisolated static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        walletBackupDataChangedSubject.eraseToAnyPublisher()
    }

    static let maxNoisePayloadBytes = 1000
    static let invoiceRefreshBufferSeconds: TimeInterval = 30 * 60
    static let maxReceivedInvoicePaymentHashesPerContact = 100
    static let staleLinkFailureThreshold = 3
    static let publishingEnabledKey = "sharesPrivatePaykitEndpoints"
    static let cleanupPendingKey = "paykitContactSharingCleanupPending"
    static let profileRecoveryPendingKey = "privatePaykitProfileRecoveryPending"
    static let cacheStateKey = "privatePaykitCacheState"
    static let privateEndpointRemovalPayload = #"{"value":""}"#
    static let recoveryMarkerStageInit = "init"
    static let recoveryMarkerStageResponse = "response"
    static let recoveryMarkerStageFinal = "final"
    static let pendingPublicationRetryDelay: UInt64 = 5_000_000_000
    static let pendingPublicationRetryAttempts = 60
    static let freshLinkInitialPublishDelaySeconds: UInt64 = 8
    static let completedLinkRecoveryMarkerGraceSeconds: UInt64 = 5 * 60
    static let privateStorageRootPath = "/pub/paykit/v0/private/"
    static let privateStoragePurgeMaxEntries = 500
    static let privateStoragePurgeMaxDepth = 3

    var state: PrivatePaykitState
    var activeHandlesByContact: [String: ContactPaykitHandles] = [:]
    var linkEstablishmentTasks: [String: LinkEstablishmentTask] = [:]
    var publicationTasks: [String: PublicationTask] = [:]
    var pendingPublicationRetryTasks: [String: Task<Void, Never>] = [:]
    var knownSavedContactKeys: Set<String> = []
    var stateGeneration: UInt64 = 0

    init() {
        let secretState = (try? Keychain.load(key: .privatePaykitSecretState))
            .flatMap { try? JSONDecoder().decode(PrivatePaykitSecretState.self, from: $0) } ?? PrivatePaykitSecretState(contacts: [:])
        let cacheState = UserDefaults.standard.data(forKey: Self.cacheStateKey)
            .flatMap { try? JSONDecoder().decode(PrivatePaykitCacheState.self, from: $0) } ?? PrivatePaykitCacheState(contacts: [:])

        state = PrivatePaykitState(secretState: secretState, cacheState: cacheState)
    }

    static func shouldInitiate(ownPublicKey: String, remotePublicKey: String) -> Bool {
        let own = PubkyPublicKeyFormat.normalized(ownPublicKey) ?? ownPublicKey
        let remote = PubkyPublicKeyFormat.normalized(remotePublicKey) ?? remotePublicKey
        return own > remote
    }

    static func setContactSharingCleanupPending(_ isPending: Bool) {
        UserDefaults.standard.set(isPending, forKey: cleanupPendingKey)
    }

    static func setProfileRecoveryPending(_ isPending: Bool) {
        UserDefaults.standard.set(isPending, forKey: profileRecoveryPendingKey)
    }

    static var isProfileRecoveryPending: Bool {
        UserDefaults.standard.bool(forKey: profileRecoveryPendingKey)
    }
}
