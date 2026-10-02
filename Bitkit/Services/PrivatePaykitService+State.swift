import Foundation

// MARK: - State

extension PrivatePaykitService {
    func closeAndClear() async {
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
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        privatePaymentListConsumptions = privatePaymentListConsumptions.filter { $0.key.publicKey != normalizedKey }
        let consumedVersion = state.contacts[normalizedKey]?.consumedPrivatePaymentListVersion
        if consumedVersion == nil {
            state.contacts[normalizedKey] = nil
        } else {
            var contactState = ContactState()
            contactState.consumedPrivatePaymentListVersion = consumedVersion
            state.contacts[normalizedKey] = contactState
        }
        await PrivatePaykitAddressReservationStore.shared.clearContactAssignment(publicKey: normalizedKey)
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
