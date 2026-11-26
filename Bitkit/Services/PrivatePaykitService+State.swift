import Foundation

// MARK: - State

extension PrivatePaykitService {
    @discardableResult
    func closeAndClear() throws -> Data {
        let emptyState = PrivatePaykitState(contacts: [:])
        let encoded = try JSONEncoder().encode(emptyState)
        invalidateContactPreparation()
        unavailableLinkRetryAt.removeAll()
        privatePaymentListConsumptions.removeAll()
        state = emptyState
        knownSavedContactKeys.removeAll()
        UserDefaults.standard.set(encoded, forKey: Self.cacheStateKey)
        markWalletBackupDataChanged()
        Self.setContactSharingCleanupPending(false)
        Self.clearDeletedContactCleanupPending()
        return encoded
    }

    func validateWipedState() throws {
        guard state.contacts.isEmpty, privatePaymentListConsumptions.isEmpty,
              UserDefaults.standard.object(forKey: Self.cacheStateKey) == nil
        else { throw ProfileRemovalStore.StoreError.changed }
    }

    func validateRemovalState(_ encoded: Data) throws {
        guard state.contacts.isEmpty, privatePaymentListConsumptions.isEmpty,
              UserDefaults.standard.data(forKey: Self.cacheStateKey) == encoded
        else { throw ProfileRemovalStore.StoreError.changed }
    }

    func clearContactState(publicKey: String) async {
        await clearContactStates(publicKeys: [publicKey])
    }

    func clearContactStates(publicKeys: [String]) async {
        do { try await profileAdmission.withOperation {
            let keys = Set(publicKeys.compactMap(PubkyPublicKeyFormat.normalized))
            guard !keys.isEmpty else { return }
            await PrivatePaykitAddressReservationStore.shared.clearContactAssignments(publicKeys: Array(keys))
            try profileAdmission.checkCurrent()
            privatePaymentListConsumptions = privatePaymentListConsumptions.filter { !keys.contains($0.key.publicKey) }
            for key in keys {
                unavailableLinkRetryAt[key] = nil
                let consumedVersion = state.contacts[key]?.consumedPrivatePaymentListVersion
                if consumedVersion == nil {
                    state.contacts[key] = nil
                } else {
                    var contactState = ContactState()
                    contactState.consumedPrivatePaymentListVersion = consumedVersion
                    contactState.consumedPrivatePaymentListOwner = state.contacts[key]?.consumedPrivatePaymentListOwner
                    state.contacts[key] = contactState
                }
            }
            persistState(markWalletBackup: true)
        } } catch { Logger.debug("Contact state cleanup stopped: \(error)", context: "PrivatePaykit") }
    }

    func persistState(markWalletBackup: Bool = false) {
        do {
            try persistStateOrThrow(markWalletBackup: markWalletBackup)
        } catch {
            Logger.error("Failed to persist private Paykit cache state: \(error)", context: "PrivatePaykit")
        }
    }

    func persistStateOrThrow(markWalletBackup: Bool = false) throws {
        let data = try JSONEncoder().encode(state)
        UserDefaults.standard.set(data, forKey: Self.cacheStateKey)
        if markWalletBackup {
            markWalletBackupDataChanged()
        }
    }
}
