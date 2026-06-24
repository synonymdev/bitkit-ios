import Foundation
import Paykit

// MARK: - Saved Contacts

extension PrivatePaykitService {
    @discardableResult
    func prepareSavedContacts(
        _ publicKeys: [String],
        wallet: WalletViewModel,
        requireImmediatePublication: Bool = false
    ) async -> Error? {
        let publicKeys = rememberSavedContacts(publicKeys, replacing: true)
        guard await canPublishPrivateEndpoints(wallet: wallet) else {
            return requireImmediatePublication && !publicKeys.isEmpty ? PrivatePaykitError.privateUnavailable : nil
        }

        await PrivatePaykitAddressReservationStore.shared.reconcileReservedIndexesWithLdk()

        return await syncLocalEndpointPublication(
            for: publicKeys,
            wallet: wallet,
            reason: "prepare",
            requireImmediatePublication: requireImmediatePublication
        )
    }

    func refreshSavedContactEndpoints(for publicKeys: [String], wallet: WalletViewModel, forceRefreshLightning: Bool = false) async {
        _ = await refreshSavedContactEndpointsReturningError(
            for: publicKeys,
            wallet: wallet,
            forceRefreshLightning: forceRefreshLightning,
            requireImmediatePublication: false
        )
    }

    func refreshKnownSavedContactEndpoints(wallet: WalletViewModel, reason: String, forceRefreshLightning: Bool = false) async {
        let publicKeys = Array(knownSavedContactKeys)
        guard !publicKeys.isEmpty else { return }

        _ = await refreshSavedContactEndpointsReturningError(
            for: publicKeys,
            wallet: wallet,
            forceRefreshLightning: forceRefreshLightning,
            requireImmediatePublication: false,
            reason: reason
        )
    }

    @discardableResult
    func refreshSavedContactEndpointsReturningError(
        for publicKeys: [String],
        wallet: WalletViewModel,
        forceRefreshLightning: Bool,
        requireImmediatePublication: Bool,
        reason: String = "refresh"
    ) async -> Error? {
        guard await canPublishPrivateEndpoints(wallet: wallet) else {
            return requireImmediatePublication && !publicKeys.isEmpty ? PrivatePaykitError.privateUnavailable : nil
        }

        return await syncLocalEndpointPublication(
            for: publicKeys,
            wallet: wallet,
            reason: reason,
            forceRefreshLightning: forceRefreshLightning,
            requireImmediatePublication: requireImmediatePublication
        )
    }

    func removePublishedEndpoints() async throws {
        let publicKeys = Set(knownSavedContactKeys)
            .union(state.contacts.keys)
            .union(Self.pendingDeletedContactCleanupKeys())
        try await removePublishedEndpoints(for: Array(publicKeys))
    }

    func removePublishedEndpoints(for publicKeys: [String]) async throws {
        var firstError: Error?
        for publicKey in normalizedSavedContactKeys(publicKeys) {
            do {
                let report = try await PaykitSdkService.shared.clearPrivatePaymentList(to: publicKey)
                if !report.failedToQueue.isEmpty || !report.failedToDeliver.isEmpty {
                    throw PrivatePaykitError.privateUnavailable
                }
                if var contactState = state.contacts[publicKey] {
                    contactState.cachedResolvedEndpoints = []
                    contactState.localInvoice = nil
                    contactState.hasPublishedPrivatePaymentList = false
                    state.contacts[publicKey] = contactState.hasCacheState ? contactState : nil
                }
                Self.clearDeletedContactCleanupPending([publicKey])
                persistState(markWalletBackup: true)
            } catch {
                firstError = firstError ?? error
                Self.markDeletedContactCleanupPending([publicKey])
            }
        }

        if let firstError {
            throw firstError
        }
    }

