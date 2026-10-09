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
        let ensureLink: (_ publicKey: String) async throws -> LinkedPeerState
        let buildEndpoints: (_ publicKey: String) async throws -> [PublicPaykitService.Endpoint]
        let syncPaymentLists: (_ updates: [PrivatePaymentListReservationUpdateInput]) async throws -> PrivatePaymentListDeliveryReport
        var linkedPeers: () async throws -> [LinkedPeerRecord] = { [] }
        var canPublish: () async -> Bool = { true }
    }

    struct PrivateMessageDrainOperations {
        let ensureLink: (String) async throws -> Void
        let pendingOutbound: () async throws -> [String]
        let linkedPeers: () async throws -> [LinkedPeerRecord]
        let processPending: (String) async throws -> Void
        let receive: (String) async throws -> Void

        static func live(readPriority: PaykitSdkOperationLock.Priority = .ordered) -> PrivateMessageDrainOperations {
            PrivateMessageDrainOperations(
                ensureLink: { _ = try await PaykitSdkService.shared.ensureLinkWithPeer($0, priority: readPriority) },
                pendingOutbound: { try await PaykitSdkService.shared.pendingOutboundPrivateCounterparties(priority: readPriority) },
                linkedPeers: { try await PaykitSdkService.shared.linkedPeers(priority: readPriority) },
                processPending: { _ = try await PaykitSdkService.shared.processOutboundPrivateMessages(counterparty: $0, priority: readPriority) },
                receive: { _ = try await PaykitSdkService.shared.receivePrivateMessages(counterparty: $0, priority: readPriority) }
            )
        }
    }

    struct PrivateMessageRetryOperations {
        var now: () -> Date = Date.init
        var sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
        var currentPublicKey: (PaykitSdkOperationLock.Priority) async throws -> String? = {
            try await PaykitSdkService.shared.identityStatus(priority: $0)?.publicKey
        }

        var drain: (PaykitSdkOperationLock.Priority) -> PrivateMessageDrainOperations = { .live(readPriority: $0) }
        var didLink: (String, String) async -> Void = { identity, publicKey in
            contactLinkCompletedSubject.send((identity, publicKey))
        }
    }

    struct PrivateMessageRetry {
        let id = UUID()
        var nextAttemptAt: Date
        var retryIndex = 0
        var foregroundUntil: Date?
        var expectedIdentity: String?

        func priority(at now: Date) -> PaykitSdkOperationLock.Priority {
            foregroundUntil.map { $0 > now } == true ? .interactive : .background
        }

        mutating func completeAttempt(at now: Date) {
            retryIndex = min(retryIndex + 1, privateMessageDrainRetryDelays.count - 1)
            let delay = privateMessageDrainRetryDelays[retryIndex]
            nextAttemptAt = now.addingTimeInterval(TimeInterval(delay) / 1_000_000_000)
        }
    }

    struct PrivateMessageSchedulingSnapshot {
        let peers: [LinkedPeerRecord]
        let pendingOutbound: Set<String>
        let preparationGeneration: Int
        let schedulingGeneration: Int
        var expectedIdentity: String?

        func drainKeys(_ retryKeys: Set<String>, retryMissingPeers: Bool = false) -> Set<String> {
            var linkedPeers: [String: LinkedPeerState] = [:]
            for peer in peers {
                guard let publicKey = PubkyPublicKeyFormat.normalized(peer.counterparty) else { continue }
                linkedPeers[publicKey] = peer.state
            }
            return PrivatePaykitService.pendingPrivateMessageDrainKeys(
                retryKeys, linkedPeers: linkedPeers, pendingOutbound: pendingOutbound, retryMissingPeers: retryMissingPeers
            )
        }
    }

    struct EndpointCleanupOperations {
        let linkedPeers: () async throws -> [LinkedPeerRecord]
        let clearPaymentLists: (_ publicKeys: [String]) async throws -> PrivatePaymentListDeliveryReport?
        let drainMessages: (_ publicKeys: [String]) async -> Void
        let pendingDrainKeys: (_ publicKeys: [String]) async -> Set<String>
        let syncApp: () async throws -> Void
    }

    @discardableResult
    func prepareSavedContacts(
        _ publicKeys: [String],
        wallet: WalletViewModel,
        requireImmediatePublication: Bool = false,
        isSessionCurrent: (@MainActor () -> Bool)? = nil
    ) async -> Error? {
        let revision = savedContactsRevision
        let generation = preparationGeneration
        if let isSessionCurrent, await !isSessionCurrent() { return nil }
        guard revision == savedContactsRevision, generation == preparationGeneration else { return nil }
        if !requireImmediatePublication {
            let keys = rememberSavedContacts(publicKeys, replacing: true)
            scheduleContactPreparation(keys, wallet: wallet, isSessionCurrent: isSessionCurrent)
            return nil
        }
        return await prepareSavedContacts(
            publicKeys,
            publicationUnavailableReason: privateEndpointPublicationUnavailabilityReason(wallet: wallet),
            prepareLinks: { await self.prepareRelevantPrivateLinksIfAvailable($0, reason: "prepare") },
            publishEndpoints: { publicKeys in
                await PrivatePaykitAddressReservationStore.shared.reconcileReservedIndexesWithLdk()
                return await self.syncLocalEndpointPublication(
                    for: publicKeys,
                    wallet: wallet,
                    reason: "prepare",
                    requireImmediatePublication: requireImmediatePublication,
                    isSessionCurrent: isSessionCurrent
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

        guard !Task.isCancelled else { return }
        scheduleContactPreparation(
            publicKeys,
            wallet: wallet,
            forceRefreshLightning: forceRefreshLightning,
            requeueActive: true
        )
    }

    func refreshKnownSavedContactEndpoints(wallet: WalletViewModel, reason: String, forceRefreshLightning: Bool = false) async {
        scheduleContactPreparation(Array(knownSavedContactKeys), wallet: wallet, forceRefreshLightning: forceRefreshLightning)
    }

    func awaitContactPreparation() async throws {
        try Task.checkCancellation()
        guard let preparationTask else { return }
        // Cancelling a caller must not cancel preparation shared by other callers.
        let (completion, continuation) = AsyncStream<Void>.makeStream()
        let waiter = Task {
            await preparationTask.value
            continuation.finish()
        }
        defer {
            waiter.cancel()
            continuation.finish()
        }
        for await _ in completion {}
        try Task.checkCancellation()
    }

    private func scheduleContactPreparation(
        _ publicKeys: [String],
        wallet: WalletViewModel,
        forceRefreshLightning: Bool = false,
        requeueActive: Bool = false,
        isSessionCurrent: (@MainActor () -> Bool)? = nil
    ) {
        scheduleContactPreparation(
            publicKeys,
            forceRefreshLightning: forceRefreshLightning,
            requeueActive: requeueActive || isSessionCurrent != nil
        ) { keys, forceRefresh in
            guard !UserDefaults.standard.bool(forKey: Self.cleanupPendingKey) else { return }
            _ = await self.refreshSavedContactEndpointsReturningError(
                for: keys,
                wallet: wallet,
                forceRefreshLightning: forceRefresh,
                requireImmediatePublication: false,
                reason: "contact preparation",
                isSessionCurrent: isSessionCurrent
            )
        }
    }

    func scheduleContactPreparation(
        _ publicKeys: [String],
        forceRefreshLightning: Bool = false,
        requeueActive: Bool = false,
        operation: @escaping ([String], Bool) async -> Void
    ) {
        guard !isDeletingProfile else { return }
        let keys = publicKeys.filter { requeueActive || forceRefreshLightning || !activePreparationKeys.contains($0) }
        guard !keys.isEmpty else { return }
        pendingPreparationKeys.formUnion(keys)
        pendingPreparationOperation = operation
        pendingForceRefreshLightning = pendingForceRefreshLightning || forceRefreshLightning
        guard preparationTask == nil, !pendingPreparationKeys.isEmpty else { return }
        preparationTask = Task {
            defer {
                activePreparationKeys.removeAll()
                pendingPreparationOperation = nil
                preparationTask = nil
            }
            while !Task.isCancelled, !pendingPreparationKeys.isEmpty {
                guard await waitForBackgroundWork(generation: preparationGeneration) else { continue }
                guard let operation = pendingPreparationOperation else { break }
                let keys = pendingPreparationKeys.intersection(knownSavedContactKeys)
                let forceRefresh = pendingForceRefreshLightning
                pendingPreparationKeys.removeAll()
                pendingPreparationOperation = nil
                pendingForceRefreshLightning = false
                activePreparationKeys = keys
                await operation(Array(keys).sorted(), forceRefresh)
                activePreparationKeys.removeAll()
            }
        }
    }

    func invalidateContactPreparation() {
        preparationGeneration += 1
        resumeBackgroundWorkWaiters()
        pendingPreparationKeys.removeAll()
        pendingPreparationOperation = nil
        activePreparationKeys.removeAll()
        pendingForceRefreshLightning = false
        activeLinkPreparationKeys.removeAll()
        linkPreparationWaiters.values.flatMap(\.values).forEach { $0.finish() }
        linkPreparationWaiters.removeAll()
        pendingMessageDrainRetryTask?.cancel()
        pendingMessageDrainRetryTask = nil
        pendingMessageDrainRetrySleep?.cancel()
        pendingMessageDrainRetrySleep = nil
        pendingMessageDrainRetries.removeAll()
        pendingMessageDrainRetryGeneration += 1
    }

    func setBackgroundWorkPaused(_ paused: Bool) {
        if paused != isBackgroundWorkPaused { messageSchedulingGeneration += 1 }
        isBackgroundWorkPaused = paused
        if !paused { resumeBackgroundWorkWaiters() }
    }

    func waitForBackgroundWork(generation: Int) async -> Bool {
        while isBackgroundWorkPaused, generation == preparationGeneration, !Task.isCancelled {
            let id = UUID()
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            backgroundWorkWaiters[id] = continuation
            for await _ in stream {}
            backgroundWorkWaiters.removeValue(forKey: id)
        }
        return generation == preparationGeneration && !Task.isCancelled
    }

    private func resumeBackgroundWorkWaiters() {
        let waiters = backgroundWorkWaiters.values
        backgroundWorkWaiters.removeAll()
        waiters.forEach { $0.finish() }
    }

    func beginProfileDeletion() {
        isDeletingProfile = true
        invalidateContactPreparation()
    }

    func endProfileDeletion() {
        isDeletingProfile = false
    }

    @discardableResult
    func refreshSavedContactEndpointsReturningError(
        for publicKeys: [String],
        wallet: WalletViewModel,
        forceRefreshLightning: Bool,
        requireImmediatePublication: Bool,
        reason: String = "refresh",
        isSessionCurrent: (@MainActor () -> Bool)? = nil
    ) async -> Error? {
        if let isSessionCurrent, await !isSessionCurrent() { return nil }
        let generation = preparationGeneration
        if !requireImmediatePublication, await !waitForBackgroundWork(generation: generation) { return nil }
        let operations = endpointPublicationOperations(
            wallet: wallet,
            forceRefreshLightning: forceRefreshLightning,
            readPriority: requireImmediatePublication ? .ordered : .background
        )
        guard await operations.canPublish() else {
            await prepareRelevantPrivateLinksIfAvailable(publicKeys, reason: reason, isBackgroundWork: !requireImmediatePublication)
            return requireImmediatePublication && !publicKeys.isEmpty ? PrivatePaykitError.privateUnavailable : nil
        }
        guard generation == preparationGeneration else {
            return requireImmediatePublication ? PrivatePaykitError.privateUnavailable : nil
        }

        return await syncLocalEndpointPublication(
            for: publicKeys,
            reason: reason,
            requireImmediatePublication: requireImmediatePublication,
            isSessionCurrent: isSessionCurrent,
            operations: operations
        )
    }

    func removePublishedEndpoints(for publicKeys: [String]? = nil, isSessionCurrent: (@MainActor () -> Bool)? = nil) async throws {
        try await removePublishedEndpoints(for: publicKeys, isSessionCurrent: isSessionCurrent, operations: EndpointCleanupOperations(
            linkedPeers: { try await PaykitSdkService.shared.linkedPeers() },
            clearPaymentLists: { try await PaykitSdkService.shared.clearPrivatePaymentLists(to: $0, isSessionCurrent: isSessionCurrent) },
            drainMessages: { await self.drainPendingPrivateMessages(reason: "cleanup", advancing: $0) },
            pendingDrainKeys: { await self.pendingPrivateMessageDrainKeys($0) },
            syncApp: { try await PublicPaykitService.syncPaykitApp() }
        ))
    }

    func removePublishedEndpoints(
        for publicKeys: [String]? = nil,
        isSessionCurrent: (@MainActor () -> Bool)? = nil,
        operations: EndpointCleanupOperations
    ) async throws {
        let revision = publicKeys != nil && isSessionCurrent != nil ? savedContactsRevision : nil
        if let isSessionCurrent, await !isSessionCurrent() { throw PubkyServiceError.sessionNotActive }
        let publicKeys = publicKeys.map { normalizedSavedContactKeys($0) }
        guard publicKeys?.isEmpty != true else { return }
        if publicKeys == nil { invalidateContactPreparation() }
        let generation = preparationGeneration

        do {
            try await withPublicationLock {
                if let isSessionCurrent, await !isSessionCurrent() { throw PubkyServiceError.sessionNotActive }
                try await removePublishedEndpointsLocked(
                    for: publicKeys, isSessionCurrent: isSessionCurrent, revision: revision, generation: generation, operations: operations
                )
            }
        } catch {
            if await isSessionCurrent?() != false,
               revision == nil || (revision == savedContactsRevision && generation == preparationGeneration)
            { PublicPaykitService.setCleanupPending(true) }
            throw error
        }
    }

    private func removePublishedEndpointsLocked(
        for publicKeys: [String]?, isSessionCurrent: (@MainActor () -> Bool)?, revision: Int?, generation: Int,
        operations: EndpointCleanupOperations
    ) async throws {
        let peers = try await operations.linkedPeers()
        let linkedPublicKeys = Set(peers
            .filter { $0.state == .linked || $0.state == .linking || $0.state == .recoveryRequired }
            .compactMap { PubkyPublicKeyFormat.normalized($0.counterparty) })
        let publicKeys = publicKeys ?? normalizedSavedContactKeys(Array(
            Set(knownSavedContactKeys)
                .union(state.contacts.keys)
                .union(Self.pendingDeletedContactCleanupKeys())
                .union(linkedPublicKeys)
        ))
        let cleanupKeys = privatePaymentListCleanupKeys(publicKeys, linkedPublicKeys: linkedPublicKeys)
        let publicKeySet = Set(publicKeys)
        let cleanupStateSnapshots = Dictionary(uniqueKeysWithValues: publicKeys.map { publicKey in
            (publicKey, publishedEndpointCleanupState(publicKey: publicKey))
        })

        var firstError: Error?
        var failedPublicKeys = Set<String>()
        var clearedRetryKeys = [String]()
        if !cleanupKeys.isEmpty {
            if let isSessionCurrent, await !isSessionCurrent() { throw PubkyServiceError.sessionNotActive }
            if let revision, revision != savedContactsRevision || generation != preparationGeneration {
                throw PubkyServiceError.sessionNotActive
            }
            do {
                if let report = try await operations.clearPaymentLists(cleanupKeys) {
                    logPrivatePaymentListDeliveryFailures(report, reason: "cleanup")
                    failedPublicKeys.formUnion((report.failedToQueue.map(\.counterparty) + report.failedToDeliver.map(\.counterparty))
                        .compactMap { PubkyPublicKeyFormat.normalized($0) })
                    clearedRetryKeys = report.cleared.compactMap { PubkyPublicKeyFormat.normalized($0.counterparty) }
                        .filter { !failedPublicKeys.contains($0) }
                    if !failedPublicKeys.isEmpty { firstError = PrivatePaykitError.privateUnavailable }
                }
            } catch {
                if let isSessionCurrent, await !isSessionCurrent() { throw error }
                if let revision, revision != savedContactsRevision || generation != preparationGeneration { throw error }
                Logger.warn(
                    "Failed to clear private Paykit endpoints: \(PaykitResolutionFailureDiagnostics.reason(for: error))",
                    context: "PrivatePaykit"
                )
                failedPublicKeys.formUnion(cleanupKeys)
                firstError = error
            }
        }

        if !clearedRetryKeys.isEmpty {
            var pendingRetryKeys = await operations.pendingDrainKeys(clearedRetryKeys)
            if !pendingRetryKeys.isEmpty {
                await operations.drainMessages(Array(pendingRetryKeys))
                pendingRetryKeys = await operations.pendingDrainKeys(clearedRetryKeys)
            }
            if !pendingRetryKeys.isEmpty {
                Logger.warn(
                    "Private Paykit endpoint withdrawal remains pending for \(pendingRetryKeys.map(PubkyPublicKeyFormat.redacted))",
                    context: "PrivatePaykit"
                )
                failedPublicKeys.formUnion(pendingRetryKeys)
                firstError = firstError ?? PrivatePaykitError.privateUnavailable
            }
        }

        if let isSessionCurrent, await !isSessionCurrent() { throw PubkyServiceError.sessionNotActive }
        if let revision, revision != savedContactsRevision || generation != preparationGeneration {
            throw PubkyServiceError.sessionNotActive
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
        try await operations.syncApp()
    }

    func privatePaymentListCleanupKeys(_ publicKeys: [String], linkedPublicKeys: Set<String>) -> [String] {
        publicKeys.filter {
            linkedPublicKeys.contains($0) || state.contacts[$0]?.hasPublishedPrivatePaymentList == true
        }
    }

    func removeSavedContact(publicKey: String) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        savedContactsRevision += 1
        knownSavedContactKeys.remove(normalizedKey)
        pendingMessageDrainRetries[normalizedKey] = nil
        unavailableLinkRetryAt[normalizedKey] = nil
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
        savedContactsRevision += 1
        for publicKey in normalizedKeys {
            knownSavedContactKeys.remove(publicKey)
            pendingMessageDrainRetries[publicKey] = nil
            unavailableLinkRetryAt[publicKey] = nil
        }
        if isDeletingProfile {
            await clearContactStates(publicKeys: normalizedKeys)
            return
        }
        Self.markDeletedContactCleanupPending(normalizedKeys)
        do {
            try await removePublishedEndpoints(for: normalizedKeys)
            await clearContactStates(publicKeys: normalizedKeys)
        } catch {
            Logger.warn("Failed to remove private Paykit endpoints for deleted contacts: \(error)", context: "PrivatePaykit")
        }
    }

    func pruneUnsavedContactState(
        savedPublicKeys publicKeys: [String], isSessionCurrent: (@MainActor () -> Bool)? = nil
    ) async {
        let revision = savedContactsRevision
        let generation = preparationGeneration
        if let isSessionCurrent, await !isSessionCurrent() { return }
        guard revision == savedContactsRevision, generation == preparationGeneration else { return }
        let savedKeys = Set(rememberSavedContacts(publicKeys, replacing: true))
        let cleanupRevision = savedContactsRevision

        let staleKeys: Set<String> = Set(state.contacts.compactMap { publicKey, contactState in
            guard !savedKeys.contains(publicKey), contactState.hasContactOwnedCacheState else { return nil }
            return publicKey
        })
        let cleanupKeys = staleKeys.union(Self.pendingDeletedContactCleanupKeys().subtracting(savedKeys))
        guard !cleanupKeys.isEmpty else { return }

        if isDeletingProfile {
            await clearContactStates(publicKeys: Array(staleKeys))
            return
        }

        do {
            try await removePublishedEndpoints(for: Array(cleanupKeys), isSessionCurrent: isSessionCurrent)
            try await withPublicationLock {
                if let isSessionCurrent, await !isSessionCurrent() { return }
                guard cleanupRevision == savedContactsRevision, generation == preparationGeneration else { return }
                await clearContactStates(publicKeys: Array(staleKeys))
            }
        } catch {
            if let isSessionCurrent, await !isSessionCurrent() { return }
            guard cleanupRevision == savedContactsRevision, generation == preparationGeneration else { return }
            Logger.warn("Failed to prune private Paykit endpoints for unsaved contacts: \(error)", context: "PrivatePaykit")
        }
    }

    func retryPendingEndpointReconciliation(wallet: WalletViewModel, savedPublicKeys publicKeys: [String]) async {
        guard !isDeletingProfile else { return }
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
            let error = await resumeEndpointPublication {
                await self.refreshSavedContactEndpointsReturningError(
                    for: publicKeys,
                    wallet: wallet,
                    forceRefreshLightning: false,
                    requireImmediatePublication: true,
                    reason: "reconcile"
                )
            }
            if let error {
                Logger.warn("Failed to reconcile private Paykit endpoints: \(error)", context: "PrivatePaykit")
            }
            return
        }

        let cleanupKeys = isFullCleanupPending
            ? Set(knownSavedContactKeys).union(state.contacts.keys).union(Self.pendingDeletedContactCleanupKeys())
            : Set(pendingPrivateEndpointRemovalKeys(savedPublicKeys: publicKeys))

        guard isFullCleanupPending || !cleanupKeys.isEmpty else { return }

        do {
            try await removePublishedEndpoints(for: isFullCleanupPending ? nil : Array(cleanupKeys))
            await clearContactStates(publicKeys: Array(cleanupKeys.subtracting(savedKeys)))
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

    func resumeEndpointPublication(_ publish: () async -> Error?) async -> Error? {
        let generation = preparationGeneration
        Self.setContactSharingCleanupPending(false)
        let error = await publish()
        if error != nil, generation == preparationGeneration {
            Self.setContactSharingCleanupPending(true)
        }
        return error
    }

    private func syncLocalEndpointPublication(
        for publicKeys: [String],
        wallet: WalletViewModel,
        reason: String,
        forceRefreshLightning: Bool = false,
        requireImmediatePublication: Bool,
        isSessionCurrent: (@MainActor () -> Bool)? = nil
    ) async -> Error? {
        let operations = endpointPublicationOperations(
            wallet: wallet,
            forceRefreshLightning: forceRefreshLightning,
            readPriority: requireImmediatePublication ? .ordered : .background
        )
        return await syncLocalEndpointPublication(
            for: publicKeys,
            reason: reason,
            requireImmediatePublication: requireImmediatePublication,
            isSessionCurrent: isSessionCurrent,
            operations: operations
        )
    }

    private func endpointPublicationOperations(
        wallet: WalletViewModel,
        forceRefreshLightning: Bool,
        readPriority: PaykitSdkOperationLock.Priority
    ) -> EndpointPublicationOperations {
        if let publicationOperations { return publicationOperations }
        return EndpointPublicationOperations(
            currentPublicKey: {
                await PubkyService.currentPublicKey()
            },
            ensureLink: { publicKey in
                try await PaykitSdkService.shared.ensureLinkWithPeer(publicKey, priority: readPriority).state
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
            },
            linkedPeers: { try await PaykitSdkService.shared.linkedPeers(priority: readPriority) },
            canPublish: { await self.canPublishPrivateEndpoints(wallet: wallet) }
        )
    }

    func syncLocalEndpointPublication(
        for publicKeys: [String],
        reason: String,
        requireImmediatePublication: Bool,
        isSessionCurrent: (@MainActor () -> Bool)? = nil,
        operations: EndpointPublicationOperations
    ) async -> Error? {
        let publicKeys = normalizedSavedContactKeys(publicKeys)
        guard !publicKeys.isEmpty else { return nil }

        let generation = preparationGeneration
        if !requireImmediatePublication, await !waitForBackgroundWork(generation: generation) { return nil }
        guard let identity = await operations.currentPublicKey() else {
            return requireImmediatePublication ? PubkyServiceError.sessionNotActive : nil
        }

        var firstError: Error?
        var preparedKeys = [String]()
        var linkRetryKeys = [String]()
        let peerStates: [String: LinkedPeerState]
        do {
            if !requireImmediatePublication, await !waitForBackgroundWork(generation: generation) { return nil }
            peerStates = try await Dictionary(uniqueKeysWithValues: operations.linkedPeers().map { ($0.counterparty, $0.state) })
        } catch {
            Logger.warn("Failed to read private Paykit links during \(reason): \(error)", context: "PrivatePaykit")
            return requireImmediatePublication ? error : nil
        }

        for publicKey in publicKeys {
            if !requireImmediatePublication, await !waitForBackgroundWork(generation: generation) { return nil }
            guard generation == preparationGeneration else { break }
            guard knownSavedContactKeys.contains(publicKey), !UserDefaults.standard.bool(forKey: Self.cleanupPendingKey) else { continue }
            if peerStates[publicKey] == .blocked { continue }
            if !requireImmediatePublication, let retryAt = unavailableLinkRetryAt[publicKey], retryAt > messageRetryOperations.now() { continue }
            do {
                if peerStates[publicKey] != .linked,
                   try await withLinkPreparation(publicKey, operation: { try await operations.ensureLink(publicKey) }) != .linked
                {
                    linkRetryKeys.append(publicKey)
                }
                unavailableLinkRetryAt[publicKey] = nil
            } catch PaykitError.NotFound {
                unavailableLinkRetryAt[publicKey] = messageRetryOperations.now().addingTimeInterval(5 * 60)
                continue
            } catch {
                if case PaykitError.Transport = error {
                    unavailableLinkRetryAt[publicKey] = nil
                    if !requireImmediatePublication, await !waitForBackgroundWork(generation: generation) { return nil }
                    if let peers = try? await operations.linkedPeers() {
                        let state = peers.first { $0.counterparty == publicKey }?.state
                        if state == nil || state == .notLinked {
                            unavailableLinkRetryAt[publicKey] = messageRetryOperations.now().addingTimeInterval(5 * 60)
                        }
                    }
                }
                Logger.warn(
                    "Failed to prepare private Paykit link for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): \(error)",
                    context: "PrivatePaykit"
                )
                linkRetryKeys.append(publicKey)
                continue
            }
            preparedKeys.append(publicKey)
        }

        do {
            if !requireImmediatePublication, await !waitForBackgroundWork(generation: generation) { return nil }
            // Do not wait for foreground while holding a publication batch.
            try await withPublicationLock {
                if let isSessionCurrent, await !isSessionCurrent() { throw PubkyServiceError.sessionNotActive }
                guard generation == preparationGeneration,
                      await operations.currentPublicKey() == identity,
                      !UserDefaults.standard.bool(forKey: Self.cleanupPendingKey)
                else { throw PrivatePaykitError.privateUnavailable }
                var updates = [PrivatePaymentListReservationUpdateInput]()
                for publicKey in preparedKeys {
                    guard generation == preparationGeneration else { throw PrivatePaykitError.privateUnavailable }
                    guard knownSavedContactKeys.contains(publicKey) else { continue }
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
                updates.removeAll { !knownSavedContactKeys.contains($0.counterparty) }
                guard generation == preparationGeneration else { throw PrivatePaykitError.privateUnavailable }
                guard !updates.isEmpty else {
                    schedulePendingPrivateMessageDrainRetries(reason: reason, retryKeys: linkRetryKeys)
                    return
                }
                let report = try await operations.syncPaymentLists(updates)
                let deliveryError = applyPrivatePaymentListDeliveryReport(report, reason: reason)
                firstError = firstError ?? deliveryError
                let retryKeys = linkRetryKeys + privatePaymentListDeliveryRetryKeys(from: report)
                schedulePendingPrivateMessageDrainRetries(reason: reason, retryKeys: retryKeys)
            }
        } catch {
            Logger.warn("Failed to sync private Paykit endpoint publications during \(reason): \(error)", context: "PrivatePaykit")
            firstError = firstError ?? error
            if !linkRetryKeys.isEmpty {
                let sessionIsCurrent = await isSessionCurrent?() ?? true
                let currentIdentity = await operations.currentPublicKey()
                if !Task.isCancelled, sessionIsCurrent, generation == preparationGeneration, currentIdentity == identity,
                   !UserDefaults.standard.bool(forKey: Self.cleanupPendingKey)
                {
                    schedulePendingPrivateMessageDrainRetries(
                        reason: reason, retryKeys: linkRetryKeys.filter { knownSavedContactKeys.contains($0) }
                    )
                }
            }
        }

        return requireImmediatePublication ? firstError : nil
    }

    private func prepareRelevantPrivateLinksIfAvailable(_ publicKeys: [String], reason: String, isBackgroundWork: Bool = false) async {
        let generation = preparationGeneration
        if isBackgroundWork, await !waitForBackgroundWork(generation: generation) { return }
        guard !UserDefaults.standard.bool(forKey: Self.cleanupPendingKey), await canUsePrivateLinks() else { return }
        guard generation == preparationGeneration, !Task.isCancelled else { return }

        await drainAndSchedulePrivateLinkRetries(
            reason: reason,
            retryKeys: normalizedSavedContactKeys(publicKeys),
            isBackgroundWork: isBackgroundWork
        )
    }

    private func canUsePrivateLinks() async -> Bool {
        guard PaykitFeatureFlags.isUIEnabled,
              let ownPublicKey = await PubkyService.currentPublicKey()
        else { return false }

        return PubkyProfileManager.hasLocalSecretKey(for: ownPublicKey)
    }

    private func drainAndSchedulePrivateLinkRetries(reason: String, retryKeys: [String], isBackgroundWork: Bool) async {
        let generation = preparationGeneration
        let priority: PaykitSdkOperationLock.Priority = isBackgroundWork ? .background : .ordered
        let retryKeys = Array(Set(retryKeys).subtracting(pendingMessageDrainRetryKeys))
        guard !retryKeys.isEmpty else { return }

        let drainKeys = await pendingPrivateMessageDrainKeys(retryKeys, retryMissingPeers: true, priority: priority)
        guard generation == preparationGeneration, !Task.isCancelled, !drainKeys.isEmpty else { return }

        await drainPendingPrivateMessages(
            reason: reason, advancing: Array(drainKeys), isBackgroundWork: isBackgroundWork, operations: .live(readPriority: priority)
        )
        let pendingRetryKeys = await pendingPrivateMessageDrainKeys(Array(drainKeys), priority: priority)
        guard generation == preparationGeneration, !Task.isCancelled else { return }
        if !pendingRetryKeys.isEmpty {
            schedulePendingPrivateMessageDrainRetries(reason: reason, retryKeys: Array(pendingRetryKeys))
        }
    }

    private func privatePaymentListDeliveryRetryKeys(from report: PrivatePaymentListDeliveryReport) -> [String] {
        normalizedSavedContactKeys((report.queued + report.cleared).map(\.counterparty) + report.failedToDeliver.map(\.counterparty))
    }

    func drainPendingPrivateMessages(
        reason: String,
        advancing retryKeys: [String],
        isBackgroundWork: Bool = false,
        operations: PrivateMessageDrainOperations = .live(),
        schedulingSnapshot: PrivateMessageSchedulingSnapshot? = nil,
        isCurrent: () async -> Bool = { true },
        onReceived: (Set<String>) -> Void = { _ in }
    ) async {
        var retryKeys = Set(retryKeys.map { PubkyPublicKeyFormat.normalized($0) ?? $0 })
        guard !retryKeys.isEmpty, !Task.isCancelled else { return }
        let generation = preparationGeneration
        var receivedKeys = Set<String>()
        do {
            if isBackgroundWork, await !waitForBackgroundWork(generation: generation) { return }
            guard await isCurrent() else { return }
            let peers: [LinkedPeerRecord] = if let schedulingSnapshot, isSchedulingSnapshotCurrent(schedulingSnapshot) {
                schedulingSnapshot.peers
            } else {
                try await operations.linkedPeers()
            }
            retryKeys.subtract(peers.filter { $0.state == .blocked || $0.state == .unknown }.map {
                PubkyPublicKeyFormat.normalized($0.counterparty) ?? $0.counterparty
            })
            let alreadyLinkedKeys = Set(peers.filter { $0.state == .linked }.map {
                PubkyPublicKeyFormat.normalized($0.counterparty) ?? $0.counterparty
            })
            for retryKey in retryKeys.sorted() {
                if isBackgroundWork, await !waitForBackgroundWork(generation: generation) { return }
                guard generation == preparationGeneration, !Task.isCancelled, await isCurrent() else { return }
                if alreadyLinkedKeys.contains(retryKey) { continue }
                if let retryAt = unavailableLinkRetryAt[retryKey], retryAt > messageRetryOperations.now() { continue }
                do {
                    _ = try await withLinkPreparation(retryKey) { try await operations.ensureLink(retryKey) }
                } catch PaykitError.NotFound {
                    if generation == preparationGeneration, !Task.isCancelled {
                        unavailableLinkRetryAt[retryKey] = messageRetryOperations.now().addingTimeInterval(5 * 60)
                    }
                } catch {
                    Logger.warn(
                        "Failed to advance private Paykit link for \(PubkyPublicKeyFormat.redacted(retryKey)) during \(reason): \(error)",
                        context: "PrivatePaykit"
                    )
                }
            }
            if isBackgroundWork, await !waitForBackgroundWork(generation: generation) { return }
            guard generation == preparationGeneration, !Task.isCancelled, await isCurrent() else { return }
            let pendingKeys = try await retryKeys.intersection(operations.pendingOutbound().map { PubkyPublicKeyFormat.normalized($0) ?? $0 })
            for publicKey in pendingKeys.sorted() {
                if isBackgroundWork, await !waitForBackgroundWork(generation: generation) { return }
                guard generation == preparationGeneration, !Task.isCancelled, await isCurrent() else { return }
                do {
                    try await operations.processPending(publicKey)
                } catch {
                    Logger.warn(
                        "Failed to send private Paykit messages during \(reason): \(PaykitResolutionFailureDiagnostics.reason(for: error))",
                        context: "PrivatePaykit"
                    )
                }
            }
            if isBackgroundWork, await !waitForBackgroundWork(generation: generation) { return }
            guard generation == preparationGeneration, !Task.isCancelled, await isCurrent() else { return }
            let linkedKeys = try await Set(operations.linkedPeers().filter { $0.state == .linked }.map {
                PubkyPublicKeyFormat.normalized($0.counterparty) ?? $0.counterparty
            })
            for publicKey in retryKeys.intersection(linkedKeys).sorted() {
                if isBackgroundWork, await !waitForBackgroundWork(generation: generation) { return }
                guard generation == preparationGeneration, !Task.isCancelled, await isCurrent() else { return }
                do {
                    try await operations.receive(publicKey)
                    receivedKeys.insert(publicKey)
                } catch {
                    Logger.warn(
                        "Failed to receive private Paykit messages during \(reason): \(PaykitResolutionFailureDiagnostics.reason(for: error))",
                        context: "PrivatePaykit"
                    )
                }
            }
        } catch {
            Logger.warn("Failed to process pending private Paykit messages during \(reason): \(error)", context: "PrivatePaykit")
        }
        onReceived(receivedKeys)
    }

    private func withLinkPreparation<T>(_ publicKey: String, operation: () async throws -> T) async throws -> T? {
        try Task.checkCancellation()
        guard activeLinkPreparationKeys.insert(publicKey).inserted else { return nil }
        let generation = preparationGeneration
        defer {
            if generation == preparationGeneration {
                messageSchedulingGeneration += 1
                activeLinkPreparationKeys.remove(publicKey)
                linkPreparationWaiters.removeValue(forKey: publicKey)?.values.forEach { $0.finish() }
            }
        }
        return try await operation()
    }

    private func schedulePendingPrivateMessageDrainRetries(reason: String, retryKeys: [String]) {
        guard !isDeletingProfile, !retryKeys.isEmpty else { return }
        let now = messageRetryOperations.now()
        for key in retryKeys where pendingMessageDrainRetries[key] == nil {
            pendingMessageDrainRetries[key] = PrivateMessageRetry(nextAttemptAt: now.addingTimeInterval(1))
        }
        startPendingPrivateMessageDrainRetries(reason: reason)
    }

    func startExplicitContactLink(publicKey: String, expectedIdentity: String?, wallet: WalletViewModel) {
        let generation = preparationGeneration
        let startedAt = messageRetryOperations.now()
        guard let publicKey = PubkyPublicKeyFormat.normalized(publicKey),
              let expectedIdentity = expectedIdentity.flatMap(PubkyPublicKeyFormat.normalized),
              PaykitFeatureFlags.isUIEnabled, PubkyProfileManager.hasLocalSecretKey(for: expectedIdentity),
              !isDeletingProfile, !Task.isCancelled
        else { return }
        _ = rememberSavedContacts([publicKey], replacing: false)
        scheduleExplicitContactLink(publicKey: publicKey, identity: expectedIdentity, startedAt: startedAt)
        Task {
            do {
                guard await waitForBackgroundWork(generation: generation),
                      let identity = try await messageRetryOperations.currentPublicKey(
                          messageRetryOperations.now().timeIntervalSince(startedAt) < 20 ? .interactive : .background
                      ),
                      PubkyPublicKeyFormat.matches(identity, expectedIdentity), generation == preparationGeneration,
                      !Task.isCancelled, knownSavedContactKeys.contains(publicKey)
                else { return }
                scheduleContactPreparation([publicKey], wallet: wallet)
            } catch {
                Logger.warn(
                    "Failed to inspect private Paykit identity during contact preparation: \(PaykitResolutionFailureDiagnostics.reason(for: error))",
                    context: "PrivatePaykit"
                )
            }
        }
    }

    func scheduleExplicitContactLink(publicKey: String, identity: String, startedAt: Date? = nil) {
        guard !isDeletingProfile, knownSavedContactKeys.contains(publicKey),
              !UserDefaults.standard.bool(forKey: Self.cleanupPendingKey)
        else { return }
        let now = messageRetryOperations.now()
        var retry = pendingMessageDrainRetries[publicKey] ?? PrivateMessageRetry(nextAttemptAt: now)
        guard retry.priority(at: now) != .interactive else { return }
        retry.foregroundUntil = (startedAt ?? now).addingTimeInterval(20)
        retry.expectedIdentity = identity
        retry.nextAttemptAt = now
        retry.retryIndex = -1
        unavailableLinkRetryAt[publicKey] = nil
        pendingMessageDrainRetries[publicKey] = retry
        startPendingPrivateMessageDrainRetries(reason: "contact link")
    }

    private func startPendingPrivateMessageDrainRetries(reason: String) {
        // Wake only the timer. An admitted SDK operation keeps ownership until it completes.
        pendingMessageDrainRetrySleep?.cancel()
        guard pendingMessageDrainRetryTask == nil else { return }
        pendingMessageDrainRetryGeneration += 1
        let retryGeneration = pendingMessageDrainRetryGeneration
        pendingMessageDrainRetryTask = Task { [reason, retryGeneration] in
            var foregroundAttempts = 0
            var schedulingSnapshot: PrivateMessageSchedulingSnapshot?
            while !Task.isCancelled, retryGeneration == pendingMessageDrainRetryGeneration {
                guard await waitForBackgroundWork(generation: preparationGeneration) else { break }
                guard retryGeneration == pendingMessageDrainRetryGeneration else { return }
                let now = messageRetryOperations.now()
                let due = pendingMessageDrainRetries.filter { $0.value.nextAttemptAt <= now }
                let foreground = due.filter { $0.value.priority(at: now) == .interactive }
                let background = due.filter { $0.value.priority(at: now) == .background }
                let candidates = !foreground.isEmpty && (foregroundAttempts < 3 || background.isEmpty)
                    ? foreground : (background.isEmpty ? pendingMessageDrainRetries : background)
                guard let next = candidates.min(by: {
                    if $0.value.nextAttemptAt == $1.value.nextAttemptAt { return $0.key < $1.key }
                    return $0.value.nextAttemptAt < $1.value.nextAttemptAt
                }) else { break }
                let delay = next.value.nextAttemptAt.timeIntervalSince(now)
                if delay > 0 {
                    schedulingSnapshot = nil
                    let sleep = messageRetryOperations.sleep
                    let timer = Task { _ = try? await sleep(UInt64(delay * 1_000_000_000)) }
                    pendingMessageDrainRetrySleep = timer
                    await timer.value
                    guard retryGeneration == pendingMessageDrainRetryGeneration else { return }
                    pendingMessageDrainRetrySleep = nil
                    continue
                }
                foregroundAttempts = next.value.priority(at: now) == .interactive ? foregroundAttempts + 1 : 0
                await drainPendingPrivateMessageRetry(publicKey: next.key, reason: "\(reason) retry", schedulingSnapshot: &schedulingSnapshot)
            }
            guard retryGeneration == pendingMessageDrainRetryGeneration else { return }
            pendingMessageDrainRetryTask = nil
        }
    }

    func schedulePrivatePaymentRecovery(for publicKey: String) {
        guard let publicKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        schedulePendingPrivateMessageDrainRetries(
            reason: "payment recovery",
            retryKeys: [publicKey]
        )
    }

    private func drainPendingPrivateMessageRetry(
        publicKey: String, reason: String, schedulingSnapshot: inout PrivateMessageSchedulingSnapshot?
    ) async {
        guard let retry = pendingMessageDrainRetries[publicKey] else { return }
        let generation = preparationGeneration
        var identityInspectionFailed = false
        var inspectedSchedulingGeneration: Int?
        defer {
            if identityInspectionFailed, isMessageRetryCurrent(publicKey: publicKey, id: retry.id, generation: generation),
               pendingMessageDrainRetries[publicKey]?.foregroundUntil == retry.foregroundUntil
            {
                pendingMessageDrainRetries[publicKey]?.completeAttempt(at: messageRetryOperations.now())
            }
        }
        let isCurrent: () async -> Bool = {
            guard !identityInspectionFailed, await self.waitForBackgroundWork(generation: generation) else { return false }
            if let identity = retry.expectedIdentity {
                while inspectedSchedulingGeneration != self.messageSchedulingGeneration {
                    let schedulingGeneration = self.messageSchedulingGeneration
                    let priority = retry.priority(at: self.messageRetryOperations.now())
                    do {
                        guard try await self.messageRetryOperations.currentPublicKey(priority) == identity else { return false }
                    } catch {
                        identityInspectionFailed = true
                        Logger.warn(
                            "Failed to inspect private Paykit identity during \(reason): \(PaykitResolutionFailureDiagnostics.reason(for: error))",
                            context: "PrivatePaykit"
                        )
                        return false
                    }
                    guard await self.waitForBackgroundWork(generation: generation) else { return false }
                    inspectedSchedulingGeneration = schedulingGeneration
                }
                guard self.knownSavedContactKeys.contains(publicKey) else { return false }
            }
            return self.isMessageRetryCurrent(publicKey: publicKey, id: retry.id, generation: generation)
        }
        guard await isCurrent() else {
            if !identityInspectionFailed, pendingMessageDrainRetries[publicKey]?.id == retry.id { pendingMessageDrainRetries[publicKey] = nil }
            return
        }
        while activeLinkPreparationKeys.contains(publicKey) {
            schedulingSnapshot = nil
            inspectedSchedulingGeneration = nil
            let id = UUID()
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            linkPreparationWaiters[publicKey, default: [:]][id] = continuation
            for await _ in stream {}
            linkPreparationWaiters[publicKey]?[id] = nil
            guard await isCurrent() else { return }
        }
        var linkUnavailable = false
        // Another identity operation can run while any SDK call, including a read, is suspended.
        let operations = PrivateMessageDrainOperations(
            ensureLink: {
                defer { inspectedSchedulingGeneration = nil }
                do {
                    try await self.retryDrainOperations(for: publicKey).ensureLink($0)
                } catch {
                    if case PaykitError.NotFound = error { linkUnavailable = true }
                    throw error
                }
            },
            pendingOutbound: {
                defer { inspectedSchedulingGeneration = nil }
                return try await self.retryDrainOperations(for: publicKey).pendingOutbound()
            },
            linkedPeers: {
                defer { inspectedSchedulingGeneration = nil }
                return try await self.retryDrainOperations(for: publicKey).linkedPeers()
            },
            processPending: {
                defer { inspectedSchedulingGeneration = nil }
                try await self.retryDrainOperations(for: publicKey).processPending($0)
            },
            receive: {
                defer { inspectedSchedulingGeneration = nil }
                try await self.retryDrainOperations(for: publicKey).receive($0)
            }
        )
        if let snapshot = schedulingSnapshot,
           !isSchedulingSnapshotCurrent(snapshot) || snapshot.expectedIdentity != retry.expectedIdentity
        {
            schedulingSnapshot = nil
        }
        let drainKeys: Set<String>
        if retry.expectedIdentity != nil {
            drainKeys = [publicKey]
        } else {
            if schedulingSnapshot == nil {
                schedulingSnapshot = await readPrivateMessageSchedulingSnapshot(priority: .background, operations: operations, isCurrent: isCurrent)
            }
            drainKeys = schedulingSnapshot?.drainKeys([publicKey]) ?? [publicKey]
        }
        guard await isCurrent() else { return }
        var received = Set<String>()
        await drainPendingPrivateMessages(
            reason: reason, advancing: Array(drainKeys),
            isBackgroundWork: true, operations: operations, schedulingSnapshot: schedulingSnapshot,
            isCurrent: isCurrent, onReceived: { received = $0 }
        )
        guard await waitForBackgroundWork(generation: generation), await isCurrent() else { return }
        // Post-mutation reads stay fresh; only the next due peer's scheduling can reuse them.
        schedulingSnapshot = await readPrivateMessageSchedulingSnapshot(
            priority: .background, operations: operations, isCurrent: isCurrent
        )
        schedulingSnapshot?.expectedIdentity = retry.expectedIdentity
        let remainingKeys = schedulingSnapshot?.drainKeys(
            [publicKey], retryMissingPeers: retry.expectedIdentity != nil && !linkUnavailable
        ) ?? [publicKey]
        guard await isCurrent() else { return }
        guard pendingMessageDrainRetries[publicKey]?.foregroundUntil == retry.foregroundUntil else { return }
        let needsForegroundIntake = !linkUnavailable && retry.priority(at: messageRetryOperations.now()) == .interactive && !received
            .contains(publicKey)
        if remainingKeys.isEmpty, !needsForegroundIntake {
            pendingMessageDrainRetries[publicKey] = nil
            if retry.priority(at: messageRetryOperations.now()) == .interactive,
               received.contains(publicKey), let identity = retry.expectedIdentity
            {
                await messageRetryOperations.didLink(identity, publicKey)
            }
        } else {
            pendingMessageDrainRetries[publicKey]?.completeAttempt(at: messageRetryOperations.now())
        }
    }

    private func isMessageRetryCurrent(publicKey: String, id: UUID, generation: Int) -> Bool {
        generation == preparationGeneration && pendingMessageDrainRetries[publicKey]?.id == id && !Task.isCancelled
    }

    private func retryDrainOperations(for publicKey: String) -> PrivateMessageDrainOperations {
        let priority = pendingMessageDrainRetries[publicKey]?.priority(at: messageRetryOperations.now()) ?? .background
        return messageRetryOperations.drain(priority)
    }

    private func isSchedulingSnapshotCurrent(_ snapshot: PrivateMessageSchedulingSnapshot) -> Bool {
        snapshot.preparationGeneration == preparationGeneration && snapshot.schedulingGeneration == messageSchedulingGeneration &&
            activeLinkPreparationKeys.isEmpty
    }

    private func pendingPrivateMessageDrainKeys(
        _ retryKeys: [String],
        retryMissingPeers: Bool = false,
        priority: PaykitSdkOperationLock.Priority = .ordered,
        operations: PrivateMessageDrainOperations? = nil,
        isCurrent: () async -> Bool = { true }
    ) async -> Set<String> {
        let retryKeys = Set(retryKeys)
        guard !retryKeys.isEmpty else { return [] }
        let operations = operations ?? .live(readPriority: priority)
        let snapshot = await readPrivateMessageSchedulingSnapshot(priority: priority, operations: operations, isCurrent: isCurrent)
        return snapshot?.drainKeys(retryKeys, retryMissingPeers: retryMissingPeers) ?? retryKeys
    }

    private func readPrivateMessageSchedulingSnapshot(
        priority: PaykitSdkOperationLock.Priority,
        operations: PrivateMessageDrainOperations,
        isCurrent: () async -> Bool
    ) async -> PrivateMessageSchedulingSnapshot? {
        let generation = preparationGeneration
        let schedulingGeneration = messageSchedulingGeneration

        let peers: [LinkedPeerRecord]
        do {
            if priority == .background, await !waitForBackgroundWork(generation: generation) { return nil }
            guard await isCurrent() else { return nil }
            peers = try await operations.linkedPeers()
        } catch {
            Logger.warn("Failed to inspect private Paykit link state: \(error)", context: "PrivatePaykit")
            return nil
        }

        let pendingOutbound: Set<String>
        do {
            if priority == .background, await !waitForBackgroundWork(generation: generation) { return nil }
            guard await isCurrent() else { return nil }
            let pending = try await operations.pendingOutbound()
            pendingOutbound = Set(pending.compactMap(PubkyPublicKeyFormat.normalized))
        } catch {
            Logger.warn("Failed to inspect pending private Paykit messages: \(error)", context: "PrivatePaykit")
            return nil
        }

        return PrivateMessageSchedulingSnapshot(
            peers: peers, pendingOutbound: pendingOutbound, preparationGeneration: generation, schedulingGeneration: schedulingGeneration
        )
    }

    static func pendingPrivateMessageDrainKeys(
        _ retryKeys: Set<String>,
        linkedPeers: [String: LinkedPeerState],
        pendingOutbound: Set<String>,
        retryMissingPeers: Bool = false
    ) -> Set<String> {
        return Set(retryKeys.filter { retryKey in
            guard let state = linkedPeers[retryKey] else {
                return retryMissingPeers || pendingOutbound.contains(retryKey)
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
        logPrivatePaymentListDeliveryFailures(report, reason: reason)
        var didChangeState = false

        for change in report.queued {
            guard let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) else { continue }
            didChangeState = recordPublishedPrivatePaymentList(publicKey: publicKey) || didChangeState
        }

        for change in report.cleared {
            guard let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) else { continue }
            didChangeState = clearPublishedPrivatePaymentList(publicKey: publicKey) || didChangeState
        }

        if didChangeState {
            persistState(markWalletBackup: true)
        }

        return report.failedToQueue.isEmpty && report.failedToDeliver.isEmpty ? nil : PrivatePaykitError.privateUnavailable
    }

    private func logPrivatePaymentListDeliveryFailures(_ report: PrivatePaymentListDeliveryReport, reason: String) {
        for change in report.failedToQueue {
            let publicKey = PubkyPublicKeyFormat.normalized(change.counterparty) ?? change.counterparty
            Logger.warn(
                "Failed to queue private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): " +
                    "\(change.error?.redactedContext() ?? "unknown error")",
                context: "PrivatePaykit"
            )
        }

        for failure in report.failedToDeliver {
            let publicKey = PubkyPublicKeyFormat.normalized(failure.counterparty) ?? failure.counterparty
            Logger.warn(
                "Failed to deliver private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(publicKey)) during \(reason): " +
                    failure.error.redactedContext(),
                context: "PrivatePaykit"
            )
        }
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
        let previousKeys = knownSavedContactKeys
        let normalizedKeys = normalizedSavedContactKeys(publicKeys)
        if replacing {
            knownSavedContactKeys = Set(normalizedKeys)
            unavailableLinkRetryAt = unavailableLinkRetryAt.filter { knownSavedContactKeys.contains($0.key) }
        } else {
            knownSavedContactKeys.formUnion(normalizedKeys)
        }
        if knownSavedContactKeys != previousKeys { savedContactsRevision += 1 }
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
