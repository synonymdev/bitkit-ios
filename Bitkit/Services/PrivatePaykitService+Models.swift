import Foundation
import Paykit

// MARK: - State Models

extension PrivatePaykitService {
    struct ContactPaykitHandles {
        var linkId: String?
        var handshakeId: String?
    }

    struct LinkEstablishmentTask {
        var id: UUID
        var maxAdvanceSteps: Int
        var task: Task<String?, Error>
    }

    struct PublicationTask {
        var id: UUID
        var task: Task<Void, Error>
    }

    struct PrivateStoragePurgeResult {
        var deletedCount: Int
        var didHitLimit: Bool
        var didFail: Bool
    }

    struct PrivatePaykitState {
        var contacts: [String: ContactState]

        init(contacts: [String: ContactState]) {
            self.contacts = contacts
        }

        init(secretState: PrivatePaykitSecretState, cacheState: PrivatePaykitCacheState) {
            var contacts = cacheState.contacts.mapValues(ContactState.init(cacheState:))

            for (publicKey, secretState) in secretState.contacts {
                var contactState = contacts[publicKey, default: ContactState()]
                contactState.linkSnapshotHex = secretState.linkSnapshotHex
                contactState.handshakeSnapshotHex = secretState.handshakeSnapshotHex
                contacts[publicKey] = contactState
            }

            self.contacts = contacts
        }

        var secretState: PrivatePaykitSecretState {
            PrivatePaykitSecretState(
                contacts: contacts.compactMapValues { contactState in
                    let secretState = ContactSecretState(contactState: contactState)
                    return secretState.hasSecretState ? secretState : nil
                }
            )
        }

        var cacheState: PrivatePaykitCacheState {
            PrivatePaykitCacheState(
                contacts: contacts.compactMapValues { contactState in
                    let cacheState = ContactCacheState(contactState: contactState)
                    return cacheState.hasCacheState ? cacheState : nil
                }
            )
        }
    }

    struct PrivatePaykitSecretState: Codable {
        var contacts: [String: ContactSecretState]
    }

    struct PrivatePaykitCacheState: Codable {
        var contacts: [String: ContactCacheState]
    }

    struct ContactState: Codable {
        var linkSnapshotHex: String?
        var handshakeSnapshotHex: String?
        var remoteEndpoints: [StoredPaymentEntry] = []
        var localInvoice: StoredInvoice?
        var receivedInvoicePaymentHashes: [String] = []
        var lastLocalPayloadHash: String?
        var linkCompletedAt: UInt64?
        var handshakeUpdatedAt: UInt64?
        var recoveryStartedAt: UInt64?
        var mainRecoveryAttemptId: String?
        var responderRecoveryAttemptId: String?
        var lastCompletedRecoveryAttemptId: String?
        var linkFailureCount: Int = 0

        init() {}

        init(cacheState: ContactCacheState) {
            remoteEndpoints = cacheState.remoteEndpoints
            localInvoice = cacheState.localInvoice
            receivedInvoicePaymentHashes = cacheState.receivedInvoicePaymentHashes
            lastLocalPayloadHash = cacheState.lastLocalPayloadHash
            linkCompletedAt = cacheState.linkCompletedAt
            handshakeUpdatedAt = cacheState.handshakeUpdatedAt
            recoveryStartedAt = cacheState.recoveryStartedAt
            mainRecoveryAttemptId = cacheState.mainRecoveryAttemptId
            responderRecoveryAttemptId = cacheState.responderRecoveryAttemptId
            lastCompletedRecoveryAttemptId = cacheState.lastCompletedRecoveryAttemptId
            linkFailureCount = cacheState.linkFailureCount
        }

        var remoteEndpointMap: [String: String] {
            remoteEndpoints.reduce(into: [:]) { map, entry in
                map[entry.methodId] = entry.endpointData
            }
        }

        var hasBackupState: Bool {
            linkSnapshotHex != nil ||
                handshakeSnapshotHex != nil ||
                !remoteEndpoints.isEmpty ||
                linkCompletedAt != nil ||
                handshakeUpdatedAt != nil ||
                recoveryStartedAt != nil ||
                mainRecoveryAttemptId != nil ||
                responderRecoveryAttemptId != nil ||
                lastCompletedRecoveryAttemptId != nil
        }
    }

    struct ContactSecretState: Codable {
        var linkSnapshotHex: String?
        var handshakeSnapshotHex: String?

        init(contactState: ContactState) {
            linkSnapshotHex = contactState.linkSnapshotHex
            handshakeSnapshotHex = contactState.handshakeSnapshotHex
        }

        var hasSecretState: Bool {
            linkSnapshotHex != nil ||
                handshakeSnapshotHex != nil
        }
    }

    struct ContactCacheState: Codable {
        var remoteEndpoints: [StoredPaymentEntry] = []
        var localInvoice: StoredInvoice?
        var receivedInvoicePaymentHashes: [String] = []
        var lastLocalPayloadHash: String?
        var linkCompletedAt: UInt64?
        var handshakeUpdatedAt: UInt64?
        var recoveryStartedAt: UInt64?
        var mainRecoveryAttemptId: String?
        var responderRecoveryAttemptId: String?
        var lastCompletedRecoveryAttemptId: String?
        var linkFailureCount: Int = 0

        init(contactState: ContactState) {
            remoteEndpoints = contactState.remoteEndpoints
            localInvoice = contactState.localInvoice
            receivedInvoicePaymentHashes = contactState.receivedInvoicePaymentHashes
            lastLocalPayloadHash = contactState.lastLocalPayloadHash
            linkCompletedAt = contactState.linkCompletedAt
            handshakeUpdatedAt = contactState.handshakeUpdatedAt
            recoveryStartedAt = contactState.recoveryStartedAt
            mainRecoveryAttemptId = contactState.mainRecoveryAttemptId
            responderRecoveryAttemptId = contactState.responderRecoveryAttemptId
            lastCompletedRecoveryAttemptId = contactState.lastCompletedRecoveryAttemptId
            linkFailureCount = contactState.linkFailureCount
        }

        var hasCacheState: Bool {
            !remoteEndpoints.isEmpty ||
                localInvoice != nil ||
                !receivedInvoicePaymentHashes.isEmpty ||
                lastLocalPayloadHash != nil ||
                linkCompletedAt != nil ||
                handshakeUpdatedAt != nil ||
                recoveryStartedAt != nil ||
                mainRecoveryAttemptId != nil ||
                responderRecoveryAttemptId != nil ||
                lastCompletedRecoveryAttemptId != nil ||
                linkFailureCount != 0
        }
    }

    struct StoredPaymentEntry: Codable {
        var methodId: String
        var endpointData: String

        init(entry: FfiPaymentEntry) {
            methodId = entry.methodId
            endpointData = entry.endpointData
        }

        init(methodId: String, endpointData: String) {
            self.methodId = methodId
            self.endpointData = endpointData
        }
    }

    struct StoredInvoice: Codable {
        var bolt11: String
        var paymentHash: String
        var expiresAt: Double
    }

    struct RecoveryMarker: Codable {
        var version: Int
        var path: String
        var stage: String
        var attemptId: String
        var createdAt: UInt64
    }
}
