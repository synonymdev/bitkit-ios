import Foundation

// MARK: - Backup

extension PrivatePaykitService {
    func backupSnapshot(
        sdkService: PaykitSdkService = .shared,
        hasStoredIdentity: @Sendable () throws -> Bool = { try PubkyProfileManager.hasStoredIdentityForBackup() }
    ) async throws -> (state: String?, sdkVersion: UInt64) {
        return try await profileAdmission.withOperation {
            let initialSdkVersion = await sdkService.backupStateVersion
            guard try await sdkService.currentPublicKey() != nil else {
                guard try !hasStoredIdentity() else { throw PubkyServiceError.sessionNotActive }
                return (nil, initialSdkVersion)
            }
            // Wallet backups may be required before broadcast; they cannot wait for payment to finish.
            let exported = try await sdkService.exportBackupSnapshot(priority: .interactive)
            let backup = Backup(
                sdkState: exported.state,
                consumedPrivatePaymentListVersions: state.contacts.compactMapValues { contactState in
                    contactState.consumedPrivatePaymentListVersion
                }
            )
            let data = try JSONEncoder().encode(backup)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return (encoded, exported.version)
        }
    }

    func restoreBackup(_ backup: String?) async throws {
        return try await profileAdmission.withOperation {
            invalidateContactPreparation()
            unavailableLinkRetryAt.removeAll()
            let decoded = try backup.map { try JSONDecoder().decode(Backup.self, from: Data($0.utf8)) }
            if let decoded {
                // Wallet restore must not rewind the identity's live state or Noise counters.
                try Keychain.upsert(key: .paykitRecoveryBackup, data: Data(decoded.sdkState.utf8))
            }
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
}
