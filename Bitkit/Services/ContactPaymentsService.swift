import Foundation

enum ContactPaymentsService {
    static let confirmedPreferenceKey = "hasConfirmedPublicPaykitEndpoints"

    @MainActor private static var isOperationActive = false
    @MainActor private static var operationWaiters: [CheckedContinuation<Void, Never>] = []
    /// True while a contact payments change is still current: no newer change has started, and the Pubky session it
    /// started for is still the current one. Once false, it never turns true again.
    typealias ChangeCheck = @MainActor () -> Bool

    @MainActor private static var latestChange = 0
    @MainActor private static var latestPublicChange = 0

    struct Operations {
        let syncPublicEndpoints: (_ publish: Bool, _ isChangeCurrent: @escaping ChangeCheck) async throws -> Void
        let syncPrivateCapability: (_ enabled: Bool, _ isChangeCurrent: @escaping ChangeCheck) async throws -> Void
        var preparePrivateEndpoints: (
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
                    try await PublicPaykitService.syncPublishedEndpoints(
                        wallet: wallet,
                        publish: publish,
                        isSessionCurrent: isChangeCurrent,
                        appSyncPriority: publish ? .ordered : .interactive
                    )
                },
                syncPrivateCapability: { enabled, isChangeCurrent in
                    try await PublicPaykitService.withEndpointLock(unlessSessionEnded: isChangeCurrent) {
                        try await PublicPaykitService.syncPaykitApp(
                            privateSharingEnabled: enabled, priority: .interactive, isSessionCurrent: isChangeCurrent
                        )
                    }
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
        let sharesPrivateEndpoints: Bool
        let hasConfirmedPreference: Bool
        let privateCleanupPending: Bool
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: confirmedPreferenceKey) &&
            defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey)
    }

    static func enableAllPaymentOptions(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        defaults.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        defaults.set(true, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
    }

    /// Applies the latest private sharing preference for the current session. Enabling waits for saved contacts;
    /// disabling starts cleanup immediately. Returns false if superseded by another change or session.
    @discardableResult
    @MainActor
    static func setEnabled(
        _ enabled: Bool,
        pubkyProfile: PubkyProfileManager,
        contactsManager: ContactsManager,
        operations: Operations,
        defaults: UserDefaults = .standard,
        privatePaymentAccess: (String) throws -> Bool = { try PubkyProfileManager.hasPrivatePaymentAccess(for: $0) }
    ) async throws -> Bool {
        latestChange += 1
        let change = latestChange
        guard let session = pubkyProfile.currentSession else { return false }
        let isChangeCurrent: ChangeCheck = { Self.latestChange == change && pubkyProfile.currentSession == session }
        try Task.checkCancellation()
        let canUsePrivatePayments = enabled ? try privatePaymentAccess(session.publicKey) : false
        try Task.checkCancellation()
        if enabled, canUsePrivatePayments {
            do {
                try await contactsManager.loadContactsIfNeeded(for: session.publicKey)
            } catch {
                guard isChangeCurrent() else { return false }
                throw error
            }
        }
        guard isChangeCurrent() else { return false }

        var currentOperations = operations
        currentOperations.preparePrivateEndpoints = { @MainActor _, immediate, isCurrent in
            while !Task.isCancelled, isCurrent() {
                let snapshot = contactsManager.savedContactsSnapshot()
                let error = await operations.preparePrivateEndpoints(snapshot.publicKeys, immediate) {
                    isCurrent() && snapshot.isCurrent()
                }
                if snapshot.isCurrent() {
                    return error
                }
            }
            return Task.isCancelled && isCurrent() ? CancellationError() : nil
        }

        do {
            try await setEnabled(
                enabled,
                contactPublicKeys: contactsManager.contacts.map(\.publicKey),
                canUsePrivatePayments: canUsePrivatePayments,
                operations: currentOperations,
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

        if enabled, !canUsePrivatePayments {
            throw PrivatePaykitError.privateUnavailable
        }

        enableAllPaymentOptions(defaults: defaults)

        if !enabled {
            if let error = await disable(operations: operations, defaults: defaults, isChangeCurrent: isChangeCurrent) {
                throw error
            }
            return
        }

        let previousState = StoredState(
            sharesPrivateEndpoints: defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey),
            hasConfirmedPreference: defaults.bool(forKey: confirmedPreferenceKey),
            privateCleanupPending: defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey)
        )

        do {
            try await enable(
                contactPublicKeys: contactPublicKeys,
                operations: operations,
                defaults: defaults,
                isChangeCurrent: isChangeCurrent
            )
        } catch {
            await restore(
                previousState,
                contactPublicKeys: contactPublicKeys,
                operations: operations,
                defaults: defaults,
                isChangeCurrent: isChangeCurrent
            )
            throw error
        }
    }

    /// Public payment details are published only in response to an explicit public sharing choice.
    @discardableResult
    @MainActor
    static func setPublicEnabled(
        _ enabled: Bool,
        pubkyProfile: PubkyProfileManager,
        operations: Operations,
        defaults: UserDefaults = .standard
    ) async throws -> Bool {
        latestPublicChange += 1
        let change = latestPublicChange
        guard let session = pubkyProfile.currentSession else { return false }
        let isChangeCurrent: ChangeCheck = { Self.latestPublicChange == change && pubkyProfile.currentSession == session }
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard isChangeCurrent() else { return false }

        let wasEnabled = defaults.bool(forKey: PublicPaykitService.publishingEnabledKey)
        let wasCleanupPending = defaults.bool(forKey: PublicPaykitService.cleanupPendingKey)
        defaults.set(enabled, forKey: PublicPaykitService.publishingEnabledKey)
        operations.setPublicCleanupPending(true)
        do {
            try await operations.syncPublicEndpoints(enabled, isChangeCurrent)
            try Task.checkCancellation()
            guard isChangeCurrent() else { return false }
            if !enabled {
                operations.setPublicCleanupPending(false)
            }
        } catch {
            guard isChangeCurrent() else { return false }
            if enabled {
                defaults.set(wasEnabled, forKey: PublicPaykitService.publishingEnabledKey)
                operations.setPublicCleanupPending(true)
                do {
                    try await operations.syncPublicEndpoints(wasEnabled, isChangeCurrent)
                    try Task.checkCancellation()
                    if !wasEnabled, isChangeCurrent() {
                        operations.setPublicCleanupPending(wasCleanupPending)
                    }
                } catch {
                    if isChangeCurrent() {
                        operations.setPublicCleanupPending(true)
                        Logger.warn("Failed to restore public payments: \(error)", context: "ContactPaymentsService")
                    }
                }
            }
            guard isChangeCurrent() else { return false }
            throw error
        }
        return isChangeCurrent()
    }

    @MainActor
    static func disablePaykitUI(
        pubkyProfile: PubkyProfileManager,
        operations: Operations,
        defaults: UserDefaults = .standard
    ) async throws -> Bool {
        latestChange += 1
        latestPublicChange += 1
        let change = latestChange
        let publicChange = latestPublicChange
        let session = pubkyProfile.currentSession
        let isChangeCurrent: ChangeCheck = {
            Self.latestChange == change && Self.latestPublicChange == publicChange &&
                pubkyProfile.currentSession == session && !defaults.bool(forKey: PaykitFeatureFlags.uiEnabledKey)
        }
        let hadPublicState = PaykitFeatureFlags.hasPublicPublishedState(defaults: defaults) ||
            defaults.bool(forKey: PublicPaykitService.cleanupPendingKey)
        let hadPrivateState = PaykitFeatureFlags.hasPrivatePublishedState(defaults: defaults) ||
            defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey)

        defaults.set(false, forKey: PaykitFeatureFlags.uiEnabledKey)
        defaults.set(false, forKey: confirmedPreferenceKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.removeObject(forKey: "publicPaykitBolt11")
        defaults.removeObject(forKey: "publicPaykitBolt11PaymentHash")
        defaults.removeObject(forKey: "publicPaykitBolt11ExpiresAt")
        if hadPublicState {
            operations.setPublicCleanupPending(true)
        }
        if hadPrivateState {
            operations.setPrivateCleanupPending(true)
        }

        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard isChangeCurrent() else { return false }

        var cleanupError: Error?
        if hadPublicState || defaults.bool(forKey: PublicPaykitService.cleanupPendingKey) {
            operations.setPublicCleanupPending(true)
            do {
                try await operations.syncPublicEndpoints(false, isChangeCurrent)
                try Task.checkCancellation()
                guard isChangeCurrent() else { return false }
                operations.setPublicCleanupPending(false)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError {
                    throw error
                }
                guard isChangeCurrent() else { return false }
                cleanupError = error
            }
        }

        if hadPrivateState || defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey) {
            operations.setPrivateCleanupPending(true)
            do {
                try await operations.removePrivateEndpoints(isChangeCurrent)
                try Task.checkCancellation()
                guard isChangeCurrent() else { return false }
                operations.setPrivateCleanupPending(false)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError {
                    throw error
                }
                guard isChangeCurrent() else { return false }
                cleanupError = cleanupError ?? error
            }
        }
        if let cleanupError {
            throw cleanupError
        }
        return isChangeCurrent()
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
        operations: Operations,
        defaults: UserDefaults,
        isChangeCurrent: @escaping ChangeCheck
    ) async throws {
        guard isChangeCurrent() else { return }
        defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)

        try await operations.syncPrivateCapability(true, isChangeCurrent)
        try Task.checkCancellation()

        guard isChangeCurrent() else { return }
        operations.setPrivateCleanupPending(false)
        if let error = await operations.preparePrivateEndpoints(
            contactPublicKeys,
            false,
            isChangeCurrent
        ) {
            throw error
        }
        try Task.checkCancellation()
    }

    @MainActor
    private static func disable(operations: Operations, defaults: UserDefaults, isChangeCurrent: @escaping ChangeCheck) async -> Error? {
        guard isChangeCurrent() else { return nil }
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)
        operations.setPrivateCleanupPending(true)

        var cleanupError: Error?
        do {
            try await operations.removePrivateEndpoints(isChangeCurrent)
            try Task.checkCancellation()
        } catch {
            if isChangeCurrent() {
                cleanupError = error
            }
        }

        do {
            try await operations.syncPrivateCapability(false, isChangeCurrent)
            try Task.checkCancellation()
        } catch {
            if isChangeCurrent() {
                cleanupError = cleanupError ?? error
            }
        }
        if isChangeCurrent() {
            operations.setPrivateCleanupPending(cleanupError != nil)
            return cleanupError
        }
        return nil
    }

    @MainActor
    private static func restore(
        _ state: StoredState,
        contactPublicKeys: [String],
        operations: Operations,
        defaults: UserDefaults,
        isChangeCurrent: @escaping ChangeCheck
    ) async {
        guard isChangeCurrent() else { return }
        let restoresPrivateEndpoints = state.sharesPrivateEndpoints
        defaults.set(restoresPrivateEndpoints, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(state.hasConfirmedPreference, forKey: confirmedPreferenceKey)

        if !restoresPrivateEndpoints {
            operations.setPrivateCleanupPending(true)
            do {
                try await operations.removePrivateEndpoints(isChangeCurrent)
                try Task.checkCancellation()
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
            try await operations.syncPrivateCapability(restoresPrivateEndpoints, isChangeCurrent)
            try Task.checkCancellation()
        } catch {
            if isChangeCurrent() {
                operations.setPublicCleanupPending(true)
                Logger.warn("Failed to restore private payment capability: \(error)", context: "ContactPaymentsService")
            }
            return
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
