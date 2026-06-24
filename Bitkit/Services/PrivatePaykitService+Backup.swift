import Foundation

// MARK: - Backup

extension PrivatePaykitService {
    func backupSnapshot() async throws -> String? {
        guard await PubkyService.currentPublicKey() != nil else {
            return nil
        }
        return try await PaykitSdkService.shared.exportBackupState()
    }

    func restoreBackup(_ backup: String?) async throws {
        pendingMessageDrainRetryTask?.cancel()
        pendingMessageDrainRetryTask = nil
        state = PrivatePaykitState(contacts: [:])
        knownSavedContactKeys.removeAll()
        if let backup {
            try await PaykitSdkService.shared.restoreBackupState(backup)
        } else {
            await PaykitSdkService.shared.clearState()
        }
        Self.setContactSharingCleanupPending(false)
        Self.clearDeletedContactCleanupPending()
        persistState(markWalletBackup: true)
    }
}
