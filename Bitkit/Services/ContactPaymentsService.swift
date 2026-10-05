import Foundation

enum ContactPaymentsService {
    static let confirmedPreferenceKey = "hasConfirmedPublicPaykitEndpoints"

    @MainActor private static var isOperationActive = false
    @MainActor private static var operationWaiters: [CheckedContinuation<Void, Never>] = []

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
        defaults.bool(forKey: confirmedPreferenceKey) &&
            (defaults.bool(forKey: PublicPaykitService.publishingEnabledKey) ||
                defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
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
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        enableAllPaymentOptions(defaults: defaults)

        if !enabled {
            if let error = await disable(operations: operations, defaults: defaults) {
                throw error
            }
            return
        }

        let previousState = StoredState(
            sharesPublicEndpoints: defaults.bool(forKey: PublicPaykitService.publishingEnabledKey),
            sharesPrivateEndpoints: defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey),
            hasConfirmedPreference: defaults.bool(forKey: confirmedPreferenceKey),
            publicCleanupPending: defaults.bool(forKey: PublicPaykitService.cleanupPendingKey),
            privateCleanupPending: defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey)
        )

        do {
            try await enable(
                contactPublicKeys: contactPublicKeys,
                canUsePrivatePayments: canUsePrivatePayments,
                operations: operations,
                defaults: defaults
            )
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
    static func reconcilePendingEndpoints(_ reconcile: () async -> Void) async {
        guard !isOperationActive, !Task.isCancelled else { return }
        isOperationActive = true
        defer { releaseOperation() }
        await reconcile()
    }

    @MainActor
    private static func acquireOperation() async {
        guard isOperationActive else {
            isOperationActive = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    @MainActor
    private static func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            isOperationActive = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    @MainActor
    private static func enable(
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        operations: Operations,
        defaults: UserDefaults
    ) async throws {
        if !canUsePrivatePayments, defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey) {
            operations.setPrivateCleanupPending(true)
        }
        defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(canUsePrivatePayments, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)

        try await operations.syncPublicEndpoints(true)
        operations.setPublicCleanupPending(false)
        if canUsePrivatePayments {
            operations.setPrivateCleanupPending(false)
        }
        if canUsePrivatePayments,
           let error = await operations.preparePrivateEndpoints(
               contactPublicKeys,
               false
           )
        {
            throw error
        }
    }

    @MainActor
    private static func disable(operations: Operations, defaults: UserDefaults) async -> Error? {
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)
        operations.setPublicCleanupPending(true)
        operations.setPrivateCleanupPending(true)

        var cleanupError: Error?
        do {
            try await operations.removePrivateEndpoints()
            operations.setPrivateCleanupPending(false)
        } catch {
            operations.setPrivateCleanupPending(true)
            cleanupError = error
        }

        do {
            try await operations.syncPublicEndpoints(false)
            operations.setPublicCleanupPending(false)
        } catch {
            operations.setPublicCleanupPending(true)
            cleanupError = cleanupError ?? error
        }
        return cleanupError
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

        if !restoresPrivateEndpoints {
            do {
                try await operations.removePrivateEndpoints()
                operations.setPrivateCleanupPending(state.privateCleanupPending)
            } catch {
                operations.setPrivateCleanupPending(true)
                Logger.warn("Failed to clean up private contact payments: \(error)", context: "ContactPaymentsService")
            }
        }

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
                false
            ) {
                operations.setPrivateCleanupPending(true)
                Logger.warn("Failed to restore private contact payments: \(error)", context: "ContactPaymentsService")
            } else {
                operations.setPrivateCleanupPending(state.privateCleanupPending)
            }
        }
    }
}
