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
            await prepareRelevantPrivateLinksIfAvailable(publicKeys, reason: "prepare")
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
        var firstError: Error?
        var didChangeState = false
        for publicKey in normalizedSavedContactKeys(publicKeys) {
            var didFail = false
            let cleanupReceiverPaths: [String]
            do {
                cleanupReceiverPaths = try await receiverPathsForCleanup(publicKey: publicKey)
            } catch {
                firstError = firstError ?? error
                Self.markDeletedContactCleanupPending([publicKey])
                continue
            }

            for receiverPath in cleanupReceiverPaths {
                do {
                    let report = try await PaykitSdkService.shared.clearPrivatePaymentList(to: publicKey, receiverPath: receiverPath)
                    if !report.failedToQueue.isEmpty || !report.failedToDeliver.isEmpty {
                        throw PrivatePaykitError.privateUnavailable
                    }
                    let retryKey = PrivateMessageDrainRetryKey(publicKey: publicKey, receiverPath: receiverPath)
                    await drainPendingPrivateMessages(reason: "cleanup", advancing: [retryKey])
                    if await pendingPrivateMessageDrainKeys([retryKey]).contains(retryKey) {
                        throw PrivatePaykitError.privateUnavailable
                    }
                } catch {
                    didFail = true
                    firstError = firstError ?? error
                    Self.markDeletedContactCleanupPending([publicKey])
                }
            }

            if !didFail {
                if var contactState = state.contacts[publicKey] {
                    let hadStateToClear = !contactState.cachedResolvedEndpoints.isEmpty ||
                        !contactState.localInvoicesByReceiverPath.isEmpty ||
                        !contactState.publishedPrivatePaymentReceiverPaths.isEmpty
                    contactState.cachedResolvedEndpoints = []
                    contactState.localInvoicesByReceiverPath = [:]
                    contactState.publishedPrivatePaymentReceiverPaths = []
                    let shouldRemoveContact = !contactState.hasCacheState
                    state.contacts[publicKey] = shouldRemoveContact ? nil : contactState
                    didChangeState = didChangeState || hadStateToClear || shouldRemoveContact
                }

                Self.clearDeletedContactCleanupPending([publicKey])
            }
        }

        if didChangeState {
            persistState(markWalletBackup: true)
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
        var linkRetryKeys = [PrivateMessageDrainRetryKey]()
        for publicKey in publicKeys {
            let receiverPaths: [String]
            do {
                receiverPaths = try await receiverPathsForSavedContact(publicKey: publicKey)
            } catch {
                firstError = firstError ?? error
                Logger.warn(
                    "Failed to read saved Paykit receivers for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                    context: "PrivatePaykit"
                )
                continue
            }
            let receiverPathSelection: PrivateReceiverPathSelection
            do {
                receiverPathSelection = try await PaykitSdkService.shared.privateReceiverPathSelection(
                    publicKey: publicKey,
                    savedReceiverPaths: receiverPaths
                )
            } catch {
                return error
            }
            let linkableReceiverPaths = receiverPathSelection.linkableReceiverPaths
            let publicationReceiverPaths = receiverPathSelection.publishableReceiverPaths
            if let error = receiverPathSelection.error {
                firstError = firstError ?? error
                Logger.warn(
                    "Failed to inspect private Paykit receiver markers for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                    context: "PrivatePaykit"
                )
            }
            let cleanupReceiverPaths: [String]
            do {
                cleanupReceiverPaths = try await receiverPathsForPrivateEndpointCleanup(
                    publicKey: publicKey,
                    excluding: publicationReceiverPaths + receiverPathSelection.cleanupProtectedReceiverPaths
                )
            } catch {
                cleanupReceiverPaths = []
                firstError = firstError ?? error
                Logger.warn(
                    "Failed to inspect private Paykit links for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                    context: "PrivatePaykit"
                )
            }

            for receiverPath in Set(linkableReceiverPaths).union(cleanupReceiverPaths) {
                linkRetryKeys.append(PrivateMessageDrainRetryKey(publicKey: publicKey, receiverPath: receiverPath))
                do {
                    _ = try await PaykitSdkService.shared.ensureLinkWithPeer(publicKey, receiverPath: receiverPath)
                } catch {
                    Logger.warn(
                        "Failed to prepare private Paykit link for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                        context: "PrivatePaykit"
                    )
                }
            }

            updates.append(contentsOf: cleanupReceiverPaths.map { receiverPath in
                PrivatePaymentListReservationUpdateInput(
                    counterparty: publicKey,
                    counterpartyReceiverPath: receiverPath,
                    reservations: []
                )
            })

            for receiverPath in publicationReceiverPaths {
                do {
                    let endpoints = try await buildLocalEndpoints(
                        for: publicKey,
                        receiverPath: receiverPath,
                        wallet: wallet,
                        forceRefreshLightning: forceRefreshLightning
                    )
                    let reservations = reservations(from: endpoints, publicKey: publicKey, receiverPath: receiverPath)
                    let update = PrivatePaymentListReservationUpdateInput(
                        counterparty: publicKey,
                        counterpartyReceiverPath: receiverPath,
                        reservations: reservations
                    )
                    updates.append(update)
                } catch {
                    Logger.warn(
                        "Failed to prepare private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                        context: "PrivatePaykit"
                    )
                    firstError = firstError ?? error
                }
            }
        }

        guard !updates.isEmpty else {
            await drainAndSchedulePrivateLinkRetries(reason: reason, retryKeys: linkRetryKeys)
            return requireImmediatePublication ? firstError : nil
        }

        do {
            let report = try await PaykitSdkService.shared.syncPrivatePaymentListsWithReservations(
                updates,
                clearUnlistedLinkedPeers: false
            )
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

        var retryKeys = [PrivateMessageDrainRetryKey]()
        for publicKey in normalizedSavedContactKeys(publicKeys) {
            do {
                let receiverPaths = try await receiverPathsForSavedContact(publicKey: publicKey)
                let selection = try await PaykitSdkService.shared.privateReceiverPathSelection(
                    publicKey: publicKey,
                    savedReceiverPaths: receiverPaths
                )
                if let error = selection.error {
                    Logger.warn(
                        "Failed to inspect private Paykit receiver markers for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                        context: "PrivatePaykit"
                    )
                }
                retryKeys.append(contentsOf: selection.linkableReceiverPaths.map {
                    PrivateMessageDrainRetryKey(publicKey: publicKey, receiverPath: $0)
                })
            } catch is CancellationError {
                return
            } catch {
                Logger.warn(
                    "Failed to prepare private Paykit links for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }

        await drainAndSchedulePrivateLinkRetries(reason: reason, retryKeys: retryKeys)
    }

    private func canUsePrivateLinks() async -> Bool {
        guard PaykitFeatureFlags.isUIEnabled,
              let ownPublicKey = await PubkyService.currentPublicKey()
        else { return false }

        return PubkyProfileManager.hasLocalSecretKey(for: ownPublicKey)
    }

    private func drainAndSchedulePrivateLinkRetries(reason: String, retryKeys: [PrivateMessageDrainRetryKey]) async {
        let retryKeys = Array(Set(retryKeys))
        guard !retryKeys.isEmpty else { return }

        await drainPendingPrivateMessages(reason: reason, advancing: retryKeys)
        let pendingRetryKeys = await pendingPrivateMessageDrainKeys(retryKeys)
        if !pendingRetryKeys.isEmpty {
            schedulePendingPrivateMessageDrainRetries(reason: reason, retryKeys: Array(pendingRetryKeys))
        }
    }

    private func privatePaymentListDeliveryRetryKeys(from report: PrivatePaymentListDeliveryReport) -> [PrivateMessageDrainRetryKey] {
        let changes = (report.queued + report.cleared).map { (counterparty: $0.counterparty, receiverPath: $0.counterpartyReceiverPath) } +
            report.failedToDeliver.map { (counterparty: $0.counterparty, receiverPath: $0.counterpartyReceiverPath) }
        var seen = Set<PrivateMessageDrainRetryKey>()
        return changes.compactMap { change in
            guard let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) else { return nil }
            let retryKey = PrivateMessageDrainRetryKey(publicKey: publicKey, receiverPath: change.receiverPath)
            guard seen.insert(retryKey).inserted else { return nil }
            return retryKey
        }
    }

    private func drainPendingPrivateMessages(reason: String, advancing retryKeys: [PrivateMessageDrainRetryKey]) async {
        do {
            for retryKey in Set(retryKeys) {
                do {
                    _ = try await PaykitSdkService.shared.ensureLinkWithPeer(retryKey.publicKey, receiverPath: retryKey.receiverPath)
                } catch {
                    Logger.warn(
                        "Failed to advance private Paykit link for \(PubkyPublicKeyFormat.redacted(retryKey.publicKey)) during \(reason): \(error)",
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

    private func schedulePendingPrivateMessageDrainRetries(reason: String, retryKeys: [PrivateMessageDrainRetryKey]) {
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
            retryKeys: [PrivateMessageDrainRetryKey(publicKey: publicKey, receiverPath: PaykitReceiverPath.wallet)]
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

    private func updatePendingMessageDrainRetryKeys(_ retryKeys: [PrivateMessageDrainRetryKey]) async {
        let remainingKeys = await pendingPrivateMessageDrainKeys(retryKeys)
        pendingMessageDrainRetryKeys.subtract(retryKeys)
        pendingMessageDrainRetryKeys.formUnion(remainingKeys)
    }

    private func pendingPrivateMessageDrainKeys(_ retryKeys: [PrivateMessageDrainRetryKey]) async -> Set<PrivateMessageDrainRetryKey> {
        let retryKeys = Set(retryKeys)
        guard !retryKeys.isEmpty else { return [] }

        let linkedPeers: [PrivateMessageDrainRetryKey: LinkedPeerState]
        do {
            var peersByKey: [PrivateMessageDrainRetryKey: LinkedPeerState] = [:]
            for peer in try await PaykitSdkService.shared.linkedPeers() {
                guard let publicKey = PubkyPublicKeyFormat.normalized(peer.counterparty) else { continue }
                peersByKey[PrivateMessageDrainRetryKey(publicKey: publicKey, receiverPath: peer.counterpartyReceiverPath)] = peer.state
            }
            linkedPeers = peersByKey
        } catch {
            Logger.warn("Failed to inspect private Paykit link state: \(error)", context: "PrivatePaykit")
            return retryKeys
        }

        let pendingOutbound: Set<PrivateMessageDrainRetryKey>
        do {
            let pendingReceivers = try await PaykitSdkService.shared.pendingOutboundPrivateCounterparties()
            pendingOutbound = Set(pendingReceivers.compactMap { receiver in
                guard let publicKey = PubkyPublicKeyFormat.normalized(receiver.counterparty) else { return nil }
                return PrivateMessageDrainRetryKey(publicKey: publicKey, receiverPath: receiver.counterpartyReceiverPath)
            })
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
            didChangeState = recordPublishedPrivatePaymentList(
                publicKey: publicKey,
                receiverPath: change.counterpartyReceiverPath
            ) || didChangeState
        }

        for change in report.cleared {
            guard let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) else { continue }
            didChangeState = clearPublishedPrivatePaymentList(
                publicKey: publicKey,
                receiverPath: change.counterpartyReceiverPath
            ) || didChangeState
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

    private func receiverPathsForSavedContact(publicKey: String) async throws -> [String] {
        guard let record = try await PaykitSdkService.shared.contactRecord(publicKey: publicKey) else {
            return [PaykitReceiverPath.wallet]
        }

        let paths = record.receiverPaths.filter { PaykitReceiverPath.supported.contains($0) }
        return paths.isEmpty ? [PaykitReceiverPath.wallet] : paths
    }

    private func receiverPathsForPrivateEndpointCleanup(
        publicKey: String,
        excluding publicationReceiverPaths: [String]
    ) async throws -> [String] {
        let publishedPaths = publishedPrivatePaymentReceiverPaths(publicKey: publicKey)
        let linkedPaths = try await linkedReceiverPaths(publicKey: publicKey)
        let excluded = Set(publicationReceiverPaths)
        return Array(Set(publishedPaths).union(linkedPaths).subtracting(excluded))
            .filter { PaykitReceiverPath.supported.contains($0) }
            .sorted()
    }

    private func receiverPathsForCleanup(publicKey: String) async throws -> [String] {
        let linkedPaths = try await linkedReceiverPaths(publicKey: publicKey)
        let publishedPaths = publishedPrivatePaymentReceiverPaths(publicKey: publicKey)
        return Array(Set(linkedPaths).union(publishedPaths))
            .filter { PaykitReceiverPath.supported.contains($0) }
            .sorted()
    }

    private func linkedReceiverPaths(publicKey: String) async throws -> [String] {
        guard let publicKey = PubkyPublicKeyFormat.normalized(publicKey) else { return [] }
        let peers = try await PaykitSdkService.shared.linkedPeers()

        let linkedPaths = peers.compactMap { peer -> String? in
            guard PubkyPublicKeyFormat.normalized(peer.counterparty) == publicKey,
                  PaykitReceiverPath.supported.contains(peer.counterpartyReceiverPath)
            else { return nil }
            return peer.counterpartyReceiverPath
        }
        return Array(Set(linkedPaths)).sorted()
    }

    private func publishedPrivatePaymentReceiverPaths(publicKey: String) -> [String] {
        state.contacts[publicKey]?.publishedPrivatePaymentReceiverPaths ?? []
    }

    private func recordPublishedPrivatePaymentList(publicKey: String, receiverPath: String) -> Bool {
        var contactState = state.contacts[publicKey, default: ContactState()]
        var paths = Set(contactState.publishedPrivatePaymentReceiverPaths)
        guard paths.insert(receiverPath).inserted else { return false }
        contactState.publishedPrivatePaymentReceiverPaths = Array(paths).sorted()
        state.contacts[publicKey] = contactState
        return true
    }

    private func clearPublishedPrivatePaymentList(publicKey: String, receiverPath: String) -> Bool {
        guard var contactState = state.contacts[publicKey] else { return false }
        let hadPublishedPath = contactState.publishedPrivatePaymentReceiverPaths.contains(receiverPath)
        let hadLocalInvoice = contactState.localInvoicesByReceiverPath[receiverPath] != nil
        guard hadPublishedPath || hadLocalInvoice else { return false }
        contactState.publishedPrivatePaymentReceiverPaths.removeAll { $0 == receiverPath }
        contactState.localInvoicesByReceiverPath.removeValue(forKey: receiverPath)
        state.contacts[publicKey] = contactState.hasCacheState ? contactState : nil
        return true
    }
}
