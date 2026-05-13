import Foundation

// MARK: - Backup

extension PrivatePaykitService {
    func backupSnapshot() -> [String: PrivatePaykitContactLinkBackupV1]? {
        let contacts: [String: PrivatePaykitContactLinkBackupV1] = Dictionary(
            uniqueKeysWithValues: state.contacts.compactMap { publicKey, contactState in
                guard contactState.hasBackupState else {
                    return nil
                }

                return (
                    publicKey,
                    PrivatePaykitContactLinkBackupV1(
                        publicKey: publicKey,
                        linkSnapshotHex: contactState.linkSnapshotHex,
                        handshakeSnapshotHex: contactState.handshakeSnapshotHex,
                        remoteEndpoints: contactState.remoteEndpointMap,
                        linkCompletedAt: contactState.linkCompletedAt,
                        handshakeUpdatedAt: contactState.handshakeUpdatedAt,
                        recoveryStartedAt: contactState.recoveryStartedAt,
                        mainRecoveryAttemptId: contactState.mainRecoveryAttemptId,
                        responderRecoveryAttemptId: contactState.responderRecoveryAttemptId
                    )
                )
            }
        )

        guard !contacts.isEmpty else { return nil }

        return contacts
    }

    func restoreBackup(_ backup: [String: PrivatePaykitContactLinkBackupV1]?) async {
        resetInFlightWork()
        await closeActivePaykitHandles()
        activeHandlesByContact.removeAll()
        knownSavedContactKeys.removeAll()

        guard let backup else {
            state = PrivatePaykitState(contacts: [:])
            persistState()
            return
        }

        var restoredContacts: [String: ContactState] = [:]
        for (publicKey, contactBackup) in backup {
            guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { continue }
            let linkSnapshotHex = await validatedSnapshot(
                contactBackup.linkSnapshotHex,
                publicKey: normalizedKey,
                recipient: PubkyService.encryptedLinkSnapshotRecipient
            )
            let handshakeSnapshotHex = await validatedSnapshot(
                contactBackup.handshakeSnapshotHex,
                publicKey: normalizedKey,
                recipient: PubkyService.encryptedLinkHandshakeSnapshotRecipient
            )

            var contactState = ContactState()
            contactState.linkSnapshotHex = linkSnapshotHex
            contactState.handshakeSnapshotHex = handshakeSnapshotHex
            contactState.remoteEndpoints = Self.storedPaymentEntries(from: contactBackup.remoteEndpoints)
            contactState.linkCompletedAt = contactBackup.linkCompletedAt
            contactState.handshakeUpdatedAt = contactBackup.handshakeUpdatedAt
            contactState.recoveryStartedAt = contactBackup.recoveryStartedAt
            contactState.mainRecoveryAttemptId = contactBackup.mainRecoveryAttemptId
            contactState.responderRecoveryAttemptId = contactBackup.responderRecoveryAttemptId
            restoredContacts[normalizedKey] = contactState
        }

        state = PrivatePaykitState(contacts: restoredContacts)
        persistState()
    }

    func validatedSnapshot(
        _ snapshotHex: String?,
        publicKey: String,
        recipient: (String) async throws -> String
    ) async -> String? {
        guard let snapshotHex else { return nil }

        do {
            try await validateSnapshot(snapshotHex, publicKey: publicKey, recipient: recipient)
            return snapshotHex
        } catch {
            Logger.warn(
                "Dropping private Paykit snapshot with mismatched recipient for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)",
                context: "PrivatePaykit"
            )
            return nil
        }
    }

    static func storedPaymentEntries(from endpoints: [String: String]) -> [StoredPaymentEntry] {
        endpoints
            .sorted { $0.key < $1.key }
            .map { StoredPaymentEntry(methodId: $0.key, endpointData: $0.value) }
    }
}
