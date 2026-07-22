import Foundation

// MARK: - Backup

extension PrivatePaykitService {
    func backupSnapshot() async throws -> String? {
        guard await PubkyService.currentPublicKey() != nil else {
            return nil
        }
        let backup = try await Backup(
            sdkState: PaykitSdkService.shared.exportBackupState(),
            consumedPrivatePaymentListVersions: state.contacts.compactMapValues { contactState in
                contactState.consumedPrivatePaymentListVersionsByReceiverPath.isEmpty
                    ? nil
                    : contactState.consumedPrivatePaymentListVersionsByReceiverPath
            }
        )
        let data = try JSONEncoder().encode(backup)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return encoded
    }

    func restoreBackup(_ backup: String?) async throws {
        pendingMessageDrainRetryTask?.cancel()
        pendingMessageDrainRetryTask = nil
        pendingMessageDrainRetryKeys.removeAll()
        pendingMessageDrainRetryGeneration += 1
        state = PrivatePaykitState(contacts: [:])
        knownSavedContactKeys.removeAll()
        if let backup {
            let decoded = try JSONDecoder().decode(Backup.self, from: Data(backup.utf8))
            try await PaykitSdkService.shared.restoreBackupState(decoded.sdkState)
            for (publicKey, versions) in decoded.consumedPrivatePaymentListVersions {
                state.contacts[publicKey, default: ContactState()].consumedPrivatePaymentListVersionsByReceiverPath = versions
            }
        } else {
            await PaykitSdkService.shared.clearState()
        }
        Self.setContactSharingCleanupPending(false)
        Self.clearDeletedContactCleanupPending()
        persistState(markWalletBackup: true)
    }
}
