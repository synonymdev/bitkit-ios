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
        state.contacts[normalizedKey] = nil
        await PrivatePaykitAddressReservationStore.shared.clearContactAssignment(publicKey: normalizedKey)
        persistState(markWalletBackup: true)
    }

    func persistState(markWalletBackup: Bool = false) {
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: Self.cacheStateKey)
        } catch {
            Logger.error("Failed to persist private Paykit cache state: \(error)", context: "PrivatePaykit")
        }

        if markWalletBackup {
            markWalletBackupDataChanged()
        }
    }
}
