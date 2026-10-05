import Foundation

enum ContactPaymentsService {
    static let confirmedPreferenceKey = "hasConfirmedPublicPaykitEndpoints"

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

    /// Turns contact payments on or off for the signed-in Pubky session. Private endpoints are prepared for the saved
    /// contacts, so it first waits for the first contacts load. The latest change wins: a change from General Settings or
    /// Pay Contacts can outlive its screen, so a newer one can start while it still runs. Once a newer change starts, or
    /// that session ends or changes, the change stops and returns quietly: it writes no preference, publishing flag or
    /// cleanup mark and restores nothing, and its endpoint publications and removals check that it is still current under
    /// the locks that the newer change's endpoint writes and sign-out's endpoint removal also take, so they never land
    /// after those. Returns true once the change was applied, and false when it stopped.
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
        if canUsePrivatePayments {
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
        // The change above stops quietly once it is no longer current, and it never becomes current again, so this also
        // reports that stop.
        return isChangeCurrent()
    }

    /// Once `isChangeCurrent` is false, the preference, flags and cleanup marks belong to the newer change or the session
    /// change that started, so it is checked right before each write here, with nothing suspending in between, and the
    /// endpoint publications and removals check it again under their locks.
    @MainActor
    static func setEnabled(
        _ enabled: Bool,
        contactPublicKeys: [String],
        canUsePrivatePayments: Bool,
        operations: Operations,
        defaults: UserDefaults = .standard,
        isChangeCurrent: @escaping ChangeCheck = { true }
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
                    isChangeCurrent: isChangeCurrent
                )
            } else {
                try await disable(operations: operations, defaults: defaults, isChangeCurrent: isChangeCurrent)
            }
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

        if canUsePrivatePayments,
           let error = await operations.preparePrivateEndpoints(
               contactPublicKeys,
               true,
               isChangeCurrent
           )
        {
            throw error
        }

        try await operations.syncPublicEndpoints(true, isChangeCurrent)

        guard isChangeCurrent() else { return }
        operations.setPublicCleanupPending(false)
        if canUsePrivatePayments {
            operations.setPrivateCleanupPending(false)
        }
    }

    @MainActor
    private static func disable(operations: Operations, defaults: UserDefaults, isChangeCurrent: @escaping ChangeCheck) async throws {
        do {
            try await operations.removePrivateEndpoints(isChangeCurrent)
            if isChangeCurrent() {
                operations.setPrivateCleanupPending(false)
            }
        } catch {
            if isChangeCurrent() {
                operations.setPrivateCleanupPending(true)
                Logger.warn(
                    "Deferred private Paykit endpoint cleanup after disable failed: \(error)",
                    context: "ContactPaymentsService"
                )
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
            }
            throw error
        }

        guard isChangeCurrent() else { return }
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
        isChangeCurrent: @escaping ChangeCheck
    ) async {
        guard isChangeCurrent() else { return }
        let restoresPrivateEndpoints = state.sharesPrivateEndpoints && canUsePrivatePayments
        defaults.set(state.sharesPublicEndpoints, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(restoresPrivateEndpoints, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(state.hasConfirmedPreference, forKey: confirmedPreferenceKey)

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
                true,
                isChangeCurrent
            ) {
                if isChangeCurrent() {
                    operations.setPrivateCleanupPending(true)
                    Logger.warn("Failed to restore private contact payments: \(error)", context: "ContactPaymentsService")
                }
            } else if isChangeCurrent() {
                operations.setPrivateCleanupPending(state.privateCleanupPending)
            }
        } else {
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
    }
}
