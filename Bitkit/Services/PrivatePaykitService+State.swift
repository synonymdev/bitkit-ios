import Foundation

// MARK: - Active Paykit Handles

extension PrivatePaykitService {
    func markProfileRecoveryPendingIfNeeded() {
        guard !state.contacts.isEmpty || !knownSavedContactKeys.isEmpty else { return }
        Self.setProfileRecoveryPending(true)
    }

    func closeAndClear(markProfileRecoveryPending: Bool = false) async {
        if markProfileRecoveryPending {
            markProfileRecoveryPendingIfNeeded()
        }
        resetInFlightWork()
        await closeActivePaykitHandles()
        activeHandlesByContact.removeAll()
        knownSavedContactKeys.removeAll()
        state = PrivatePaykitState(contacts: [:])
        try? Keychain.delete(key: .privatePaykitSecretState)
        UserDefaults.standard.removeObject(forKey: Self.cacheStateKey)
        markWalletBackupDataChanged()
    }

    func persistLinkSnapshot(linkId: String, publicKey: String, generation: UInt64, linkWasReplaced: Bool = false) async throws {
        let snapshotHex = try await PubkyService.serializeEncryptedLink(linkId: linkId)
        try ensureCurrentGeneration(generation)
        guard activeHandlesByContact[publicKey]?.linkId == linkId else {
            throw PrivatePaykitError.staleLinkState
        }
        let completedAttemptId = state.contacts[publicKey]?.mainRecoveryAttemptId ?? state.contacts[publicKey]?.responderRecoveryAttemptId
        state.contacts[publicKey, default: ContactState()].linkSnapshotHex = snapshotHex
        state.contacts[publicKey]?.handshakeSnapshotHex = nil
        state.contacts[publicKey]?.recoveryStartedAt = nil
        state.contacts[publicKey]?.mainRecoveryAttemptId = nil
        state.contacts[publicKey]?.responderRecoveryAttemptId = nil
        if linkWasReplaced || state.contacts[publicKey]?.linkCompletedAt == nil {
            state.contacts[publicKey]?.linkCompletedAt = UInt64(Date().timeIntervalSince1970)
        }
        if linkWasReplaced {
            state.contacts[publicKey]?.lastLocalPayloadHash = nil
        }
        if let completedAttemptId {
            state.contacts[publicKey]?.lastCompletedRecoveryAttemptId = completedAttemptId
        }
        persistState(markWalletBackup: true)
    }

    func clearContactState(publicKey: String) async {
        let ownPublicKey = await (PubkyService.currentPublicKey()).flatMap(PubkyPublicKeyFormat.normalized)
        if let ownPublicKey {
            await clearRecoveryMarker(from: ownPublicKey, to: publicKey)
        }

        if let linkId = activeHandlesByContact[publicKey]?.linkId {
            try? await PubkyService.closeEncryptedLink(linkId: linkId)
        }
        if let handshakeId = activeHandlesByContact[publicKey]?.handshakeId {
            try? await PubkyService.dropEncryptedLinkHandshake(handshakeId: handshakeId)
        }

        activeHandlesByContact[publicKey] = nil
        state.contacts[publicKey] = nil
        persistState(markWalletBackup: true)
    }

    func closeActivePaykitHandles() async {
        for handles in activeHandlesByContact.values {
            if let linkId = handles.linkId {
                try? await PubkyService.closeEncryptedLink(linkId: linkId)
            }
            if let handshakeId = handles.handshakeId {
                try? await PubkyService.dropEncryptedLinkHandshake(handshakeId: handshakeId)
            }
        }
    }

    func recordLinkSuccess(publicKey: String) {
        guard state.contacts[publicKey]?.linkFailureCount != 0 else { return }
        state.contacts[publicKey]?.linkFailureCount = 0
        persistState()
    }

