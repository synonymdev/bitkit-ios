import Foundation
import Paykit

// MARK: - Saved Contacts

extension PrivatePaykitService {
    enum FullCleanupReconciliationMode: Equatable {
        case restoreSavedContacts
        case removePublishedState
    }

    static func fullCleanupReconciliationMode(defaults: UserDefaults = .standard) -> FullCleanupReconciliationMode {
        return defaults.bool(forKey: publishingEnabledKey) ? .restoreSavedContacts : .removePublishedState
    }

    struct EndpointPublicationOperations {
        let currentPublicKey: () async -> String?
        let ensureLink: (_ publicKey: String) async throws -> Void
        let buildEndpoints: (_ publicKey: String) async throws -> [PublicPaykitService.Endpoint]
        let syncPaymentLists: (_ updates: [PrivatePaymentListReservationUpdateInput]) async throws -> PrivatePaymentListDeliveryReport
    }

    @discardableResult
    func prepareSavedContacts(
        _ publicKeys: [String],
        wallet: WalletViewModel,
        requireImmediatePublication: Bool = false
    ) async -> Error? {
        await prepareSavedContacts(
            publicKeys,
            publicationUnavailableReason: privateEndpointPublicationUnavailabilityReason(wallet: wallet),
            prepareLinks: { await self.prepareRelevantPrivateLinksIfAvailable($0, reason: "prepare") },
            publishEndpoints: { publicKeys in
                await PrivatePaykitAddressReservationStore.shared.reconcileReservedIndexesWithLdk()
                return await self.syncLocalEndpointPublication(
                    for: publicKeys,
                    wallet: wallet,
                    reason: "prepare",
                    requireImmediatePublication: requireImmediatePublication
                )
            }
        )
    }

    func prepareSavedContacts(
        _ publicKeys: [String],
        publicationUnavailableReason: String?,
        prepareLinks: ([String]) async -> Void,
        publishEndpoints: ([String]) async -> Error?
    ) async -> Error? {
        let publicKeys = rememberSavedContacts(publicKeys, replacing: true)
        if let reason = publicationUnavailableReason {
            Logger.info("Deferring private Paykit endpoint publication during prepare: \(reason)", context: "PrivatePaykitService")
            await prepareLinks(publicKeys)
            return nil
        }
        return await publishEndpoints(publicKeys)
    }

