import Foundation

// MARK: - Saved Contacts

extension PrivatePaykitService {
    func prepareSavedContacts(_ publicKeys: [String], wallet: WalletViewModel) async {
        let publicKeys = rememberSavedContacts(publicKeys, replacing: true)
        guard await canPublishPrivateEndpoints(wallet: wallet) else { return }
        await PrivatePaykitAddressReservationStore.shared.reconcileReservedIndexesWithLdk()
        await publishLocalEndpoints(for: publicKeys, wallet: wallet, maxAdvanceSteps: 3, reason: "prepare")
    }

    func refreshSavedContactEndpoints(for publicKeys: [String], wallet: WalletViewModel) async {
        let publicKeys = rememberSavedContacts(publicKeys, replacing: true)
        guard await canPublishPrivateEndpoints(wallet: wallet) else { return }
        await publishLocalEndpoints(for: publicKeys, wallet: wallet, maxAdvanceSteps: 1, reason: "refresh")
    }

    func refreshKnownSavedContactEndpoints(wallet: WalletViewModel, reason: String) async {
        guard !knownSavedContactKeys.isEmpty else { return }
        guard await canPublishPrivateEndpoints(wallet: wallet) else { return }
        await publishLocalEndpoints(for: Array(knownSavedContactKeys), wallet: wallet, maxAdvanceSteps: 1, reason: reason)
    }