    func removeSavedContact(publicKey: String) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        knownSavedContactKeys.remove(normalizedKey)
        do {
            try await removePublishedEndpoints(for: [normalizedKey])
            await clearContactState(publicKey: normalizedKey)
        } catch {
            Logger.warn(
                "Failed to remove private Paykit endpoints for deleted contact \(PubkyPublicKeyFormat.redacted(normalizedKey)): \(error)",
                context: "PrivatePaykit"
            )
        }
    }

    func removeSavedContacts(publicKeys: [String]) async {
        let normalizedKeys = normalizedSavedContactKeys(publicKeys)
        for publicKey in normalizedKeys {
            knownSavedContactKeys.remove(publicKey)
        }
        do {
            try await removePublishedEndpoints(for: normalizedKeys)
            for publicKey in normalizedKeys {
                await clearContactState(publicKey: publicKey)
            }
        } catch {
            Logger.warn("Failed to remove private Paykit endpoints for deleted contacts: \(error)", context: "PrivatePaykit")
        }
    }

    func pruneUnsavedContactState(savedPublicKeys publicKeys: [String]) async {
        let savedKeys = Set(normalizedSavedContactKeys(publicKeys))
        knownSavedContactKeys = savedKeys

        let staleKeys = Set(state.contacts.keys).subtracting(savedKeys)
        let cleanupKeys = staleKeys.union(Self.pendingDeletedContactCleanupKeys().subtracting(savedKeys))
        guard !cleanupKeys.isEmpty else { return }

        do {
            try await removePublishedEndpoints(for: Array(cleanupKeys))
            for publicKey in staleKeys {
                await clearContactState(publicKey: publicKey)
            }
        } catch {
            Logger.warn("Failed to prune private Paykit endpoints for unsaved contacts: \(error)", context: "PrivatePaykit")
        }
    }

    func retryPendingEndpointRemoval(wallet _: WalletViewModel, savedPublicKeys publicKeys: [String]) async {
        let savedKeys = Set(normalizedSavedContactKeys(publicKeys))
        let isFullCleanupPending = UserDefaults.standard.bool(forKey: Self.cleanupPendingKey)
        let cleanupKeys = isFullCleanupPending
            ? Set(knownSavedContactKeys).union(state.contacts.keys).union(Self.pendingDeletedContactCleanupKeys())
            : Set(pendingPrivateEndpointRemovalKeys(savedPublicKeys: publicKeys))

        guard !cleanupKeys.isEmpty else {
            if isFullCleanupPending {
                Self.setContactSharingCleanupPending(false)
            }
            return
        }

        do {
            try await removePublishedEndpoints(for: Array(cleanupKeys))
            for publicKey in cleanupKeys where !savedKeys.contains(publicKey) {
                await clearContactState(publicKey: publicKey)
            }
            if isFullCleanupPending {
                Self.setContactSharingCleanupPending(false)
            }
        } catch {
            Logger.warn("Failed to retry private Paykit endpoint cleanup: \(error)", context: "PrivatePaykit")
        }
    }

    func pendingPrivateEndpointRemovalKeys(savedPublicKeys publicKeys: [String]) -> [String] {
        let savedKeys = Set(normalizedSavedContactKeys(publicKeys))
        return Array(Self.pendingDeletedContactCleanupKeys().subtracting(savedKeys)).sorted()
    }

    func clearUnsavedContactState(savedPublicKeys publicKeys: [String]) async {
        await pruneUnsavedContactState(savedPublicKeys: publicKeys)
    }

    func publishLocalEndpoints(
        for publicKey: String,
        wallet: WalletViewModel,
        forceRefreshLightning: Bool = false
    ) async throws {
        if let error = await syncLocalEndpointPublication(
            for: [publicKey],
            wallet: wallet,
            reason: "publish",
            forceRefreshLightning: forceRefreshLightning,
            requireImmediatePublication: true
        ) {
            throw error
        }
    }

    private func syncLocalEndpointPublication(
        for publicKeys: [String],
        wallet: WalletViewModel,
        reason: String,
        forceRefreshLightning: Bool = false,
        requireImmediatePublication: Bool
    ) async -> Error? {
        do {
            return try await withPublicationLock {
                await syncLocalEndpointPublicationLocked(
                    for: publicKeys,
                    wallet: wallet,
                    reason: reason,
                    forceRefreshLightning: forceRefreshLightning,
                    requireImmediatePublication: requireImmediatePublication
                )
            }
        } catch {
            return requireImmediatePublication ? error : nil
        }
    }

    private func syncLocalEndpointPublicationLocked(
        for publicKeys: [String],
        wallet: WalletViewModel,
        reason: String,
        forceRefreshLightning: Bool = false,
        requireImmediatePublication: Bool
    ) async -> Error? {
        let publicKeys = normalizedSavedContactKeys(publicKeys)
        guard !publicKeys.isEmpty else { return nil }

        guard await PubkyService.currentPublicKey() != nil else {
            return requireImmediatePublication ? PubkyServiceError.sessionNotActive : nil
        }

        var firstError: Error?
        var updates = [PrivatePaymentListReservationUpdateInput]()
        for publicKey in publicKeys {
            do {
                _ = try await PaykitSdkService.shared.ensureLinkWithPeer(publicKey)
            } catch {
                Logger.warn(
                    "Failed to prepare private Paykit link for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                    context: "PrivatePaykit"
                )
            }

            do {
                let endpoints = try await buildLocalEndpoints(
                    for: publicKey,
                    wallet: wallet,
                    forceRefreshLightning: forceRefreshLightning
                )
                let reservations = reservations(from: endpoints, publicKey: publicKey)
                updates.append(PrivatePaymentListReservationUpdateInput(counterparty: publicKey, reservations: reservations))
            } catch {
                Logger.warn(
                    "Failed to prepare private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                    context: "PrivatePaykit"
                )
                firstError = firstError ?? error
            }
        }

        guard !updates.isEmpty else {
            return requireImmediatePublication ? firstError ?? PrivatePaykitError.privateUnavailable : nil
        }

        do {
            let report = try await PaykitSdkService.shared.syncPrivatePaymentListsWithReservations(
                updates,
                clearUnlistedLinkedPeers: false
            )
            firstError = firstError ?? applyPrivatePaymentListDeliveryReport(report, reason: reason)
            let retryKeys = privatePaymentListDeliveryRetryKeys(from: report)
            await drainPendingPrivateMessages(reason: reason, advancingLinksFor: retryKeys)
            if !retryKeys.isEmpty {
                schedulePendingPrivateMessageDrainRetries(reason: reason, publicKeys: retryKeys)
            }
        } catch {
            Logger.warn("Failed to sync private Paykit endpoint publications during \(reason): \(error)", context: "PrivatePaykit")
            firstError = firstError ?? error
        }

        return requireImmediatePublication ? firstError : nil
    }

    private func privatePaymentListDeliveryRetryKeys(from report: PrivatePaymentListDeliveryReport) -> [String] {
        normalizedSavedContactKeys(report.queued.map(\.counterparty) + report.failedToDeliver.map(\.counterparty))
    }

    private func drainPendingPrivateMessages(reason: String, advancingLinksFor publicKeys: [String] = []) async {
        do {
            for publicKey in normalizedSavedContactKeys(publicKeys) {
                do {
                    _ = try await PaykitSdkService.shared.ensureLinkWithPeer(publicKey)
                } catch {
                    Logger.warn(
                        "Failed to advance private Paykit link for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                        context: "PrivatePaykit"
                    )
                }
            }
            try await PaykitSdkService.shared.processPendingPrivateMessages()
            try await PaykitSdkService.shared.receivePrivateMessagesFromLinkedPeers()
            try await PaykitSdkService.shared.processPendingPrivateMessages()
            try await PaykitSdkService.shared.receivePrivateMessagesFromLinkedPeers()
        } catch {
            Logger.warn("Failed to process pending private Paykit messages during \(reason): \(error)", context: "PrivatePaykit")
        }
    }

    private func schedulePendingPrivateMessageDrainRetries(reason: String, publicKeys: [String]) {
        pendingMessageDrainRetryTask?.cancel()
        pendingMessageDrainRetryTask = Task { [reason, publicKeys] in
            for delay in Self.privateMessageDrainRetryDelays {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await PrivatePaykitService.shared.drainPendingPrivateMessages(reason: "\(reason) retry", advancingLinksFor: publicKeys)
            }
        }
    }

    private func applyPrivatePaymentListDeliveryReport(_ report: PrivatePaymentListDeliveryReport, reason: String) -> Error? {
        var firstError: Error?
        var didChangeState = false

        for change in report.queued {
            guard let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) else { continue }
            state.contacts[publicKey, default: ContactState()].hasPublishedPrivatePaymentList = true
            Self.clearDeletedContactCleanupPending([publicKey])
            didChangeState = true
        }

        for change in report.cleared {
            guard let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) else { continue }
            if var contactState = state.contacts[publicKey] {
                contactState.cachedResolvedEndpoints = []
                contactState.localInvoice = nil
                contactState.hasPublishedPrivatePaymentList = false
                state.contacts[publicKey] = contactState.hasCacheState ? contactState : nil
                didChangeState = true
            }
            Self.clearDeletedContactCleanupPending([publicKey])
        }

        for change in report.failedToQueue {
            let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) ?? change.counterparty
            Logger.warn(
                "Failed to queue private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(change.error ?? "unknown error")",
                context: "PrivatePaykit"
            )
            firstError = firstError ?? PrivatePaykitError.privateUnavailable
        }

        for failure in report.failedToDeliver {
            let publicKey = PubkyPublicKeyFormat.normalized(failure.counterparty) ?? failure.counterparty
            Logger.warn(
                "Failed to deliver private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(failure.error)",
                context: "PrivatePaykit"
            )
            firstError = firstError ?? PrivatePaykitError.privateUnavailable
        }

        if didChangeState {
            persistState(markWalletBackup: true)
        }

        return firstError
    }

    func normalizedSavedContactKeys(_ publicKeys: [String]) -> [String] {
        var seen = Set<String>()
        return publicKeys.compactMap { publicKey in
            guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey),
                  seen.insert(normalizedKey).inserted
            else { return nil }

            return normalizedKey
        }
    }

    func rememberSavedContacts(_ publicKeys: [String], replacing: Bool) -> [String] {
        let normalizedKeys = normalizedSavedContactKeys(publicKeys)
        if replacing {
            knownSavedContactKeys = Set(normalizedKeys)
        } else {
            knownSavedContactKeys.formUnion(normalizedKeys)
        }
        return normalizedKeys
    }

    func knownSavedContact(_ publicKey: String) -> String? {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey),
              isKnownSavedContact(normalizedKey)
        else { return nil }

        return normalizedKey
    }

    func isKnownSavedContact(_ publicKey: String) -> Bool {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return false }
        return knownSavedContactKeys.contains(normalizedKey)
    }
}