    func recordLinkFailure(publicKey: String, error: Error, generation: UInt64) async {
        guard stateGeneration == generation, !Task.isCancelled else {
            return
        }

        guard shouldCountAsStaleLinkFailure(error) else {
            return
        }

        let failureCount = (state.contacts[publicKey]?.linkFailureCount ?? 0) + 1
        state.contacts[publicKey, default: ContactState()].linkFailureCount = failureCount

        guard failureCount >= Self.staleLinkFailureThreshold else {
            persistState()
            return
        }

        if let linkId = activeHandlesByContact[publicKey]?.linkId {
            try? await PubkyService.closeEncryptedLink(linkId: linkId)
        }
        guard stateGeneration == generation, !Task.isCancelled else {
            return
        }

        stateGeneration &+= 1
        linkEstablishmentTasks.removeValue(forKey: publicKey)?.task.cancel()
        if var handles = activeHandlesByContact[publicKey] {
            handles.linkId = nil
            handles.handshakeId = nil
            activeHandlesByContact[publicKey] = handles
        }
        state.contacts[publicKey]?.linkSnapshotHex = nil
        state.contacts[publicKey]?.handshakeSnapshotHex = nil
        state.contacts[publicKey]?.lastLocalPayloadHash = nil
        state.contacts[publicKey]?.remoteEndpoints = []
        state.contacts[publicKey]?.linkFailureCount = 0
        state.contacts[publicKey]?.recoveryStartedAt = UInt64(Date().timeIntervalSince1970)
        state.contacts[publicKey]?.mainRecoveryAttemptId = nil
        state.contacts[publicKey]?.responderRecoveryAttemptId = nil
        persistState(markWalletBackup: true)
    }

    func resetInFlightWork() {
        stateGeneration &+= 1
        for inFlight in linkEstablishmentTasks.values {
            inFlight.task.cancel()
        }
        linkEstablishmentTasks.removeAll()
        for inFlight in publicationTasks.values {
            inFlight.task.cancel()
        }
        publicationTasks.removeAll()
        for inFlight in pendingPublicationRetryTasks.values {
            inFlight.cancel()
        }
        pendingPublicationRetryTasks.removeAll()
    }

    func invalidateLinkEstablishmentWork() {
        stateGeneration &+= 1
        for inFlight in linkEstablishmentTasks.values {
            inFlight.task.cancel()
        }
        linkEstablishmentTasks.removeAll()
    }

    func invalidateLinkEstablishment(for publicKey: String) {
        stateGeneration &+= 1
        if let inFlight = linkEstablishmentTasks.removeValue(forKey: publicKey) {
            inFlight.task.cancel()
        }
        cancelPendingPublicationRetry(for: publicKey)
    }