    func removePublishedEndpoints() async throws {
        invalidateLinkEstablishmentWork()
        let publicKeys = Array(state.contacts.keys)
        var firstError: Error?

        for publicKey in publicKeys {
            let generation = stateGeneration
            do {
                try await removePublishedEndpoints(for: publicKey, generation: generation)
            } catch {
                await recordLinkFailure(publicKey: publicKey, error: error, generation: generation)
                if firstError == nil {
                    firstError = error
                }
                Logger.warn(
                    "Failed to remove private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }

        if let firstError {
            throw firstError
        }
    }

    func removeSavedContact(publicKey: String) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        invalidateLinkEstablishment(for: normalizedKey)
        knownSavedContactKeys.remove(normalizedKey)
        let generation = stateGeneration

        do {
            try await removePublishedEndpoints(for: normalizedKey, generation: generation)
        } catch {
            await recordLinkFailure(publicKey: normalizedKey, error: error, generation: generation)
            Self.setContactSharingCleanupPending(true)
            Logger.warn(
                "Failed to tombstone private Paykit endpoints for removed contact \(PubkyPublicKeyFormat.redacted(normalizedKey)): \(error)",
                context: "PrivatePaykit"
            )
            return
        }

        await clearContactState(publicKey: normalizedKey)
        await PrivatePaykitAddressReservationStore.shared.clearContactAssignment(publicKey: normalizedKey)
    }

    func removeSavedContacts(publicKeys: [String]) async {
        for publicKey in normalizedSavedContactKeys(publicKeys) {
            await removeSavedContact(publicKey: publicKey)
        }
    }

    func pruneUnsavedContactState(savedPublicKeys publicKeys: [String]) async {
        let savedKeys = Set(rememberSavedContacts(publicKeys, replacing: true))
        let staleKeys = state.contacts.keys.filter { !savedKeys.contains($0) }

        for publicKey in staleKeys {
            await removeSavedContact(publicKey: publicKey)
        }

        await PrivatePaykitAddressReservationStore.shared.clearContactAssignments(excludingPublicKeys: Array(savedKeys))
    }

    func retryPendingEndpointRemoval(wallet: WalletViewModel, savedPublicKeys: [String]) async {
        guard UserDefaults.standard.bool(forKey: Self.cleanupPendingKey) else { return }

        do {
            try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: false)
            try await removePublishedEndpoints()
            await clearUnsavedContactState(savedPublicKeys: savedPublicKeys)
            Self.setContactSharingCleanupPending(false)
        } catch {
            Logger.warn("Failed to retry pending Paykit contact endpoint removal: \(error)", context: "PrivatePaykit")
        }
    }

    func clearUnsavedContactState(savedPublicKeys publicKeys: [String]) async {
        let savedKeys = Set(normalizedSavedContactKeys(publicKeys))
        let staleKeys = state.contacts.keys.filter { !savedKeys.contains($0) }

        for publicKey in staleKeys {
            await clearContactState(publicKey: publicKey)
        }

        await PrivatePaykitAddressReservationStore.shared.clearContactAssignments(excludingPublicKeys: Array(savedKeys))
    }

    func publishLocalEndpoints(
        for publicKeys: [String],
        wallet: WalletViewModel,
        maxAdvanceSteps: Int,
        reason: String,
        scheduleRetries: Bool = true,
        forceLocalPublishWhenRemoteEmpty: Bool = false
    ) async {
        let generation = stateGeneration
        for publicKey in publicKeys {
            do {
                guard let normalizedKey = knownSavedContact(publicKey) else {
                    continue
                }

                guard let linkId = try await establishedLinkId(for: normalizedKey, maxAdvanceSteps: maxAdvanceSteps, generation: generation) else {
                    if scheduleRetries {
                        schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                    }
                    continue
                }

                if state.contacts[normalizedKey]?.lastLocalPayloadHash == nil {
                    if await shouldPublishLocalEndpoints(publicKey: normalizedKey, fetchedRemoteCount: 0),
                       !shouldDeferInitialLocalPublish(publicKey: normalizedKey, fetchedRemoteCount: 0)
                    {
                        try await publishLocalEndpoints(to: normalizedKey, linkId: linkId, wallet: wallet, generation: generation)
                        if scheduleRetries {
                            schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                        }
                        continue
                    }

                    let fetchedCount: Int
                    do {
                        fetchedCount = try await fetchRemoteEndpoints(publicKey: normalizedKey, linkId: linkId, generation: generation)
                    } catch {
                        if shouldCountAsStaleLinkFailure(error) {
                            if scheduleRetries {
                                schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                            }
                            continue
                        }
                        throw error
                    }

                    guard await shouldPublishLocalEndpoints(publicKey: normalizedKey, fetchedRemoteCount: fetchedCount) else {
                        if scheduleRetries {
                            schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                        }
                        continue
                    }

                    try await publishLocalEndpoints(to: normalizedKey, linkId: linkId, wallet: wallet, generation: generation)
                    if fetchedCount == 0, state.contacts[normalizedKey]?.remoteEndpoints.isEmpty != false {
                        if scheduleRetries {
                            schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                        }
                    } else {
                        cancelPendingPublicationRetry(for: normalizedKey)
                    }
                    continue
                }

                let fetchedCount: Int
                do {
                    fetchedCount = try await fetchRemoteEndpoints(publicKey: normalizedKey, linkId: linkId, generation: generation)
                } catch {
                    if shouldCountAsStaleLinkFailure(error) {
                        if scheduleRetries {
                            schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                        }
                        continue
                    }
                    throw error
                }

                guard await shouldPublishLocalEndpoints(publicKey: normalizedKey, fetchedRemoteCount: fetchedCount) else {
                    if scheduleRetries {
                        schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                    }
                    continue
                }

                // Recovery retries may need to send the same map again if restored Noise counters diverged.
                let shouldForcePublish = forceLocalPublishWhenRemoteEmpty &&
                    fetchedCount == 0 &&
                    state.contacts[normalizedKey]?.remoteEndpoints.isEmpty != false
                try await publishLocalEndpoints(
                    to: normalizedKey,
                    linkId: linkId,
                    wallet: wallet,
                    generation: generation,
                    force: shouldForcePublish
                )
                if fetchedCount == 0, state.contacts[normalizedKey]?.remoteEndpoints.isEmpty != false {
                    if scheduleRetries {
                        schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                    }
                } else {
                    cancelPendingPublicationRetry(for: normalizedKey)
                }
            } catch {
                Logger.warn(
                    "Failed to \(reason) private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }
    }

    func schedulePendingPublicationRetry(
        for publicKey: String,
        wallet: WalletViewModel,
        remainingAttempts: Int = PrivatePaykitService.pendingPublicationRetryAttempts
    ) {
        guard remainingAttempts > 0, isKnownSavedContact(publicKey), pendingPublicationRetryTasks[publicKey] == nil else {
            return
        }

        let task = Task { [weak self, weak wallet] in
            try? await Task.sleep(nanoseconds: Self.pendingPublicationRetryDelay)
            guard !Task.isCancelled, let self, let wallet else { return }
            await runPendingPublicationRetry(for: publicKey, wallet: wallet, remainingAttempts: remainingAttempts)
        }
        pendingPublicationRetryTasks[publicKey] = task
    }

    func runPendingPublicationRetry(for publicKey: String, wallet: WalletViewModel, remainingAttempts: Int) async {
        guard pendingPublicationRetryTasks[publicKey] != nil else { return }
        pendingPublicationRetryTasks[publicKey] = nil
        guard isKnownSavedContact(publicKey), await canPublishPrivateEndpoints(wallet: wallet) else { return }

        await publishLocalEndpoints(
            for: [publicKey],
            wallet: wallet,
            maxAdvanceSteps: 3,
            reason: "retry",
            scheduleRetries: false,
            forceLocalPublishWhenRemoteEmpty: true
        )

        let contactState = state.contacts[publicKey]
        let needsAnotherRetry = contactState?.linkCompletedAt == nil ||
            contactState?.lastLocalPayloadHash == nil ||
            contactState?.remoteEndpoints.isEmpty != false
        if needsAnotherRetry {
            schedulePendingPublicationRetry(for: publicKey, wallet: wallet, remainingAttempts: remainingAttempts - 1)
        }
    }

    func cancelPendingPublicationRetry(for publicKey: String) {
        pendingPublicationRetryTasks.removeValue(forKey: publicKey)?.cancel()
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

    func removePublishedEndpoints(for publicKey: String, generation: UInt64) async throws {
        let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
        let previousTask = publicationTasks[normalizedKey]?.task
        let taskId = UUID()
        let task = Task { [weak self] in
            if let previousTask {
                try? await previousTask.value
            }
            guard let self else { throw PrivatePaykitError.privateUnavailable }
            try Task.checkCancellation()
            try await removePublishedEndpointsUnlocked(for: normalizedKey, generation: generation)
        }
        publicationTasks[normalizedKey] = PublicationTask(id: taskId, task: task)

        do {
            try await task.value
            if publicationTasks[normalizedKey]?.id == taskId {
                publicationTasks[normalizedKey] = nil
            }
        } catch {
            if publicationTasks[normalizedKey]?.id == taskId {
                publicationTasks[normalizedKey] = nil
            }
            throw error
        }
    }

    func removePublishedEndpointsUnlocked(for publicKey: String, generation: UInt64) async throws {
        guard let linkId = try await existingOrRecoveredLinkIdForRemoval(for: publicKey, generation: generation) else {
            if shouldRequirePrivateEndpointRemoval(publicKey: publicKey) {
                throw PrivatePaykitError.privateUnavailable
            }
            return
        }

        try ensureCurrentGeneration(generation)
        let removalEntries = privateEndpointRemovalEntries()
        try validateNoisePayload(entries: removalEntries)
        try await PubkyService.setPrivatePayments(linkId: linkId, entries: removalEntries)
        try ensureCurrentGeneration(generation)
        state.contacts[publicKey]?.lastLocalPayloadHash = nil
        state.contacts[publicKey]?.localInvoice = nil
        try await persistLinkSnapshot(linkId: linkId, publicKey: publicKey, generation: generation)
        let ownPublicKey = await (PubkyService.currentPublicKey()).flatMap(PubkyPublicKeyFormat.normalized)
        if let ownPublicKey {
            await clearRecoveryMarker(from: ownPublicKey, to: publicKey)
        }
    }

    func existingOrRecoveredLinkIdForRemoval(for publicKey: String, generation: UInt64) async throws -> String? {
        if let linkId = try await existingLinkId(for: publicKey, generation: generation) {
            return linkId
        }

        guard shouldRequirePrivateEndpointRemoval(publicKey: publicKey) else {
            return nil
        }

        return try await establishedLinkId(for: publicKey, maxAdvanceSteps: 5, generation: generation)
    }

    func shouldRequirePrivateEndpointRemoval(publicKey: String) -> Bool {
        guard let contactState = state.contacts[publicKey] else { return false }

        return contactState.linkSnapshotHex != nil ||
            contactState.lastLocalPayloadHash != nil ||
            contactState.localInvoice != nil ||
            contactState.linkCompletedAt != nil ||
            contactState.recoveryStartedAt != nil
    }
}
