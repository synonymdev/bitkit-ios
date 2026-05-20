import CryptoKit
import Foundation
import Paykit

// MARK: - Link Lifecycle

extension PrivatePaykitService {
    func establishedLinkId(for publicKey: String, maxAdvanceSteps: Int, generation: UInt64) async throws -> String? {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw PrivatePaykitError.privateUnavailable
        }

        while true {
            try Task.checkCancellation()
            if let inFlight = linkEstablishmentTasks[normalizedKey] {
                do {
                    let linkId = try await inFlight.task.value
                    if linkEstablishmentTasks[normalizedKey]?.id == inFlight.id {
                        linkEstablishmentTasks[normalizedKey] = nil
                    }
                    if linkId != nil || inFlight.maxAdvanceSteps >= maxAdvanceSteps {
                        return linkId
                    }

                    continue
                } catch {
                    if linkEstablishmentTasks[normalizedKey]?.id == inFlight.id {
                        linkEstablishmentTasks[normalizedKey] = nil
                    }
                    throw error
                }
            }

            let taskId = UUID()
            let task = Task { [weak self] in
                guard let self else { throw PrivatePaykitError.privateUnavailable }
                try Task.checkCancellation()
                return try await establishedLinkIdUnlocked(for: normalizedKey, maxAdvanceSteps: maxAdvanceSteps, generation: generation)
            }
            linkEstablishmentTasks[normalizedKey] = LinkEstablishmentTask(id: taskId, maxAdvanceSteps: maxAdvanceSteps, task: task)

            do {
                let linkId = try await task.value
                if linkEstablishmentTasks[normalizedKey]?.id == taskId {
                    linkEstablishmentTasks[normalizedKey] = nil
                }
                return linkId
            } catch {
                if linkEstablishmentTasks[normalizedKey]?.id == taskId {
                    linkEstablishmentTasks[normalizedKey] = nil
                }
                throw error
            }
        }
    }

    func establishedLinkIdUnlocked(for normalizedKey: String, maxAdvanceSteps: Int, generation: UInt64) async throws -> String? {
        try ensureCurrentGeneration(generation)
        guard
            let secretKeyHex = try Keychain.loadString(key: .pubkySecretKey),
            !secretKeyHex.isEmpty,
            let ownPublicKeyRaw = await PubkyService.currentPublicKey(),
            let ownPublicKey = PubkyPublicKeyFormat.normalized(ownPublicKeyRaw)
        else {
            throw PrivatePaykitError.privateUnavailable
        }

        if let linkId = activeHandlesByContact[normalizedKey]?.linkId {
            if let remoteRecoveryMarker = await freshRecoveryMarker(from: normalizedKey, to: ownPublicKey, stages: [Self.recoveryMarkerStageInit]) {
                if shouldReplaceUsableLink(with: remoteRecoveryMarker, publicKey: normalizedKey) {
                    guard await discardLinkForRecovery(publicKey: normalizedKey, linkId: linkId, startedAt: remoteRecoveryMarker.createdAt) else {
                        return nil
                    }
                    try ensureCurrentGeneration(generation)
                } else {
                    try ensureCurrentGeneration(generation)
                    return linkId
                }
            } else {
                try ensureCurrentGeneration(generation)
                return linkId
            }
        }

        if let linkId = activeHandlesByContact[normalizedKey]?.linkId {
            try ensureCurrentGeneration(generation)
            return linkId
        }

        if let snapshotHex = state.contacts[normalizedKey]?.linkSnapshotHex {
            do {
                try await validateSnapshot(snapshotHex, publicKey: normalizedKey, recipient: PubkyService.encryptedLinkSnapshotRecipient)
                let linkId = try await PubkyService.restoreEncryptedLink(secretKeyHex: secretKeyHex, snapshotHex: snapshotHex)
                try ensureCurrentGeneration(generation)
                activeHandlesByContact[normalizedKey] = ContactPaykitHandles(linkId: linkId, handshakeId: nil)
                if let remoteRecoveryMarker = await freshRecoveryMarker(
                    from: normalizedKey,
                    to: ownPublicKey,
                    stages: [Self.recoveryMarkerStageInit]
                ) {
                    if shouldReplaceUsableLink(with: remoteRecoveryMarker, publicKey: normalizedKey) {
                        guard await discardLinkForRecovery(publicKey: normalizedKey, linkId: linkId, startedAt: remoteRecoveryMarker.createdAt) else {
                            return nil
                        }
                        try ensureCurrentGeneration(generation)
                    } else {
                        try ensureCurrentGeneration(generation)
                        return linkId
                    }
                } else {
                    try ensureCurrentGeneration(generation)
                    return linkId
                }
            } catch {
                try ensureCurrentGeneration(generation)
                Logger.warn("Failed to restore private Paykit link, restarting handshake: \(error)", context: "PrivatePaykit")
                state.contacts[normalizedKey]?.linkSnapshotHex = nil
                state.contacts[normalizedKey]?.handshakeSnapshotHex = nil
                state.contacts[normalizedKey]?.lastLocalPayloadHash = nil
                state.contacts[normalizedKey]?.mainRecoveryAttemptId = nil
                state.contacts[normalizedKey]?.responderRecoveryAttemptId = nil
                persistState(markWalletBackup: true)
            }
        }

        let isRecovering = await shouldStartRecoveryHandshake(publicKey: normalizedKey)
        let remoteRecoveryInitMarker = await freshRecoveryMarker(from: normalizedKey, to: ownPublicKey, stages: [Self.recoveryMarkerStageInit])
            .flatMap { isCompletedRecoveryMarker($0, publicKey: normalizedKey) ? nil : $0 }
        let remoteRecoveryFinalForResponder: RecoveryMarker? = if let responderAttemptId = state.contacts[normalizedKey]?.responderRecoveryAttemptId {
            await freshRecoveryMarker(
                from: normalizedKey,
                to: ownPublicKey,
                stages: [Self.recoveryMarkerStageFinal],
                attemptId: responderAttemptId
            )
        } else {
            nil
        }
        let remoteRecoveryMarker = remoteRecoveryInitMarker ?? remoteRecoveryFinalForResponder

        let initialMainRecoveryAttemptId = state.contacts[normalizedKey]?.mainRecoveryAttemptId
        let localMainRecoveryMarker: RecoveryMarker? = if let mainRecoveryAttemptId = initialMainRecoveryAttemptId {
            await freshRecoveryMarker(
                from: ownPublicKey,
                to: normalizedKey,
                stages: [Self.recoveryMarkerStageInit, Self.recoveryMarkerStageFinal],
                attemptId: mainRecoveryAttemptId
            )
        } else {
            nil
        }

        let shouldAcceptRemoteRecovery = if remoteRecoveryFinalForResponder != nil {
            true
        } else {
            remoteRecoveryMarker.map {
                shouldAcceptRemoteRecoveryMarker(
                    remoteMarker: $0,
                    localMarker: localMainRecoveryMarker,
                    ownPublicKey: ownPublicKey,
                    remotePublicKey: normalizedKey
                )
            } ?? false
        }

        if shouldAcceptRemoteRecovery, let remoteRecoveryMarker {
            let isNewResponderAttempt = state.contacts[normalizedKey]?.responderRecoveryAttemptId != remoteRecoveryMarker.attemptId
            if isNewResponderAttempt {
                guard await purgePrivatePaymentOutbox(for: normalizedKey, reason: "recovery responder") else {
                    return nil
                }
                try ensureCurrentGeneration(generation)

                if let handshakeId = activeHandlesByContact[normalizedKey]?.handshakeId {
                    try? await PubkyService.dropEncryptedLinkHandshake(handshakeId: handshakeId)
                }

                var handles = activeHandlesByContact[normalizedKey, default: ContactPaykitHandles()]
                handles.linkId = nil
                handles.handshakeId = nil
                activeHandlesByContact[normalizedKey] = handles

                state.contacts[normalizedKey, default: ContactState()].handshakeSnapshotHex = nil
                state.contacts[normalizedKey]?.mainRecoveryAttemptId = nil
                state.contacts[normalizedKey]?.responderRecoveryAttemptId = remoteRecoveryMarker.attemptId
                state.contacts[normalizedKey]?.recoveryStartedAt = remoteRecoveryMarker.createdAt
                state.contacts[normalizedKey]?.lastLocalPayloadHash = nil
                state.contacts[normalizedKey]?.remoteEndpoints = []
                state.contacts[normalizedKey]?.awaitingRecoveredRemoteEndpoints = false
                persistState(markWalletBackup: true)
            }

            await publishRecoveryMarker(
                from: ownPublicKey,
                to: normalizedKey,
                stage: Self.recoveryMarkerStageResponse,
                attemptId: remoteRecoveryMarker.attemptId,
                createdAt: UInt64(Date().timeIntervalSince1970)
            )
        }

        let shouldInitiateRecovery = isRecovering && !shouldAcceptRemoteRecovery
        if shouldInitiateRecovery, state.contacts[normalizedKey]?.mainRecoveryAttemptId == nil {
            guard await purgePrivatePaymentOutbox(for: normalizedKey, reason: "recovery initiator") else {
                return nil
            }
            try ensureCurrentGeneration(generation)

            if let handshakeId = activeHandlesByContact[normalizedKey]?.handshakeId {
                try? await PubkyService.dropEncryptedLinkHandshake(handshakeId: handshakeId)
            }

            var handles = activeHandlesByContact[normalizedKey, default: ContactPaykitHandles()]
            handles.linkId = nil
            handles.handshakeId = nil
            activeHandlesByContact[normalizedKey] = handles

            let attemptId = UUID().uuidString
            let createdAt = UInt64(Date().timeIntervalSince1970)
            state.contacts[normalizedKey, default: ContactState()].handshakeSnapshotHex = nil
            state.contacts[normalizedKey]?.mainRecoveryAttemptId = attemptId
            state.contacts[normalizedKey]?.responderRecoveryAttemptId = nil
            state.contacts[normalizedKey]?.recoveryStartedAt = createdAt
            state.contacts[normalizedKey]?.lastLocalPayloadHash = nil
            state.contacts[normalizedKey]?.remoteEndpoints = []
            state.contacts[normalizedKey]?.awaitingRecoveredRemoteEndpoints = false
            persistState(markWalletBackup: true)

            await publishRecoveryMarker(
                from: ownPublicKey,
                to: normalizedKey,
                stage: Self.recoveryMarkerStageInit,
                attemptId: attemptId,
                createdAt: createdAt
            )
        }

        if shouldInitiateRecovery,
           initialMainRecoveryAttemptId != nil,
           let mainRecoveryAttemptId = state.contacts[normalizedKey]?.mainRecoveryAttemptId,
           localMainRecoveryMarker == nil
        {
            await publishRecoveryMarker(
                from: ownPublicKey,
                to: normalizedKey,
                stage: Self.recoveryMarkerStageInit,
                attemptId: mainRecoveryAttemptId,
                createdAt: UInt64(Date().timeIntervalSince1970)
            )
        }

        if isRecovering, !shouldAcceptRemoteRecovery,
           state.contacts[normalizedKey]?.responderRecoveryAttemptId != nil
        {
            state.contacts[normalizedKey]?.responderRecoveryAttemptId = nil
            persistState(markWalletBackup: true)
        }

        if shouldInitiateRecovery,
           let attemptId = state.contacts[normalizedKey]?.mainRecoveryAttemptId,
           state.contacts[normalizedKey]?.handshakeSnapshotHex != nil
        {
            let hasPeerProgress = await freshRecoveryMarker(
                from: normalizedKey,
                to: ownPublicKey,
                stages: [Self.recoveryMarkerStageResponse, Self.recoveryMarkerStageFinal],
                attemptId: attemptId
            ) != nil
            guard hasPeerProgress else {
                return nil
            }
        }

        if shouldAcceptRemoteRecovery,
           let attemptId = state.contacts[normalizedKey]?.responderRecoveryAttemptId,
           state.contacts[normalizedKey]?.handshakeSnapshotHex != nil
        {
            let hasPeerFinal = await freshRecoveryMarker(
                from: normalizedKey,
                to: ownPublicKey,
                stages: [Self.recoveryMarkerStageFinal],
                attemptId: attemptId
            ) != nil
            guard hasPeerFinal else {
                await publishRecoveryMarker(
                    from: ownPublicKey,
                    to: normalizedKey,
                    stage: Self.recoveryMarkerStageResponse,
                    attemptId: attemptId,
                    createdAt: UInt64(Date().timeIntervalSince1970)
                )
                return nil
            }
        }

        var handshakeId = activeHandlesByContact[normalizedKey]?.handshakeId

        if handshakeId == nil, let snapshotHex = state.contacts[normalizedKey]?.handshakeSnapshotHex {
            do {
                try await validateSnapshot(snapshotHex, publicKey: normalizedKey, recipient: PubkyService.encryptedLinkHandshakeSnapshotRecipient)
                handshakeId = try await PubkyService.restoreEncryptedLinkHandshake(secretKeyHex: secretKeyHex, snapshotHex: snapshotHex)
            } catch {
                try ensureCurrentGeneration(generation)
                Logger.warn("Failed to restore private Paykit handshake, restarting: \(error)", context: "PrivatePaykit")
                state.contacts[normalizedKey]?.handshakeSnapshotHex = nil
                state.contacts[normalizedKey]?.mainRecoveryAttemptId = nil
                persistState(markWalletBackup: true)
            }
        }

        if handshakeId == nil {
            let shouldInitiate = shouldInitiateRecovery || (!shouldAcceptRemoteRecovery && Self.shouldInitiate(
                ownPublicKey: ownPublicKey,
                remotePublicKey: normalizedKey
            ))
            if shouldInitiate {
                handshakeId = try await PubkyService.initiateEncryptedLink(secretKeyHex: secretKeyHex, receiverPublicKey: normalizedKey)
                try ensureCurrentGeneration(generation)
                if isRecovering {
                    state.contacts[normalizedKey, default: ContactState()].recoveryStartedAt = UInt64(Date().timeIntervalSince1970)
                    persistState(markWalletBackup: true)
                }
            } else {
                handshakeId = try await PubkyService.acceptEncryptedLink(secretKeyHex: secretKeyHex, senderPublicKey: normalizedKey)
            }
        }

        let isRecoveryHandshake = shouldInitiateRecovery || shouldAcceptRemoteRecovery
        guard var handshakeId else { return nil }
        try ensureCurrentGeneration(generation)
        var handles = activeHandlesByContact[normalizedKey, default: ContactPaykitHandles()]
        handles.linkId = nil
        handles.handshakeId = handshakeId
        activeHandlesByContact[normalizedKey] = handles

        for _ in 0 ..< maxAdvanceSteps {
            let progress: FfiHandshakeProgress
            do {
                progress = try await PubkyService.advanceHandshake(handshakeId: handshakeId)
            } catch {
                try ensureCurrentGeneration(generation)
                if isEncryptedHandshakePendingError(error) {
                    let snapshotHex = try await PubkyService.serializeEncryptedLinkHandshake(handshakeId: handshakeId)
                    try ensureCurrentGeneration(generation)
                    state.contacts[normalizedKey, default: ContactState()].handshakeSnapshotHex = snapshotHex
                    state.contacts[normalizedKey]?.handshakeUpdatedAt = UInt64(Date().timeIntervalSince1970)
                    persistState(markWalletBackup: true)
                    return nil
                }
                if isEncryptedHandshakeStateFailure(error) {
                    activeHandlesByContact[normalizedKey]?.handshakeId = nil
                    state.contacts[normalizedKey]?.handshakeSnapshotHex = nil
                    state.contacts[normalizedKey]?.mainRecoveryAttemptId = nil
                    persistState(markWalletBackup: true)
                }
                throw error
            }
            try ensureCurrentGeneration(generation)
            if progress.status == "complete" {
                let linkId = progress.handleId
                let attemptId = state.contacts[normalizedKey]?.mainRecoveryAttemptId ?? state.contacts[normalizedKey]?.responderRecoveryAttemptId
                activeHandlesByContact[normalizedKey] = ContactPaykitHandles(linkId: linkId, handshakeId: nil)
                state.contacts[normalizedKey, default: ContactState()].handshakeSnapshotHex = nil
                state.contacts[normalizedKey]?.recoveryStartedAt = nil
                try await persistLinkSnapshot(linkId: linkId, publicKey: normalizedKey, generation: generation, linkWasReplaced: true)
                if isRecoveryHandshake, let attemptId {
                    await publishRecoveryMarker(
                        from: ownPublicKey,
                        to: normalizedKey,
                        stage: Self.recoveryMarkerStageFinal,
                        attemptId: attemptId,
                        createdAt: UInt64(Date().timeIntervalSince1970)
                    )
                }
                return linkId
            }

            handshakeId = progress.handleId
            handles = activeHandlesByContact[normalizedKey, default: ContactPaykitHandles()]
            handles.linkId = nil
            handles.handshakeId = handshakeId
            activeHandlesByContact[normalizedKey] = handles
            let snapshotHex = try await PubkyService.serializeEncryptedLinkHandshake(handshakeId: handshakeId)
            try ensureCurrentGeneration(generation)
            state.contacts[normalizedKey, default: ContactState()].handshakeSnapshotHex = snapshotHex
            state.contacts[normalizedKey]?.handshakeUpdatedAt = UInt64(Date().timeIntervalSince1970)
            persistState(markWalletBackup: true)

            if isRecoveryHandshake {
                let createdAt = UInt64(Date().timeIntervalSince1970)
                if shouldInitiateRecovery, let attemptId = state.contacts[normalizedKey]?.mainRecoveryAttemptId {
                    await publishRecoveryMarker(
                        from: ownPublicKey,
                        to: normalizedKey,
                        stage: Self.recoveryMarkerStageInit,
                        attemptId: attemptId,
                        createdAt: createdAt
                    )
                } else if shouldAcceptRemoteRecovery, let attemptId = state.contacts[normalizedKey]?.responderRecoveryAttemptId {
                    await publishRecoveryMarker(
                        from: ownPublicKey,
                        to: normalizedKey,
                        stage: Self.recoveryMarkerStageResponse,
                        attemptId: attemptId,
                        createdAt: createdAt
                    )
                }
                return nil
            }
        }

        return nil
    }

    func shouldStartRecoveryHandshake(publicKey: String) async -> Bool {
        guard let contactState = state.contacts[publicKey],
              contactState.linkSnapshotHex == nil
        else {
            return false
        }

        if contactState.recoveryStartedAt != nil || contactState.mainRecoveryAttemptId != nil {
            return true
        }

        guard contactState.handshakeSnapshotHex == nil else {
            return false
        }

        if contactState.linkCompletedAt != nil || contactState.handshakeUpdatedAt != nil {
            return true
        }

        return await PrivatePaykitAddressReservationStore.shared.hasContactAssignment(for: publicKey)
    }

    func discardLinkForRecovery(publicKey: String, linkId: String?, startedAt: UInt64) async -> Bool {
        if let linkId {
            try? await PubkyService.closeEncryptedLink(linkId: linkId)
        }

        var handles = activeHandlesByContact[publicKey, default: ContactPaykitHandles()]
        handles.linkId = nil
        handles.handshakeId = nil
        activeHandlesByContact[publicKey] = handles
        state.contacts[publicKey]?.linkSnapshotHex = nil
        state.contacts[publicKey]?.handshakeSnapshotHex = nil
        state.contacts[publicKey]?.lastLocalPayloadHash = nil
        state.contacts[publicKey]?.remoteEndpoints = []
        state.contacts[publicKey]?.recoveryStartedAt = startedAt
        state.contacts[publicKey]?.mainRecoveryAttemptId = nil
        state.contacts[publicKey]?.responderRecoveryAttemptId = nil
        state.contacts[publicKey]?.awaitingRecoveredRemoteEndpoints = false
        persistState(markWalletBackup: true)
        return true
    }

    func shouldAcceptRemoteRecoveryMarker(remoteMarker: RecoveryMarker, localMarker: RecoveryMarker?,
                                          ownPublicKey: String, remotePublicKey: String) -> Bool
    {
        guard let localMarker else { return true }

        if remoteMarker.createdAt != localMarker.createdAt {
            return remoteMarker.createdAt < localMarker.createdAt
        }

        if remoteMarker.attemptId != localMarker.attemptId {
            return remoteMarker.attemptId < localMarker.attemptId
        }

        return remotePublicKey < ownPublicKey
    }

    func isCompletedRecoveryMarker(_ marker: RecoveryMarker, publicKey: String) -> Bool {
        state.contacts[publicKey]?.lastCompletedRecoveryAttemptId == marker.attemptId
    }

    func shouldReplaceUsableLink(with marker: RecoveryMarker, publicKey: String) -> Bool {
        guard !isCompletedRecoveryMarker(marker, publicKey: publicKey) else {
            return false
        }

        guard let linkCompletedAt = state.contacts[publicKey]?.linkCompletedAt else {
            return true
        }

        return marker.createdAt > linkCompletedAt
    }

    func validateSnapshot(
        _ snapshotHex: String,
        publicKey: String,
        recipient: (String) async throws -> String
    ) async throws {
        let snapshotRecipient = try await recipient(snapshotHex)
        guard PubkyPublicKeyFormat.normalized(snapshotRecipient) == PubkyPublicKeyFormat.normalized(publicKey) else {
            throw PrivatePaykitError.privateUnavailable
        }
    }

    static func recoveryMarkerPath(from writerPublicKey: String, to readerPublicKey: String) -> String? {
        guard let writerPublicKey = PubkyPublicKeyFormat.normalized(writerPublicKey),
              let readerPublicKey = PubkyPublicKeyFormat.normalized(readerPublicKey)
        else { return nil }

        let material = "bitkit-private-paykit-recovery-v1|\(writerPublicKey)|\(readerPublicKey)"
        let markerId = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "/pub/paykit/v0/private-recovery/\(markerId).json"
    }

    func freshRecoveryMarker(from writerPublicKey: String, to readerPublicKey: String, stages: Set<String>,
                             attemptId: String? = nil) async -> RecoveryMarker?
    {
        guard let markerUri = Self.recoveryMarkerUri(from: writerPublicKey, to: readerPublicKey),
              let markerPath = Self.recoveryMarkerPath(from: writerPublicKey, to: readerPublicKey),
              let payload = try? await PubkyService.fetchFileString(uri: markerUri),
              let data = payload.data(using: .utf8),
              let marker = try? JSONDecoder().decode(RecoveryMarker.self, from: data),
              marker.version == 1,
              marker.path == markerPath,
              stages.contains(marker.stage),
              !marker.attemptId.isEmpty
        else {
            return nil
        }

        let contactKey = [writerPublicKey, readerPublicKey]
            .compactMap(PubkyPublicKeyFormat.normalized)
            .first { state.contacts[$0] != nil }
        let linkCompletedAt = contactKey.flatMap { state.contacts[$0]?.linkCompletedAt } ?? 0
        guard marker.createdAt > linkCompletedAt else {
            return nil
        }

        if let attemptId, marker.attemptId != attemptId {
            return nil
        }

        return marker
    }

    func publishRecoveryMarker(from writerPublicKey: String, to readerPublicKey: String, stage: String, attemptId: String, createdAt: UInt64) async {
        guard let markerPath = Self.recoveryMarkerPath(from: writerPublicKey, to: readerPublicKey),
              let sessionSecret = try? Keychain.loadString(key: .paykitSession),
              !sessionSecret.isEmpty,
              !attemptId.isEmpty
        else { return }

        let marker = RecoveryMarker(version: 1, path: markerPath, stage: stage, attemptId: attemptId, createdAt: createdAt)
        do {
            let data = try JSONEncoder().encode(marker)
            try await PubkyService.sessionPut(sessionSecret: sessionSecret, path: markerPath, content: data)
        } catch {
            Logger.warn(
                "Failed to publish private Paykit recovery marker for \(PubkyPublicKeyFormat.redacted(readerPublicKey)): \(error)",
                context: "PrivatePaykit"
            )
        }
    }

    func clearRecoveryMarker(from writerPublicKey: String, to readerPublicKey: String) async {
        guard let markerPath = Self.recoveryMarkerPath(from: writerPublicKey, to: readerPublicKey),
              let sessionSecret = try? Keychain.loadString(key: .paykitSession),
              !sessionSecret.isEmpty
        else { return }

        try? await PubkyService.sessionDelete(sessionSecret: sessionSecret, path: markerPath)
    }

    private static func recoveryMarkerUri(from writerPublicKey: String, to readerPublicKey: String) -> String? {
        guard let writerPublicKey = PubkyPublicKeyFormat.normalized(writerPublicKey),
              let path = recoveryMarkerPath(from: writerPublicKey, to: readerPublicKey)
        else { return nil }

        return "pubky://\(writerPublicKey.dropFirst("pubky".count))\(path)"
    }

    @discardableResult
    func existingLinkId(for publicKey: String, generation: UInt64) async throws -> String? {
        try ensureCurrentGeneration(generation)
        if let linkId = activeHandlesByContact[publicKey]?.linkId {
            return linkId
        }

        guard let snapshotHex = state.contacts[publicKey]?.linkSnapshotHex,
              let secretKeyHex = try Keychain.loadString(key: .pubkySecretKey),
              !secretKeyHex.isEmpty
        else {
            return nil
        }

        let linkId = try await PubkyService.restoreEncryptedLink(secretKeyHex: secretKeyHex, snapshotHex: snapshotHex)
        try ensureCurrentGeneration(generation)
        activeHandlesByContact[publicKey] = ContactPaykitHandles(linkId: linkId, handshakeId: nil)
        return linkId
    }

    func restoreLinkHandleForReadRetry(publicKey: String, generation: UInt64) async throws -> String? {
        try ensureCurrentGeneration(generation)
        guard let snapshotHex = state.contacts[publicKey]?.linkSnapshotHex,
              let secretKeyHex = try Keychain.loadString(key: .pubkySecretKey),
              !secretKeyHex.isEmpty
        else {
            return nil
        }

        if let linkId = activeHandlesByContact[publicKey]?.linkId {
            try? await PubkyService.closeEncryptedLink(linkId: linkId)
        }
        activeHandlesByContact[publicKey]?.linkId = nil

        try ensureCurrentGeneration(generation)
        let restoredLinkId = try await PubkyService.restoreEncryptedLink(secretKeyHex: secretKeyHex, snapshotHex: snapshotHex)
        try ensureCurrentGeneration(generation)
        activeHandlesByContact[publicKey] = ContactPaykitHandles(linkId: restoredLinkId, handshakeId: nil)
        return restoredLinkId
    }
}