    func ensureCurrentGeneration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard stateGeneration == generation else {
            throw PrivatePaykitError.privateUnavailable
        }
    }

    func persistState(markWalletBackup: Bool = false) {
        do {
            let secretState = state.secretState
            if secretState.contacts.isEmpty {
                try? Keychain.delete(key: .privatePaykitSecretState)
            } else {
                let data = try JSONEncoder().encode(secretState)
                try Keychain.upsert(key: .privatePaykitSecretState, data: data)
            }

            let cacheState = state.cacheState
            if cacheState.contacts.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.cacheStateKey)
            } else {
                let data = try JSONEncoder().encode(cacheState)
                UserDefaults.standard.set(data, forKey: Self.cacheStateKey)
            }

            if markWalletBackup {
                markWalletBackupDataChanged()
            }
        } catch {
            Logger.error("Failed to persist private Paykit state: \(error)", context: "PrivatePaykit")
        }
    }

    func markWalletBackupDataChanged() {
        Self.walletBackupDataChangedSubject.send()
    }

    @discardableResult
    func purgePrivatePaymentOutbox(for publicKey: String, reason: String) async -> Bool {
        let otherContactCount = state.contacts.keys.filter { $0 != publicKey }.count
        guard otherContactCount == 0 else {
            Logger.warn(
                "Skipping broad private Paykit transport cleanup during \(reason) because \(otherContactCount) other private contact(s) have state; continuing recovery without purge",
                context: "PrivatePaykit"
            )
            return true
        }

        return await purgePrivatePaymentStorage(reason: reason)
    }

    @discardableResult
    func purgePrivatePaymentOutboxForProfileRecovery(reason: String) async -> Bool {
        await purgePrivatePaymentStorage(reason: reason)
    }

    @discardableResult
    private func purgePrivatePaymentStorage(reason: String) async -> Bool {
        guard let sessionSecret = try? Keychain.loadString(key: .paykitSession),
              !sessionSecret.isEmpty
        else { return false }

        do {
            if try await deletePrivatePaymentStorageRoot(sessionSecret: sessionSecret, reason: reason) {
                return true
            }

            let result = try await purgePrivatePaymentStorageTree(
                sessionSecret: sessionSecret,
                dirPath: Self.privateStorageRootPath,
                depth: 0,
                deletedSoFar: 0
            )
            if result.deletedCount > 0 {
                Logger.info("Cleared \(result.deletedCount) stale private Paykit transport messages during \(reason)", context: "PrivatePaykit")
            }
            if result.didHitLimit {
                Logger.warn("Stopped private Paykit transport cleanup after reaching the safety limit", context: "PrivatePaykit")
            }
            return !result.didHitLimit && !result.didFail
        } catch {
            if isMissingPrivateStorageError(error) {
                return true
            }
            Logger.warn("Failed to clear private Paykit transport messages during \(reason): \(error)", context: "PrivatePaykit")
            return false
        }
    }

    func deletePrivatePaymentStorageRoot(sessionSecret: String, reason: String) async throws -> Bool {
        do {
            try await PubkyService.sessionDelete(sessionSecret: sessionSecret, path: filePath(Self.privateStorageRootPath))
            Logger.info("Cleared stale private Paykit transport directory during \(reason)", context: "PrivatePaykit")
            return true
        } catch {
            return false
        }
    }

    func purgePrivatePaymentStorageTree(sessionSecret: String, dirPath: String, depth: Int,
                                        deletedSoFar: Int) async throws -> PrivateStoragePurgeResult
    {
        guard deletedSoFar < Self.privateStoragePurgeMaxEntries else {
            return PrivateStoragePurgeResult(deletedCount: 0, didHitLimit: true, didFail: false)
        }
        guard depth < Self.privateStoragePurgeMaxDepth else {
            return PrivateStoragePurgeResult(deletedCount: 0, didHitLimit: true, didFail: false)
        }

        let entries = try await PubkyService.sessionList(sessionSecret: sessionSecret, dirPath: directoryPath(dirPath))
        var deletedCount = 0
        var didHitLimit = false
        var didFail = false

        for entry in entries {
            guard deletedSoFar + deletedCount < Self.privateStoragePurgeMaxEntries else {
                didHitLimit = true
                break
            }
            guard let path = privateStoragePath(from: entry) else { continue }

            do {
                try await PubkyService.sessionDelete(sessionSecret: sessionSecret, path: filePath(path))
                deletedCount += 1
            } catch {
                if depth == 0, !path.hasSuffix("/") {
                    do {
                        let childResult = try await purgePrivatePaymentStorageTree(
                            sessionSecret: sessionSecret,
                            dirPath: directoryPath(path),
                            depth: depth + 1,
                            deletedSoFar: deletedSoFar + deletedCount
                        )
                        deletedCount += childResult.deletedCount
                        didHitLimit = didHitLimit || childResult.didHitLimit
                        didFail = didFail || childResult.didFail
                        continue
                    } catch {
                        if isMissingPrivateStorageError(error) {
                            continue
                        }
                        Logger.warn("Failed to list private Paykit transport directory at \(path): \(error)", context: "PrivatePaykit")
                        didFail = true
                    }
                } else if isMissingPrivateStorageError(error) {
                    continue
                }

                Logger.warn("Failed to delete stale private Paykit transport entry at \(path): \(error)", context: "PrivatePaykit")
                didFail = true
            }
        }

        return PrivateStoragePurgeResult(deletedCount: deletedCount, didHitLimit: didHitLimit, didFail: didFail)
    }

    func privateStoragePath(from entry: String) -> String? {
        let path: String = if let url = URL(string: entry), url.scheme == "pubky" {
            url.path
        } else {
            entry
        }

        guard path.hasPrefix(Self.privateStorageRootPath) else { return nil }
        return path
    }

    func directoryPath(_ path: String) -> String {
        path.hasSuffix("/") ? path : "\(path)/"
    }

    func filePath(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    func isMissingPrivateStorageError(_ error: Error) -> Bool {
        let reason: String = if let appError = error as? AppError {
            [appError.message, appError.debugMessage].compactMap { $0 }.joined(separator: " ")
        } else {
            error.localizedDescription
        }

        let lowercasedReason = reason.lowercased()
        return lowercasedReason.contains("404") && lowercasedReason.contains("not found")
    }
}
