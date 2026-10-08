import Foundation

// MARK: - State

extension PrivatePaykitService {
    func closeAndClear() async {
        invalidateContactPreparation()
        unavailableLinkRetryAt.removeAll()
        pendingMessageDrainRetryTask?.cancel()
        pendingMessageDrainRetryTask = nil
        pendingMessageDrainRetryKeys.removeAll()
        pendingMessageDrainRetryGeneration += 1
        privatePaymentListConsumptions.removeAll()
        state = PrivatePaykitState(contacts: [:])
        knownSavedContactKeys.removeAll()
        await PaykitSdkService.shared.clearState()
        persistState(markWalletBackup: true)
        Self.setContactSharingCleanupPending(false)
        Self.clearDeletedContactCleanupPending()
    }

    func clearContactState(publicKey: String) async {
        await clearContactStates(publicKeys: [publicKey])
    }

    func clearContactStates(publicKeys: [String]) async {
        let keys = Set(publicKeys.compactMap(PubkyPublicKeyFormat.normalized))
        guard !keys.isEmpty else { return }
        privatePaymentListConsumptions = privatePaymentListConsumptions.filter { !keys.contains($0.key.publicKey) }
        for key in keys {
            unavailableLinkRetryAt[key] = nil
            let consumedVersion = state.contacts[key]?.consumedPrivatePaymentListVersion
            if consumedVersion == nil {
                state.contacts[key] = nil
            } else {
                var contactState = ContactState()
                contactState.consumedPrivatePaymentListVersion = consumedVersion
                state.contacts[key] = contactState
            }
        }
        await PrivatePaykitAddressReservationStore.shared.clearContactAssignments(publicKeys: Array(keys))
        persistState(markWalletBackup: true)
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
