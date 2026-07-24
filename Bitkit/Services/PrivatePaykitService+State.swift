import Foundation

// MARK: - State

extension PrivatePaykitService {
    func closeAndClear() async {
        pendingMessageDrainRetryTask?.cancel()
        pendingMessageDrainRetryTask = nil
        pendingMessageDrainRetryKeys.removeAll()
        pendingMessageDrainRetryGeneration += 1
        state = PrivatePaykitState(contacts: [:])
        knownSavedContactKeys.removeAll()
        await PaykitSdkService.shared.clearState()
        persistState(markWalletBackup: true)
        Self.setContactSharingCleanupPending(false)
        Self.clearDeletedContactCleanupPending()
    }

    func clearContactState(publicKey: String) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        let consumedVersions = state.contacts[normalizedKey]?.consumedPrivatePaymentListVersionsByReceiverPath ?? [:]
        if consumedVersions.isEmpty {
            state.contacts[normalizedKey] = nil
        } else {
            var contactState = ContactState()
            contactState.consumedPrivatePaymentListVersionsByReceiverPath = consumedVersions
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
