import Foundation

enum ContactPaymentsService {
    static let confirmedPreferenceKey = "hasConfirmedPublicPaykitEndpoints"

    struct Operations {
        let syncPublicEndpoints: (_ publish: Bool) async throws -> Void
        let preparePrivateEndpoints: (_ contactPublicKeys: [String], _ requireImmediatePublication: Bool) async -> Error?
        let removePrivateEndpoints: () async throws -> Void
        let setPublicCleanupPending: (_ isPending: Bool) -> Void
        let setPrivateCleanupPending: (_ isPending: Bool) -> Void

        @MainActor
        static func live(wallet: WalletViewModel) -> Operations {
            Operations(
                syncPublicEndpoints: { publish in
                    try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: publish)
                },
                preparePrivateEndpoints: { contactPublicKeys, requireImmediatePublication in
                    await PrivatePaykitService.shared.prepareSavedContacts(
                        contactPublicKeys,
                        wallet: wallet,
                        requireImmediatePublication: requireImmediatePublication
                    )
                },
                removePrivateEndpoints: {
                    try await PrivatePaykitService.shared.removePublishedEndpoints()
                },
                setPublicCleanupPending: PublicPaykitService.setCleanupPending,
                setPrivateCleanupPending: PrivatePaykitService.setContactSharingCleanupPending
            )
        }
    }

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
        try await setEnabled(
            enabled,
            contactPublicKeys: contactPublicKeys,
            canUsePrivatePayments: canUsePrivatePayments,
            operations: .live(wallet: wallet),
            defaults: defaults
        )
    }

    @MainActor
    static func setEnabled(
        _ enabled: Bool,
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        operations: Operations,
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
                    contactPublicKeys: contactPublicKeys,
                    canUsePrivatePayments: canUsePrivatePayments,
                    operations: operations,
                    defaults: defaults
                )
            } else {
                try await disable(operations: operations, defaults: defaults)
            }
        } catch {
            await restore(
                previousState,
                contactPublicKeys: contactPublicKeys,
                canUsePrivatePayments: canUsePrivatePayments,
                operations: operations,
                defaults: defaults
            )
            throw error
        }
    }

    @MainActor
    private static func enable(
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        operations: Operations,
        defaults: UserDefaults
    ) async throws {
        try await operations.syncPublicEndpoints(true)

        defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(canUsePrivatePayments, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)

        if canUsePrivatePayments,
           let error = await operations.preparePrivateEndpoints(
               contactPublicKeys,
               true
           )
        {
            throw error
        }

        operations.setPublicCleanupPending(false)
        operations.setPrivateCleanupPending(false)
    }

    @MainActor
    private static func disable(operations: Operations, defaults: UserDefaults) async throws {
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)

        var firstError: Error?
        do {
            try await operations.syncPublicEndpoints(false)
            operations.setPublicCleanupPending(false)
        } catch {
            firstError = error
            operations.setPublicCleanupPending(true)
        }

        do {
            try await operations.removePrivateEndpoints()
            operations.setPrivateCleanupPending(false)
        } catch {
            firstError = firstError ?? error
            operations.setPrivateCleanupPending(true)
        }

        if let firstError {
            throw firstError
        }
    }

    @MainActor
    private static func restore(
        _ state: StoredState,
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        operations: Operations,
        defaults: UserDefaults
    ) async {
        let restoresPrivateEndpoints = state.sharesPrivateEndpoints && canUsePrivatePayments
        defaults.set(state.sharesPublicEndpoints, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(restoresPrivateEndpoints, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(state.hasConfirmedPreference, forKey: confirmedPreferenceKey)

        do {
            try await operations.syncPublicEndpoints(state.sharesPublicEndpoints)
            operations.setPublicCleanupPending(state.publicCleanupPending)
        } catch {
            operations.setPublicCleanupPending(true)
            Logger.warn("Failed to restore public contact payments: \(error)", context: "ContactPaymentsService")
        }

        if restoresPrivateEndpoints {
            if let error = await operations.preparePrivateEndpoints(
                contactPublicKeys,
                true
            ) {
                operations.setPrivateCleanupPending(true)
                Logger.warn("Failed to restore private contact payments: \(error)", context: "ContactPaymentsService")
            } else {
                operations.setPrivateCleanupPending(state.privateCleanupPending)
            }
        } else {
            do {
                try await operations.removePrivateEndpoints()
                operations.setPrivateCleanupPending(state.privateCleanupPending)
            } catch {
                operations.setPrivateCleanupPending(true)
                Logger.warn("Failed to clean up private contact payments: \(error)", context: "ContactPaymentsService")
            }
        }
    }
}
