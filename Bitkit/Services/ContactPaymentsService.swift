import Foundation

enum ContactPaymentsService {
    static let confirmedPreferenceKey = "hasConfirmedPublicPaykitEndpoints"

    @MainActor private static var isOperationActive = false
    @MainActor private static var operationWaiters: [CheckedContinuation<Void, Never>] = []
    /// True while a contact payments change is still current: no newer change has started, and the Pubky session it
    /// started for is still the current one. Once false, it never turns true again.
    typealias ChangeCheck = @MainActor () -> Bool

    @MainActor private static var latestChange = 0

    struct Operations {
        let syncPublicEndpoints: (_ publish: Bool, _ isChangeCurrent: @escaping ChangeCheck) async throws -> Void
        let preparePrivateEndpoints: (
            _ contactPublicKeys: [String],
            _ requireImmediatePublication: Bool,
            _ isChangeCurrent: @escaping ChangeCheck
        ) async -> Error?
        let removePrivateEndpoints: (_ isChangeCurrent: @escaping ChangeCheck) async throws -> Void
        let setPublicCleanupPending: (_ isPending: Bool) -> Void
        let setPrivateCleanupPending: (_ isPending: Bool) -> Void

        @MainActor
        static func live(wallet: WalletViewModel) -> Operations {
            Operations(
                syncPublicEndpoints: { publish, isChangeCurrent in
                    try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: publish, isSessionCurrent: isChangeCurrent)
                },
                preparePrivateEndpoints: { contactPublicKeys, requireImmediatePublication, isChangeCurrent in
                    await PrivatePaykitService.shared.prepareSavedContacts(
                        contactPublicKeys,
                        wallet: wallet,
                        requireImmediatePublication: requireImmediatePublication,
                        isSessionCurrent: isChangeCurrent
                    )
                },
                removePrivateEndpoints: { isChangeCurrent in
                    try await PrivatePaykitService.shared.removePublishedEndpoints(isSessionCurrent: isChangeCurrent)
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

    /// Applies the latest sharing preference for the current session. Enabling waits for saved contacts;
    /// disabling starts cleanup immediately. Returns false if superseded by another change or session.
    @discardableResult
    @MainActor
    static func setEnabled(
        _ enabled: Bool,
        pubkyProfile: PubkyProfileManager,
        contactsManager: ContactsManager,
        operations: Operations,
        defaults: UserDefaults = .standard
    ) async throws -> Bool {
        latestChange += 1
        let change = latestChange
        guard let session = pubkyProfile.currentSession else { return false }
        let isChangeCurrent: ChangeCheck = { Self.latestChange == change && pubkyProfile.currentSession == session }
        let canUsePrivatePayments = pubkyProfile.hasLocalSecretKeyForCurrentProfile
        if enabled, canUsePrivatePayments {
            do {
                try await contactsManager.loadContactsIfNeeded(for: session.publicKey)
            } catch {
                guard isChangeCurrent() else { return false }
                throw error
            }
        }
        guard isChangeCurrent() else { return false }

        do {
            try await setEnabled(
                enabled,
                contactPublicKeys: contactsManager.contacts.map(\.publicKey),
                canUsePrivatePayments: canUsePrivatePayments,
                operations: operations,
                defaults: defaults,
                isChangeCurrent: isChangeCurrent
            )
        } catch {
            guard isChangeCurrent() else { return false }
            throw error
        }
        return isChangeCurrent()
    }

    /// Serializes sharing changes. Endpoint operations recheck ownership under their publication locks.
    @MainActor
    static func setEnabled(
        _ enabled: Bool,
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        operations: Operations,
        defaults: UserDefaults = .standard,
        isChangeCurrent: @escaping ChangeCheck = { true }
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard isChangeCurrent() else { return }

        enableAllPaymentOptions(defaults: defaults)

        if !enabled {
            if let error = await disable(operations: operations, defaults: defaults, isChangeCurrent: isChangeCurrent) {
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
                defaults: defaults,
                isChangeCurrent: isChangeCurrent
            )
        } catch {
            await restore(
                previousState,
                contactPublicKeys: contactPublicKeys,
                canUsePrivatePayments: canUsePrivatePayments,
                operations: operations,
                defaults: defaults,
                isChangeCurrent: isChangeCurrent
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
        defaults: UserDefaults,
        isChangeCurrent: @escaping ChangeCheck
    ) async throws {
        guard isChangeCurrent() else { return }
        if !canUsePrivatePayments, defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey) {
            operations.setPrivateCleanupPending(true)
        }
        defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(canUsePrivatePayments, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)

        try await operations.syncPublicEndpoints(true, isChangeCurrent)

        guard isChangeCurrent() else { return }
        operations.setPublicCleanupPending(false)
        if canUsePrivatePayments {
            operations.setPrivateCleanupPending(false)
        }
        if canUsePrivatePayments,
           let error = await operations.preparePrivateEndpoints(
               contactPublicKeys,
               false,
               isChangeCurrent
           )
        {
            throw error
        }
    }

    @MainActor
    private static func disable(operations: Operations, defaults: UserDefaults, isChangeCurrent: @escaping ChangeCheck) async -> Error? {
        guard isChangeCurrent() else { return nil }
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)
        operations.setPublicCleanupPending(true)
        operations.setPrivateCleanupPending(true)

        var cleanupError: Error?
        do {
            try await operations.removePrivateEndpoints(isChangeCurrent)
            if isChangeCurrent() {
                operations.setPrivateCleanupPending(false)
            }
        } catch {
            if isChangeCurrent() {
                operations.setPrivateCleanupPending(true)
                cleanupError = error
            }
        }

        do {
            try await operations.syncPublicEndpoints(false, isChangeCurrent)
            if isChangeCurrent() {
                operations.setPublicCleanupPending(false)
            }
        } catch {
            if isChangeCurrent() {
                operations.setPublicCleanupPending(true)
                cleanupError = cleanupError ?? error
            }
        }
        return isChangeCurrent() ? cleanupError : nil
    }

    @MainActor
    private static func restore(
        _ state: StoredState,
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        operations: Operations,
        defaults: UserDefaults,
        isChangeCurrent: @escaping ChangeCheck
    ) async {
        guard isChangeCurrent() else { return }
        let restoresPrivateEndpoints = state.sharesPrivateEndpoints && canUsePrivatePayments
        defaults.set(state.sharesPublicEndpoints, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(restoresPrivateEndpoints, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(state.hasConfirmedPreference, forKey: confirmedPreferenceKey)

        if !restoresPrivateEndpoints {
            do {
                try await operations.removePrivateEndpoints(isChangeCurrent)
                if isChangeCurrent() {
                    operations.setPrivateCleanupPending(state.privateCleanupPending)
                }
            } catch {
                if isChangeCurrent() {
                    operations.setPrivateCleanupPending(true)
                    Logger.warn("Failed to clean up private contact payments: \(error)", context: "ContactPaymentsService")
                }
            }
        }

        do {
            try await operations.syncPublicEndpoints(state.sharesPublicEndpoints, isChangeCurrent)
            if isChangeCurrent() {
                operations.setPublicCleanupPending(state.publicCleanupPending)
            }
        } catch {
            if isChangeCurrent() {
                operations.setPublicCleanupPending(true)
                Logger.warn("Failed to restore public contact payments: \(error)", context: "ContactPaymentsService")
            }
        }

        if restoresPrivateEndpoints {
            if let error = await operations.preparePrivateEndpoints(
                contactPublicKeys,
                false,
                isChangeCurrent
            ) {
                if isChangeCurrent() {
                    operations.setPrivateCleanupPending(true)
                    Logger.warn("Failed to restore private contact payments: \(error)", context: "ContactPaymentsService")
                }
            } else if isChangeCurrent() {
                operations.setPrivateCleanupPending(state.privateCleanupPending)
            }
        }
    }
}
