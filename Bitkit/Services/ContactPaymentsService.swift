import Foundation

enum ContactPaymentsService {
    static let confirmedPreferenceKey = "hasConfirmedPublicPaykitEndpoints"

    private struct StoredState {
        let sharesPublicEndpoints: Bool
        let sharesPrivateEndpoints: Bool
        let hasConfirmedPreference: Bool
        let publicCleanupPending: Bool
        let privateCleanupPending: Bool
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: confirmedPreferenceKey) else { return true }

        return defaults.bool(forKey: PublicPaykitService.publishingEnabledKey) ||
            defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey)
    }

    static func enableAllPaymentOptions(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        defaults.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
    }

    @MainActor
    static func setEnabled(
        _ enabled: Bool,
        wallet: WalletViewModel,
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        defaults: UserDefaults = .standard
    ) async throws {
        enableAllPaymentOptions(defaults: defaults)

        let previousState = StoredState(
            sharesPublicEndpoints: defaults.bool(forKey: PublicPaykitService.publishingEnabledKey),
            sharesPrivateEndpoints: defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey),
            hasConfirmedPreference: defaults.bool(forKey: confirmedPreferenceKey),
            publicCleanupPending: defaults.bool(forKey: PublicPaykitService.cleanupPendingKey),
            privateCleanupPending: defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey)
        )

        do {
            if enabled {
                try await enable(
                    wallet: wallet,
                    contactPublicKeys: contactPublicKeys,
                    canUsePrivatePayments: canUsePrivatePayments,
                    defaults: defaults
                )
            } else {
                try await disable(wallet: wallet, defaults: defaults)
            }
        } catch {
            await restore(
                previousState,
                wallet: wallet,
                contactPublicKeys: contactPublicKeys,
                canUsePrivatePayments: canUsePrivatePayments,
                defaults: defaults
            )
            throw error
        }
    }

    @MainActor
    private static func enable(
        wallet: WalletViewModel,
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        defaults: UserDefaults
    ) async throws {
        try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: true)

        defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(canUsePrivatePayments, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)

        if canUsePrivatePayments,
           let error = await PrivatePaykitService.shared.prepareSavedContacts(
               contactPublicKeys,
               wallet: wallet,
               requireImmediatePublication: true
           )
        {
            throw error
        }

        try await PublicPaykitService.syncLocalReceiverMarker(
            publicSharingEnabled: true,
            privateSharingEnabled: canUsePrivatePayments
        )
        PublicPaykitService.setCleanupPending(false)
        PrivatePaykitService.setContactSharingCleanupPending(false)
    }

    @MainActor
    private static func disable(wallet: WalletViewModel, defaults: UserDefaults) async throws {
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)

        var firstError: Error?
        do {
            try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: false)
            PublicPaykitService.setCleanupPending(false)
        } catch {
            firstError = error
            PublicPaykitService.setCleanupPending(true)
        }

        do {
            try await PrivatePaykitService.shared.removePublishedEndpoints()
            PrivatePaykitService.setContactSharingCleanupPending(false)
        } catch {
            firstError = firstError ?? error
            PrivatePaykitService.setContactSharingCleanupPending(true)
        }

        if let firstError {
            throw firstError
        }
    }

    @MainActor
    private static func restore(
        _ state: StoredState,
        wallet: WalletViewModel,
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        defaults: UserDefaults
    ) async {
        let restoresPrivateEndpoints = state.sharesPrivateEndpoints && canUsePrivatePayments
        defaults.set(state.sharesPublicEndpoints, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(restoresPrivateEndpoints, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(state.hasConfirmedPreference, forKey: confirmedPreferenceKey)

        do {
            try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: state.sharesPublicEndpoints)
            PublicPaykitService.setCleanupPending(state.publicCleanupPending)
        } catch {
            PublicPaykitService.setCleanupPending(true)
            Logger.warn("Failed to restore public contact payments: \(error)", context: "ContactPaymentsService")
        }

        if restoresPrivateEndpoints {
            if let error = await PrivatePaykitService.shared.prepareSavedContacts(
                contactPublicKeys,
                wallet: wallet,
                requireImmediatePublication: true
            ) {
                PrivatePaykitService.setContactSharingCleanupPending(true)
                Logger.warn("Failed to restore private contact payments: \(error)", context: "ContactPaymentsService")
            } else {
                PrivatePaykitService.setContactSharingCleanupPending(state.privateCleanupPending)
            }
        } else {
            do {
                try await PrivatePaykitService.shared.removePublishedEndpoints()
                PrivatePaykitService.setContactSharingCleanupPending(state.privateCleanupPending)
            } catch {
                PrivatePaykitService.setContactSharingCleanupPending(true)
                Logger.warn("Failed to clean up private contact payments: \(error)", context: "ContactPaymentsService")
            }
        }

        do {
            try await PublicPaykitService.syncLocalReceiverMarker(
                publicSharingEnabled: state.sharesPublicEndpoints,
                privateSharingEnabled: restoresPrivateEndpoints
            )
        } catch {
            PublicPaykitService.setCleanupPending(true)
            Logger.warn("Failed to restore the Paykit receiver marker: \(error)", context: "ContactPaymentsService")
        }
    }
}
