import Foundation

// MARK: - Backup

extension PrivatePaykitService {
    func backupSnapshot() async throws -> String? {
        guard try await PaykitSdkService.shared.currentPublicKey() != nil else {
            return nil
        }
        let backup = try await Backup(
            sdkState: PaykitSdkService.shared.exportBackupState(),
            consumedPrivatePaymentListVersions: state.contacts.compactMapValues { contactState in
                contactState.consumedPrivatePaymentListVersion
            }
        )
        let data = try JSONEncoder().encode(backup)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return encoded
    }

    func restoreBackup(_ backup: String?) async throws {
        invalidateContactPreparation()
        unavailableLinkRetryAt.removeAll()
        let decoded = try backup.map { try JSONDecoder().decode(Backup.self, from: Data($0.utf8)) }
        if let decoded {
            // Wallet restore must not rewind the identity's live state or Noise counters.
            try Keychain.upsert(key: .paykitRecoveryBackup, data: Data(decoded.sdkState.utf8))
        }
        pendingMessageDrainRetryTask?.cancel()
        pendingMessageDrainRetryTask = nil
        pendingMessageDrainRetryKeys.removeAll()
        pendingMessageDrainRetryGeneration += 1
        privatePaymentListConsumptions.removeAll()
        state = PrivatePaykitState(contacts: [:])
        knownSavedContactKeys.removeAll()
        if let decoded {
            for (publicKey, versions) in decoded.consumedPrivatePaymentListVersions {
                state.contacts[publicKey, default: ContactState()].consumedPrivatePaymentListVersion = versions
            }
        } else {
            await PaykitSdkService.shared.clearState()
        }
        Self.setContactSharingCleanupPending(false)
        Self.clearDeletedContactCleanupPending()
        persistState(markWalletBackup: true)
    }
}
