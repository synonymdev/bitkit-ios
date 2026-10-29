import Foundation

// MARK: - Backup

extension PrivatePaykitService {
    func backupSnapshot() async throws -> (state: String?, sdkVersion: UInt64) {
        let initialSdkVersion = await PaykitSdkService.shared.backupStateVersion
        guard try await PaykitSdkService.shared.currentPublicKey() != nil else {
            return (nil, initialSdkVersion)
        }
        // Wallet backups may be required before broadcast; they cannot wait for payment to finish.
        let exported = try await PaykitSdkService.shared.exportBackupSnapshot(priority: .interactive)
        let backup = Backup(
            sdkState: exported.state,
            consumedPrivatePaymentListVersions: state.contacts.compactMapValues { contactState in
                contactState.consumedPrivatePaymentListVersion
            },
            consumedPrivatePaymentListOwners: state.contacts.compactMapValues { contactState in
                contactState.consumedPrivatePaymentListVersion == nil ? nil : contactState.consumedPrivatePaymentListOwner
            }
        )
        let data = try JSONEncoder().encode(backup)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return (encoded, exported.version)
    }

    func restoreBackup(_ backup: String?) async throws {
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
                state.contacts[publicKey]?.consumedPrivatePaymentListOwner = decoded.consumedPrivatePaymentListOwners?[publicKey]
            }
        } else {
            await PaykitSdkService.shared.clearState()
        }
        Self.setContactSharingCleanupPending(false)
        Self.clearDeletedContactCleanupPending()
        persistState(markWalletBackup: true)
    }
}