    func refreshSavedContactEndpoints(
        for publicKeys: [String],
        savedPublicKeys: [String]? = nil,
        wallet: WalletViewModel,
        forceRefreshLightning: Bool = false
    ) async {
        if let savedPublicKeys {
            _ = rememberSavedContacts(savedPublicKeys + publicKeys, replacing: false)
        }

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

    func startInitialLinkBurst(
        for publicKeys: [String],
        savedPublicKeys: [String]? = nil,
        wallet: WalletViewModel,
        reason: String
    ) {
        if let savedPublicKeys {
            _ = rememberSavedContacts(savedPublicKeys + publicKeys, replacing: false)
        }

        let publicKeys = normalizedSavedContactKeys(publicKeys)
        guard !publicKeys.isEmpty else { return }

        initialLinkBurstPublicKeys.formUnion(publicKeys)
        initialLinkBurstGeneration += 1
        let generation = initialLinkBurstGeneration
        initialLinkBurstTask?.cancel()
        Self.initialLinkBurstStartedSubject.send()

        initialLinkBurstTask = Task { [reason, generation] in
            for delay in [UInt64(0)] + Self.initialLinkBurstRetryDelays {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled,
                      generation == initialLinkBurstGeneration
                else { return }

                let publicKeys = Array(initialLinkBurstPublicKeys)
                _ = await refreshSavedContactEndpointsReturningError(
                    for: publicKeys,
                    wallet: wallet,
                    forceRefreshLightning: false,
                    requireImmediatePublication: false,
                    reason: "\(reason) initial link burst"
                )
            }

            guard generation == initialLinkBurstGeneration else { return }
            initialLinkBurstTask = nil
            initialLinkBurstPublicKeys.removeAll()
        }
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
            await prepareRelevantPrivateLinksIfAvailable(publicKeys, reason: reason)
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
        let publicKeys = normalizedSavedContactKeys(publicKeys)
        guard !publicKeys.isEmpty else { return }

        try await withPublicationLock {
            try await removePublishedEndpointsLocked(for: publicKeys)
        }
    }

    private func removePublishedEndpointsLocked(for publicKeys: [String]) async throws {
        let linkedPublicKeys = try await Set(PaykitSdkService.shared.linkedPeers()
            .filter { $0.state != .notLinked }
            .compactMap { PubkyPublicKeyFormat.normalized($0.counterparty) })
        let cleanupKeys = privatePaymentListCleanupKeys(publicKeys, linkedPublicKeys: linkedPublicKeys)
        let publicKeySet = Set(publicKeys)
        let cleanupStateSnapshots = Dictionary(uniqueKeysWithValues: publicKeys.map { publicKey in
            (publicKey, publishedEndpointCleanupState(publicKey: publicKey))
        })

        var firstError: Error?
        var failedPublicKeys = Set<String>()
        var clearedRetryKeys = [String]()
        for publicKey in cleanupKeys {
            do {
                guard let report = try await PaykitSdkService.shared.clearPrivatePaymentList(to: publicKey) else { continue }
                if !report.failedToQueue.isEmpty || !report.failedToDeliver.isEmpty {
                    throw PrivatePaykitError.privateUnavailable
                }
                clearedRetryKeys.append(publicKey)
            } catch {
                failedPublicKeys.insert(publicKey)
                firstError = firstError ?? error
            }
        }

        if !clearedRetryKeys.isEmpty {
            await drainPendingPrivateMessages(reason: "cleanup", advancing: clearedRetryKeys)
            let pendingRetryKeys = await pendingPrivateMessageDrainKeys(clearedRetryKeys)
            if !pendingRetryKeys.isEmpty {
                failedPublicKeys.formUnion(pendingRetryKeys)
                firstError = firstError ?? PrivatePaykitError.privateUnavailable
            }
        }

        for publicKey in publicKeySet.subtracting(failedPublicKeys) {
            guard publishedEndpointCleanupState(publicKey: publicKey) == cleanupStateSnapshots[publicKey] else {
                failedPublicKeys.insert(publicKey)
                firstError = firstError ?? PrivatePaykitError.privateUnavailable
                Logger.warn(
                    "Private Paykit state changed during cleanup for \(PubkyPublicKeyFormat.redacted(publicKey)); deferring local cleanup",
                    context: "PrivatePaykit"
                )
                continue
            }
        }

        let successfulPublicKeys = publicKeySet.subtracting(failedPublicKeys)
        if applyPublishedEndpointCleanupResults(
            successfulPublicKeys: successfulPublicKeys,
            failedPublicKeys: failedPublicKeys
        ) {
            persistState(markWalletBackup: true)
        }

        if let firstError {
            throw firstError
        }
    }

    func privatePaymentListCleanupKeys(_ publicKeys: [String], linkedPublicKeys: Set<String>) -> [String] {
        publicKeys.filter {
            linkedPublicKeys.contains($0) || state.contacts[$0]?.hasPublishedPrivatePaymentList == true
        }
    }

    func removeSavedContact(publicKey: String) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        knownSavedContactKeys.remove(normalizedKey)
        Self.markDeletedContactCleanupPending([normalizedKey])
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
        Self.markDeletedContactCleanupPending(normalizedKeys)
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

        let staleKeys: Set<String> = Set(state.contacts.compactMap { publicKey, contactState in
            guard !savedKeys.contains(publicKey), contactState.hasContactOwnedCacheState else { return nil }
            return publicKey
        })
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

    func retryPendingEndpointReconciliation(wallet: WalletViewModel, savedPublicKeys publicKeys: [String]) async {
        let savedKeys = Set(normalizedSavedContactKeys(publicKeys))
        let isFullCleanupPending = UserDefaults.standard.bool(forKey: Self.cleanupPendingKey)
        if isFullCleanupPending,
           Self.fullCleanupReconciliationMode() == .restoreSavedContacts
        {
            let restoreKeys = savedKeys.union(knownSavedContactKeys)
            guard !restoreKeys.isEmpty else { return }
            guard await canPublishPrivateEndpoints(wallet: wallet) else { return }

            let publicKeys = rememberSavedContacts(Array(restoreKeys), replacing: true)
            await PrivatePaykitAddressReservationStore.shared.reconcileReservedIndexesWithLdk()
            let error = await refreshSavedContactEndpointsReturningError(
                for: publicKeys,
                wallet: wallet,
                forceRefreshLightning: false,
                requireImmediatePublication: true,
                reason: "reconcile"
            )
            if let error {
                Logger.warn("Failed to reconcile private Paykit endpoints: \(error)", context: "PrivatePaykit")
            } else {
                Self.setContactSharingCleanupPending(false)
            }
            return
        }

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

    private func syncLocalEndpointPublication(
        for publicKeys: [String],
        wallet: WalletViewModel,
        reason: String,
        forceRefreshLightning: Bool = false,
        requireImmediatePublication: Bool
    ) async -> Error? {
        let operations = endpointPublicationOperations(
            wallet: wallet,
            forceRefreshLightning: forceRefreshLightning
        )
        return await syncLocalEndpointPublication(
            for: publicKeys,
            reason: reason,
            requireImmediatePublication: requireImmediatePublication,
            operations: operations
        )
    }

    func syncLocalEndpointPublication(
        for publicKeys: [String],
        reason: String,
        requireImmediatePublication: Bool,
        operations: EndpointPublicationOperations
    ) async -> Error? {
        do {
            return try await withPublicationLock {
                await syncLocalEndpointPublicationLocked(
                    for: publicKeys,
                    reason: reason,
                    requireImmediatePublication: requireImmediatePublication,
                    operations: operations
                )
            }
        } catch {
            return requireImmediatePublication ? error : nil
        }
    }

    private func endpointPublicationOperations(
        wallet: WalletViewModel,
        forceRefreshLightning: Bool
    ) -> EndpointPublicationOperations {
        EndpointPublicationOperations(
            currentPublicKey: {
                await PubkyService.currentPublicKey()
            },
            ensureLink: { publicKey in
                _ = try await PaykitSdkService.shared.ensureLinkWithPeer(publicKey)
            },
            buildEndpoints: { publicKey in
                try await self.buildLocalEndpoints(
                    for: publicKey,
                    wallet: wallet,
                    forceRefreshLightning: forceRefreshLightning
                )
            },
            syncPaymentLists: { updates in
                try await PaykitSdkService.shared.syncPrivatePaymentListsWithReservations(
                    updates,
                    clearUnlistedLinkedPeers: false
                )
            }
        )
    }

    private func syncLocalEndpointPublicationLocked(
        for publicKeys: [String],
        reason: String,
        requireImmediatePublication: Bool,
        operations: EndpointPublicationOperations
    ) async -> Error? {
        let publicKeys = normalizedSavedContactKeys(publicKeys)
        guard !publicKeys.isEmpty else { return nil }

        guard await operations.currentPublicKey() != nil else {
            return requireImmediatePublication ? PubkyServiceError.sessionNotActive : nil
        }

        var firstError: Error?
        var updates = [PrivatePaymentListReservationUpdateInput]()
        var linkRetryKeys = [String]()

        for publicKey in publicKeys {
            do {
                try await operations.ensureLink(publicKey)
            } catch PaykitError.NotFound {
                continue
            } catch {
                Logger.warn(
                    "Failed to prepare private Paykit link for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                    context: "PrivatePaykit"
                )
            }
            linkRetryKeys.append(publicKey)
            do {
                let endpoints = try await operations.buildEndpoints(publicKey)
                updates.append(PrivatePaymentListReservationUpdateInput(
                    counterparty: publicKey,
                    reservations: reservations(from: endpoints, publicKey: publicKey)
                ))
            } catch {
                firstError = firstError ?? error
                Logger.warn(
                    "Failed to prepare private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }

        guard !updates.isEmpty else {
            await drainAndSchedulePrivateLinkRetries(reason: reason, retryKeys: linkRetryKeys)
            return requireImmediatePublication ? firstError : nil
        }

        do {
            let report = try await operations.syncPaymentLists(updates)
            let deliveryError = applyPrivatePaymentListDeliveryReport(report, reason: reason)
            firstError = firstError ?? deliveryError
            let retryKeys = linkRetryKeys + privatePaymentListDeliveryRetryKeys(from: report)
            await drainAndSchedulePrivateLinkRetries(reason: reason, retryKeys: retryKeys)
        } catch {
            Logger.warn("Failed to sync private Paykit endpoint publications during \(reason): \(error)", context: "PrivatePaykit")
            firstError = firstError ?? error
        }

        return requireImmediatePublication ? firstError : nil
    }

    private func prepareRelevantPrivateLinksIfAvailable(_ publicKeys: [String], reason: String) async {
        guard await canUsePrivateLinks() else { return }

        await drainAndSchedulePrivateLinkRetries(reason: reason, retryKeys: normalizedSavedContactKeys(publicKeys))
    }

    private func canUsePrivateLinks() async -> Bool {
        guard PaykitFeatureFlags.isUIEnabled,
              let ownPublicKey = await PubkyService.currentPublicKey()
        else { return false }

        return PubkyProfileManager.hasLocalSecretKey(for: ownPublicKey)
    }

    private func drainAndSchedulePrivateLinkRetries(reason: String, retryKeys: [String]) async {
        let retryKeys = Array(Set(retryKeys))
        guard !retryKeys.isEmpty else { return }

        await drainPendingPrivateMessages(reason: reason, advancing: retryKeys)
        let pendingRetryKeys = await pendingPrivateMessageDrainKeys(retryKeys)
        if !pendingRetryKeys.isEmpty {
            schedulePendingPrivateMessageDrainRetries(reason: reason, retryKeys: Array(pendingRetryKeys))
        }
    }

    private func privatePaymentListDeliveryRetryKeys(from report: PrivatePaymentListDeliveryReport) -> [String] {
        normalizedSavedContactKeys((report.queued + report.cleared).map(\.counterparty) + report.failedToDeliver.map(\.counterparty))
    }

    private func drainPendingPrivateMessages(reason: String, advancing retryKeys: [String]) async {
        do {
            for retryKey in Set(retryKeys) {
                do {
                    _ = try await PaykitSdkService.shared.ensureLinkWithPeer(retryKey)
                } catch {
                    Logger.warn(
                        "Failed to advance private Paykit link for \(PubkyPublicKeyFormat.redacted(retryKey)) during \(reason): \(error)",
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

    private func schedulePendingPrivateMessageDrainRetries(reason: String, retryKeys: [String]) {
        let retryKeys = Set(retryKeys)
        guard !retryKeys.isEmpty else { return }

        pendingMessageDrainRetryKeys.formUnion(retryKeys)
        pendingMessageDrainRetryGeneration += 1
        let retryGeneration = pendingMessageDrainRetryGeneration
        pendingMessageDrainRetryTask?.cancel()

        pendingMessageDrainRetryTask = Task { [reason, retryGeneration] in
            var retryIndex = 0
            while !Task.isCancelled {
                let delay = Self.privateMessageDrainRetryDelays[min(retryIndex, Self.privateMessageDrainRetryDelays.count - 1)]
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await PrivatePaykitService.shared.drainPendingPrivateMessageRetryKeys(reason: "\(reason) retry")
                let hasPending = await PrivatePaykitService.shared.hasPendingMessageDrainRetryKeys(generation: retryGeneration)
                guard hasPending else { break }
                retryIndex += 1
            }
            guard !Task.isCancelled else { return }
            await PrivatePaykitService.shared.finishPendingPrivateMessageDrainRetries(generation: retryGeneration)
        }
    }

    func schedulePrivatePaymentRecovery(for publicKey: String) {
        guard let publicKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        schedulePendingPrivateMessageDrainRetries(
            reason: "payment recovery",
            retryKeys: [publicKey]
        )
    }

    private func drainPendingPrivateMessageRetryKeys(reason: String) async {
        let retryKeys = Array(pendingMessageDrainRetryKeys)
        guard !retryKeys.isEmpty else { return }
        await drainPendingPrivateMessages(reason: reason, advancing: retryKeys)
        await updatePendingMessageDrainRetryKeys(retryKeys)
    }

    private func hasPendingMessageDrainRetryKeys(generation: Int) -> Bool {
        generation == pendingMessageDrainRetryGeneration && !pendingMessageDrainRetryKeys.isEmpty
    }

    private func finishPendingPrivateMessageDrainRetries(generation: Int) {
        guard generation == pendingMessageDrainRetryGeneration else { return }
        pendingMessageDrainRetryTask = nil
        pendingMessageDrainRetryKeys.removeAll()
    }

    private func updatePendingMessageDrainRetryKeys(_ retryKeys: [String]) async {
        let remainingKeys = await pendingPrivateMessageDrainKeys(retryKeys)
        pendingMessageDrainRetryKeys.subtract(retryKeys)
        pendingMessageDrainRetryKeys.formUnion(remainingKeys)
    }

    private func pendingPrivateMessageDrainKeys(_ retryKeys: [String]) async -> Set<String> {
        let retryKeys = Set(retryKeys)
        guard !retryKeys.isEmpty else { return [] }

        let linkedPeers: [String: LinkedPeerState]
        do {
            var peersByKey: [String: LinkedPeerState] = [:]
            for peer in try await PaykitSdkService.shared.linkedPeers() {
                guard let publicKey = PubkyPublicKeyFormat.normalized(peer.counterparty) else { continue }
                peersByKey[publicKey] = peer.state
            }
            linkedPeers = peersByKey
        } catch {
            Logger.warn("Failed to inspect private Paykit link state: \(error)", context: "PrivatePaykit")
            return retryKeys
        }

        let pendingOutbound: Set<String>
        do {
            let pending = try await PaykitSdkService.shared.pendingOutboundPrivateCounterparties()
            pendingOutbound = Set(pending.compactMap(PubkyPublicKeyFormat.normalized))
        } catch {
            Logger.warn("Failed to inspect pending private Paykit messages: \(error)", context: "PrivatePaykit")
            return retryKeys
        }

        return Set(retryKeys.filter { retryKey in
            guard let state = linkedPeers[retryKey] else {
                return pendingOutbound.contains(retryKey)
            }
            if state == .linked {
                return pendingOutbound.contains(retryKey)
            } else if state == .blocked || state == .unknown {
                return false
            } else {
                return true
            }
        })
    }

    private func applyPrivatePaymentListDeliveryReport(_ report: PrivatePaymentListDeliveryReport, reason: String) -> Error? {
        var firstError: Error?
        var didChangeState = false

        for change in report.queued {
            guard let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) else { continue }
            didChangeState = recordPublishedPrivatePaymentList(publicKey: publicKey) || didChangeState
        }

        for change in report.cleared {
            guard let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) else { continue }
            didChangeState = clearPublishedPrivatePaymentList(publicKey: publicKey) || didChangeState
        }

        for change in report.failedToQueue {
            let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) ?? change.counterparty
            Logger.warn(
                "Failed to queue private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(change.error?.redactedContext() ?? "unknown error")",
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

    private func publishedEndpointCleanupState(publicKey: String) -> PublishedEndpointCleanupState {
        let contactState = state.contacts[publicKey]
        return PublishedEndpointCleanupState(
            cachedResolvedEndpoints: contactState?.cachedResolvedEndpoints ?? [],
            localInvoice: contactState?.localInvoice,
            hasPublishedPrivatePaymentList: contactState?.hasPublishedPrivatePaymentList ?? false
        )
    }

    @discardableResult
    func applyPublishedEndpointCleanupResults(
        successfulPublicKeys: Set<String>,
        failedPublicKeys: Set<String>
    ) -> Bool {
        var didChangeState = false
        for publicKey in successfulPublicKeys {
            if var contactState = state.contacts[publicKey] {
                let hadStateToClear = !contactState.cachedResolvedEndpoints.isEmpty ||
                    contactState.localInvoice != nil ||
                    contactState.hasPublishedPrivatePaymentList
                contactState.cachedResolvedEndpoints = []
                contactState.localInvoice = nil
                contactState.hasPublishedPrivatePaymentList = false
                let shouldRemoveContact = !contactState.hasCacheState
                state.contacts[publicKey] = shouldRemoveContact ? nil : contactState
                didChangeState = didChangeState || hadStateToClear || shouldRemoveContact
            }
        }

        Self.markDeletedContactCleanupPending(Array(failedPublicKeys))
        Self.clearDeletedContactCleanupPending(Array(successfulPublicKeys))
        return didChangeState
    }

    private func recordPublishedPrivatePaymentList(publicKey: String) -> Bool {
        var contactState = state.contacts[publicKey, default: ContactState()]
        guard !contactState.hasPublishedPrivatePaymentList else { return false }
        contactState.hasPublishedPrivatePaymentList = true
        state.contacts[publicKey] = contactState
        return true
    }

    private func clearPublishedPrivatePaymentList(publicKey: String) -> Bool {
        guard var contactState = state.contacts[publicKey] else { return false }
        guard contactState.hasPublishedPrivatePaymentList || contactState.localInvoice != nil else { return false }
        contactState.hasPublishedPrivatePaymentList = false
        contactState.localInvoice = nil
        state.contacts[publicKey] = contactState.hasCacheState ? contactState : nil
        return true
    }

    private struct PublishedEndpointCleanupState: Equatable {
        let cachedResolvedEndpoints: [StoredPaymentEntry]
        let localInvoice: StoredInvoice?
        let hasPublishedPrivatePaymentList: Bool
    }
}
