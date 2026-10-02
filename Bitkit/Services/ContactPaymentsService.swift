import Foundation

enum ContactPaymentsService {
    static let confirmedPreferenceKey = "hasConfirmedPublicPaykitEndpoints"

    /// True while the Pubky session a contact payments change started for is still the current one.
    typealias SessionCheck = @MainActor () -> Bool

    struct Operations {
        let syncPublicEndpoints: (_ publish: Bool, _ isSessionCurrent: @escaping SessionCheck) async throws -> Void
        let preparePrivateEndpoints: (
            _ contactPublicKeys: [String],
            _ requireImmediatePublication: Bool,
            _ isSessionCurrent: @escaping SessionCheck
        ) async -> Error?
        let removePrivateEndpoints: () async throws -> Void
        let setPublicCleanupPending: (_ isPending: Bool) -> Void
        let setPrivateCleanupPending: (_ isPending: Bool) -> Void

        @MainActor
        static func live(wallet: WalletViewModel) -> Operations {
            Operations(
                syncPublicEndpoints: { publish, isSessionCurrent in
                    try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: publish, isSessionCurrent: isSessionCurrent)
                },
                preparePrivateEndpoints: { contactPublicKeys, requireImmediatePublication, isSessionCurrent in
                    await PrivatePaykitService.shared.prepareSavedContacts(
                        contactPublicKeys,
                        wallet: wallet,
                        requireImmediatePublication: requireImmediatePublication,
                        isSessionCurrent: isSessionCurrent
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

    /// Turns contact payments on or off for the signed-in Pubky session. Private endpoints are prepared for the saved
    /// contacts, so it first waits for the first contacts load. Once that session ends or changes, the change stops and
    /// returns quietly: it writes no preference, publishing flag or cleared cleanup mark, and its endpoint publications
    /// check the session under the locks that sign-out's endpoint removal also takes, so they never write endpoints back
    /// after that removal.
    @MainActor
    static func setEnabled(
        _ enabled: Bool,
        pubkyProfile: PubkyProfileManager,
        contactsManager: ContactsManager,
        operations: Operations,
        defaults: UserDefaults = .standard
    ) async throws {
        guard let session = pubkyProfile.currentSession else { return }
        let isSessionCurrent: SessionCheck = { pubkyProfile.currentSession == session }
        let canUsePrivatePayments = pubkyProfile.hasLocalSecretKeyForCurrentProfile
        if canUsePrivatePayments {
            do {
                try await contactsManager.loadContactsIfNeeded(for: session.publicKey)
            } catch {
                guard isSessionCurrent() else { return }
                throw error
            }
        }
        guard isSessionCurrent() else { return }

        do {
            try await setEnabled(
                enabled,
                contactPublicKeys: contactsManager.contacts.map(\.publicKey),
                canUsePrivatePayments: canUsePrivatePayments,
                operations: operations,
                defaults: defaults,
                isSessionCurrent: isSessionCurrent
            )
        } catch {
            guard isSessionCurrent() else { return }
            throw error
        }
    }

    /// Once `isSessionCurrent` is false, the preference, flags and cleanup marks belong to the sign-out or other session
    /// change that started, so it is checked right before each write here, with nothing suspending in between, and the
    /// endpoint publications check it again under their locks.
    @MainActor
    static func setEnabled(
        _ enabled: Bool,
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        operations: Operations,
        defaults: UserDefaults = .standard,
        isSessionCurrent: @escaping SessionCheck = { true }
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
                    defaults: defaults,
                    isSessionCurrent: isSessionCurrent
                )
            } else {
                try await disable(operations: operations, defaults: defaults, isSessionCurrent: isSessionCurrent)
            }
        } catch {
            await restore(
                previousState,
                contactPublicKeys: contactPublicKeys,
                canUsePrivatePayments: canUsePrivatePayments,
                operations: operations,
                defaults: defaults,
                isSessionCurrent: isSessionCurrent
            )
            throw error
        }
    }

    @MainActor
    private static func enable(
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        operations: Operations,
        defaults: UserDefaults,
        isSessionCurrent: @escaping SessionCheck
    ) async throws {
        guard isSessionCurrent() else { return }
        if !canUsePrivatePayments, defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey) {
            operations.setPrivateCleanupPending(true)
        }
        defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(canUsePrivatePayments, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)

        if canUsePrivatePayments,
           let error = await operations.preparePrivateEndpoints(
               contactPublicKeys,
               true,
               isSessionCurrent
           )
        {
            throw error
        }

        try await operations.syncPublicEndpoints(true, isSessionCurrent)

        guard isSessionCurrent() else { return }
        operations.setPublicCleanupPending(false)
        if canUsePrivatePayments {
            operations.setPrivateCleanupPending(false)
        }
    }

    @MainActor
    private static func disable(operations: Operations, defaults: UserDefaults, isSessionCurrent: @escaping SessionCheck) async throws {
        do {
            try await operations.removePrivateEndpoints()
            if isSessionCurrent() {
                operations.setPrivateCleanupPending(false)
            }
        } catch {
            operations.setPrivateCleanupPending(true)
            Logger.warn(
                "Deferred private Paykit endpoint cleanup after disable failed: \(error)",
                context: "ContactPaymentsService"
            )
        }

        do {
            try await operations.syncPublicEndpoints(false, isSessionCurrent)
            if isSessionCurrent() {
                operations.setPublicCleanupPending(false)
            }
        } catch {
            operations.setPublicCleanupPending(true)
            throw error
        }

        guard isSessionCurrent() else { return }
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(true, forKey: confirmedPreferenceKey)
    }

    @MainActor
    private static func restore(
        _ state: StoredState,
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        operations: Operations,
        defaults: UserDefaults,
        isSessionCurrent: @escaping SessionCheck
    ) async {
        guard isSessionCurrent() else { return }
        let restoresPrivateEndpoints = state.sharesPrivateEndpoints && canUsePrivatePayments
        defaults.set(state.sharesPublicEndpoints, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(restoresPrivateEndpoints, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(state.hasConfirmedPreference, forKey: confirmedPreferenceKey)

        do {
            try await operations.syncPublicEndpoints(state.sharesPublicEndpoints, isSessionCurrent)
            if isSessionCurrent() {
                operations.setPublicCleanupPending(state.publicCleanupPending)
            }
        } catch {
            operations.setPublicCleanupPending(true)
            Logger.warn("Failed to restore public contact payments: \(error)", context: "ContactPaymentsService")
        }

        if restoresPrivateEndpoints {
            if let error = await operations.preparePrivateEndpoints(
                contactPublicKeys,
                true,
                isSessionCurrent
            ) {
                operations.setPrivateCleanupPending(true)
                Logger.warn("Failed to restore private contact payments: \(error)", context: "ContactPaymentsService")
            } else if isSessionCurrent() {
                operations.setPrivateCleanupPending(state.privateCleanupPending)
            }
        } else {
            do {
                try await operations.removePrivateEndpoints()
                if isSessionCurrent() {
                    operations.setPrivateCleanupPending(state.privateCleanupPending)
                }
            } catch {
                operations.setPrivateCleanupPending(true)
                Logger.warn("Failed to clean up private contact payments: \(error)", context: "ContactPaymentsService")
            }
        }
    }
}
