import Foundation

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
        if Self.isProfileRecoveryPending, !publicKeys.isEmpty {
            return await recoverSavedContactsAfterProfileRecreation(
                publicKeys,
                wallet: wallet,
                requireImmediatePublication: requireImmediatePublication
            )
        }
        await PrivatePaykitAddressReservationStore.shared.reconcileReservedIndexesWithLdk()
        return await publishLocalEndpoints(
            for: publicKeys,
            wallet: wallet,
            maxAdvanceSteps: 3,
            reason: "prepare",
            requireImmediatePublication: requireImmediatePublication
        )
    }

    @discardableResult
    func recoverSavedContactsAfterProfileRecreation(
        _ publicKeys: [String],
        wallet: WalletViewModel,
        requireImmediatePublication: Bool = false
    ) async -> Error? {
        let publicKeys = rememberSavedContacts(publicKeys, replacing: true)
        guard !publicKeys.isEmpty else { return nil }
        guard await canPublishPrivateEndpoints(wallet: wallet) else { return nil }

        invalidateLinkEstablishmentWork()
        guard await purgePrivatePaymentOutboxForProfileRecovery(reason: "profile recovery") else {
            return handleProfileRecoveryPurgeFailure(requireImmediatePublication: requireImmediatePublication)
        }

        let startedAt = UInt64(Date().timeIntervalSince1970)
        for publicKey in publicKeys {
            if let linkId = activeHandlesByContact[publicKey]?.linkId {
                try? await PubkyService.closeEncryptedLink(linkId: linkId)
            }
            if let handshakeId = activeHandlesByContact[publicKey]?.handshakeId {
                try? await PubkyService.dropEncryptedLinkHandshake(handshakeId: handshakeId)
            }

            markContactForProfileRecovery(publicKey, startedAt: startedAt)
        }

        persistState(markWalletBackup: true)
        Self.setProfileRecoveryPending(false)
        await PrivatePaykitAddressReservationStore.shared.reconcileReservedIndexesWithLdk()

        return await publishLocalEndpoints(
            for: publicKeys,
            wallet: wallet,
            maxAdvanceSteps: 3,
            reason: "profile recovery",
            forceLocalPublishWhenRemoteEmpty: true,
            requireImmediatePublication: requireImmediatePublication
        )
    }

    func handleProfileRecoveryPurgeFailure(requireImmediatePublication: Bool) -> Error? {
        Self.setProfileRecoveryPending(true)
        return requireImmediatePublication ? PrivatePaykitError.privateUnavailable : nil
    }

    func markContactForProfileRecovery(_ publicKey: String, startedAt: UInt64) {
        activeHandlesByContact[publicKey] = ContactPaykitHandles()

        var contactState = ContactState()
        contactState.recoveryStartedAt = startedAt
        state.contacts[publicKey] = contactState
        cancelPendingPublicationRetry(for: publicKey)
    }

    func refreshSavedContactEndpoints(for publicKeys: [String], wallet: WalletViewModel) async {
        let publicKeys = rememberSavedContacts(publicKeys, replacing: true)
        guard await canPublishPrivateEndpoints(wallet: wallet) else { return }
        if Self.isProfileRecoveryPending, !publicKeys.isEmpty {
            await recoverSavedContactsAfterProfileRecreation(publicKeys, wallet: wallet)
            return
        }
        await publishLocalEndpoints(for: publicKeys, wallet: wallet, maxAdvanceSteps: 1, reason: "refresh")
    }

    func refreshKnownSavedContactEndpoints(wallet: WalletViewModel, reason: String, forceRefreshLightning: Bool = false) async {
        guard !knownSavedContactKeys.isEmpty else { return }
        guard await canPublishPrivateEndpoints(wallet: wallet) else { return }
        if Self.isProfileRecoveryPending {
            await recoverSavedContactsAfterProfileRecreation(Array(knownSavedContactKeys), wallet: wallet)
            return
        }
        await publishLocalEndpoints(
            for: Array(knownSavedContactKeys),
            wallet: wallet,
            maxAdvanceSteps: 1,
            reason: reason,
            forceRefreshLightning: forceRefreshLightning
        )
    }

    func removePublishedEndpoints() async throws {
        try await removePublishedEndpoints(for: Array(state.contacts.keys))
    }

    func removePublishedEndpoints(for publicKeys: [String]) async throws {
        invalidateLinkEstablishmentWork()
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
            if !UserDefaults.standard.bool(forKey: PublicPaykitService.publishingEnabledKey) {
                try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: false)
            }

            let publicKeys = pendingPrivateEndpointRemovalKeys(savedPublicKeys: savedPublicKeys)
            if !publicKeys.isEmpty {
                try await removePublishedEndpoints(for: publicKeys)
            }
            await clearUnsavedContactState(savedPublicKeys: savedPublicKeys)
            Self.setContactSharingCleanupPending(false)
        } catch {
            Logger.warn("Failed to retry pending Paykit contact endpoint removal: \(error)", context: "PrivatePaykit")
        }
    }

    func pendingPrivateEndpointRemovalKeys(savedPublicKeys publicKeys: [String]) -> [String] {
        if !UserDefaults.standard.bool(forKey: Self.publishingEnabledKey) {
            return Array(state.contacts.keys)
        }

        let savedKeys = Set(normalizedSavedContactKeys(publicKeys))
        return state.contacts.keys.filter { !savedKeys.contains($0) }
    }

    func clearUnsavedContactState(savedPublicKeys publicKeys: [String]) async {
        let savedKeys = Set(normalizedSavedContactKeys(publicKeys))
        let staleKeys = state.contacts.keys.filter { !savedKeys.contains($0) }

        for publicKey in staleKeys {
            await clearContactState(publicKey: publicKey)
        }

        await PrivatePaykitAddressReservationStore.shared.clearContactAssignments(excludingPublicKeys: Array(savedKeys))
    }

    @discardableResult
    func publishLocalEndpoints(
        for publicKeys: [String],
        wallet: WalletViewModel,
        maxAdvanceSteps: Int,
        reason: String,
        scheduleRetries: Bool = true,
        forceLocalPublishWhenRemoteEmpty: Bool = false,
        forceRefreshLightning: Bool = false,
        requireImmediatePublication: Bool = false
    ) async -> Error? {
        let generation = stateGeneration
        var firstError: Error?

        for publicKey in publicKeys {
            var retryPublicKey = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
            do {
                guard let normalizedKey = knownSavedContact(publicKey) else {
                    continue
                }
                retryPublicKey = normalizedKey

                guard let linkId = try await establishedLinkId(for: normalizedKey, maxAdvanceSteps: maxAdvanceSteps, generation: generation) else {
                    if scheduleRetries {
                        schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                    }
                    if requireImmediatePublication, firstError == nil {
                        firstError = PrivatePaykitError.privateUnavailable
                    }
                    continue
                }

                if state.contacts[normalizedKey]?.lastLocalPayloadHash == nil {
                    if await shouldPublishLocalEndpoints(publicKey: normalizedKey, fetchedRemoteCount: 0),
                       !shouldDeferInitialLocalPublish(publicKey: normalizedKey, fetchedRemoteCount: 0)
                    {
                        try await publishLocalEndpoints(
                            to: normalizedKey,
                            linkId: linkId,
                            wallet: wallet,
                            generation: generation,
                            forceRefreshLightning: forceRefreshLightning
                        )
                        if scheduleRetries {
                            schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                        }
                        continue
                    }

                    let fetchedCount: Int
                    do {
                        fetchedCount = try await fetchRemoteEndpoints(publicKey: normalizedKey, linkId: linkId, generation: generation)
                    } catch {
                        if requireImmediatePublication, firstError == nil {
                            firstError = error
                        }
                        if shouldCountAsStaleLinkFailure(error) {
                            if scheduleRetries {
                                schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                            }
                            continue
                        }
                        throw error
                    }

                    let shouldForcePublish = forceLocalPublishWhenRemoteEmpty &&
                        fetchedCount == 0 &&
                        state.contacts[normalizedKey]?.remoteEndpoints.isEmpty != false
                    let shouldPublish = if shouldForcePublish {
                        true
                    } else {
                        await shouldPublishLocalEndpoints(publicKey: normalizedKey, fetchedRemoteCount: fetchedCount)
                    }
                    guard shouldPublish else {
                        if requireImmediatePublication, firstError == nil {
                            firstError = PrivatePaykitError.privateUnavailable
                        }
                        if scheduleRetries {
                            schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                        }
                        continue
                    }

                    try await publishLocalEndpoints(
                        to: normalizedKey,
                        linkId: linkId,
                        wallet: wallet,
                        generation: generation,
                        force: shouldForcePublish,
                        forceRefreshLightning: forceRefreshLightning
                    )
                    if fetchedCount == 0, state.contacts[normalizedKey]?.remoteEndpoints.isEmpty != false {
                        if scheduleRetries {
                            schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                        }
                    } else if scheduleRetries, await shouldRetryMissingPrivateLightningEndpoint(for: normalizedKey, wallet: wallet) {
                        schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                    } else {
                        cancelPendingPublicationRetry(for: normalizedKey)
                    }
                    continue
                }

                let fetchedCount: Int
                do {
                    fetchedCount = try await fetchRemoteEndpoints(publicKey: normalizedKey, linkId: linkId, generation: generation)
                } catch {
                    if requireImmediatePublication, firstError == nil {
                        firstError = error
                    }
                    if shouldCountAsStaleLinkFailure(error) {
                        if scheduleRetries {
                            schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                        }
                        continue
                    }
                    throw error
                }

                guard await shouldPublishLocalEndpoints(publicKey: normalizedKey, fetchedRemoteCount: fetchedCount) else {
                    if requireImmediatePublication, firstError == nil {
                        firstError = PrivatePaykitError.privateUnavailable
                    }
                    if scheduleRetries {
                        schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                    }
                    continue
                }

                // Recovery retries may need to resend the same map after a link is re-established and remote state is empty.
                let shouldForcePublish = forceLocalPublishWhenRemoteEmpty &&
                    fetchedCount == 0 &&
                    state.contacts[normalizedKey]?.remoteEndpoints.isEmpty != false
                try await publishLocalEndpoints(
                    to: normalizedKey,
                    linkId: linkId,
                    wallet: wallet,
                    generation: generation,
                    force: shouldForcePublish,
                    forceRefreshLightning: forceRefreshLightning
                )
                if fetchedCount == 0, state.contacts[normalizedKey]?.remoteEndpoints.isEmpty != false {
                    if scheduleRetries {
                        schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                    }
                } else if scheduleRetries, await shouldRetryMissingPrivateLightningEndpoint(for: normalizedKey, wallet: wallet) {
                    schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                } else {
                    cancelPendingPublicationRetry(for: normalizedKey)
                }
            } catch {
                if scheduleRetries {
                    schedulePendingPublicationRetry(for: retryPublicKey, wallet: wallet)
                }
                if firstError == nil {
                    firstError = error
                }
                Logger.warn(
                    "Failed to \(reason) private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(retryPublicKey)): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }

        return firstError
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
        let needsAnotherRetryFromLinkState = contactState?.linkCompletedAt == nil ||
            contactState?.lastLocalPayloadHash == nil ||
            contactState?.remoteEndpoints.isEmpty != false
        var needsAnotherRetry = needsAnotherRetryFromLinkState
        if !needsAnotherRetry {
            needsAnotherRetry = await shouldRetryMissingPrivateLightningEndpoint(for: publicKey, wallet: wallet)
        }
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
