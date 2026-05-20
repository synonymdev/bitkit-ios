import Foundation
import Paykit

// MARK: - Payment Resolution

extension PrivatePaykitService {
    func hasCachedPrivateEndpoint(publicKey: String) async -> Bool {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey),
              let contactState = state.contacts[normalizedKey]
        else { return false }

        let endpoints = contactState.remoteEndpoints.compactMap {
            PublicPaykitService.parseEndpoint(methodId: $0.methodId, endpointData: $0.endpointData)
        }
        let payableEndpoints = await privatePayableEndpoints(from: endpoints, publicKey: normalizedKey)
        return !payableEndpoints.isEmpty
    }

    func cachedPrivatePaymentResult(publicKey: String) async -> PublicPaykitPaymentLaunchResult {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            return .noEndpoint
        }

        let cachedEntries = state.contacts[normalizedKey]?.remoteEndpoints ?? []
        let endpoints = cachedEntries.compactMap {
            PublicPaykitService.parseEndpoint(methodId: $0.methodId, endpointData: $0.endpointData)
        }
        let payableEndpoints = await privatePayableEndpoints(from: endpoints, publicKey: normalizedKey)

        guard !payableEndpoints.isEmpty else {
            return cachedEntries.isEmpty ? .noEndpoint : .notOpened
        }

        return .opened(paymentRequest: PublicPaykitService.paymentRequest(from: payableEndpoints))
    }

    func contactPublicKey(forPrivateInvoicePaymentHash paymentHash: String) -> String? {
        guard !paymentHash.isEmpty else { return nil }

        return state.contacts.first { _, contactState in
            contactState.localInvoice?.paymentHash == paymentHash ||
                contactState.receivedInvoicePaymentHashes.contains(paymentHash)
        }?.key
    }

    func resolveSavedContactPayableEndpoint(publicKey: String, wallet: WalletViewModel) async -> Bool {
        guard let normalizedKey = knownSavedContact(publicKey) else {
            return await (try? PublicPaykitService.hasPayablePublicEndpoint(publicKey: publicKey)) == true
        }

        return await resolvePayableEndpoint(publicKey: normalizedKey, wallet: wallet)
    }

    func resolvePayableEndpoint(publicKey: String, wallet: WalletViewModel) async -> Bool {
        let generation = stateGeneration
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            return await (try? PublicPaykitService.hasPayablePublicEndpoint(publicKey: publicKey)) == true
        }

        let hadCachedPrivateEndpoint = await hasCachedPrivateEndpoint(publicKey: normalizedKey)

        do {
            guard let linkId = try await establishedLinkId(for: normalizedKey, maxAdvanceSteps: 3, generation: generation) else {
                if hadCachedPrivateEndpoint {
                    return true
                }
                return await (try? PublicPaykitService.hasPayablePublicEndpoint(publicKey: normalizedKey)) == true
            }

            if state.contacts[normalizedKey]?.lastLocalPayloadHash == nil {
                try await publishLocalEndpointsBestEffort(
                    to: normalizedKey,
                    linkId: linkId,
                    wallet: wallet,
                    generation: generation,
                    context: "resolve",
                    fetchedRemoteCount: 0
                )
            }

            let fetchedCount = try await fetchRemoteEndpoints(publicKey: normalizedKey, linkId: linkId, generation: generation)
            let publishLinkId = activeHandlesByContact[normalizedKey]?.linkId ?? linkId
            try await publishLocalEndpointsBestEffort(
                to: normalizedKey,
                linkId: publishLinkId,
                wallet: wallet,
                generation: generation,
                context: "resolve",
                fetchedRemoteCount: fetchedCount
            )

            if await hasCachedPrivateEndpoint(publicKey: normalizedKey) {
                return true
            }
        } catch {
            Logger.warn(
                "Failed to resolve private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(normalizedKey)): \(error)",
                context: "PrivatePaykit"
            )
            if hadCachedPrivateEndpoint {
                if shouldCountAsStaleLinkFailure(error) {
                    schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
                }
                return true
            }
        }

        return await (try? PublicPaykitService.hasPayablePublicEndpoint(publicKey: normalizedKey)) == true
    }

    func beginSavedContactPayment(to publicKey: String, wallet: WalletViewModel) async throws -> PublicPaykitPaymentLaunchResult {
        guard let normalizedKey = knownSavedContact(publicKey) else {
            return try await PublicPaykitService.beginPayment(to: publicKey)
        }
        guard let ownPublicKey = await PubkyService.currentPublicKey(),
              PubkyProfileManager.hasLocalSecretKey(for: ownPublicKey)
        else {
            return try await PublicPaykitService.beginPayment(to: publicKey)
        }

        let privateAttempt = try await beginPrivatePaymentWithRecoveryRetry(
            to: normalizedKey,
            wallet: wallet
        )
        let privateResult: PublicPaykitPaymentLaunchResult?
        let privateError: Error?
        switch privateAttempt.result {
        case let .success(result):
            privateResult = result
            privateError = nil
        case let .failure(error):
            if error is CancellationError {
                throw CancellationError()
            }
            privateResult = nil
            privateError = error
        }

        if let privateResult, case .opened = privateResult {
            return privateResult
        }

        if privateAttempt.shouldDeferPublicFallback || shouldDeferPublicFallbackForPrivateRecovery(publicKey: normalizedKey) {
            if let privateError {
                Logger.warn(
                    "Deferring public Paykit fallback for \(PubkyPublicKeyFormat.redacted(normalizedKey)) while private payment recovery completes: \(privateError)",
                    context: "PrivatePaykit"
                )
            }
            return privateResult ?? .noEndpoint
        }

        if let privateError {
            Logger.warn(
                "Falling back to public Paykit for \(PubkyPublicKeyFormat.redacted(normalizedKey)) after private payment failed: \(privateError)",
                context: "PrivatePaykit"
            )
        }

        return try await PublicPaykitService.beginPayment(to: publicKey)
    }

    func beginPrivatePaymentWithRecoveryRetry(to publicKey: String, wallet: WalletViewModel) async throws -> PrivatePaymentAttempt {
        var shouldDeferPublicFallback = shouldDeferPublicFallbackForPrivateRecovery(publicKey: publicKey)
        var result = await privatePaymentAttempt(to: publicKey, wallet: wallet)

        for _ in 0 ..< Self.privatePaymentRecoveryRetryAttempts {
            shouldDeferPublicFallback = shouldDeferPublicFallback || shouldDeferPublicFallbackForPrivateRecovery(publicKey: publicKey)
            guard try shouldRetryPrivatePaymentBeforePublicFallback(
                publicKey: publicKey,
                result: result,
                shouldDeferPublicFallback: shouldDeferPublicFallback
            ) else {
                return PrivatePaymentAttempt(result: result, shouldDeferPublicFallback: shouldDeferPublicFallback)
            }

            try await Task.sleep(nanoseconds: Self.privatePaymentRecoveryRetryDelay)
            result = await privatePaymentAttempt(to: publicKey, wallet: wallet)
        }

        shouldDeferPublicFallback = shouldDeferPublicFallback || shouldDeferPublicFallbackForPrivateRecovery(publicKey: publicKey)
        return PrivatePaymentAttempt(result: result, shouldDeferPublicFallback: shouldDeferPublicFallback)
    }

    func shouldRetryPrivatePaymentBeforePublicFallback(
        publicKey: String,
        result: Result<PublicPaykitPaymentLaunchResult, Error>,
        shouldDeferPublicFallback: Bool
    ) throws -> Bool {
        if case .success(.opened) = result {
            return false
        }

        if case let .failure(error) = result {
            if error is CancellationError {
                throw CancellationError()
            }
            if let privateError = error as? PrivatePaykitError,
               case .privateUnavailable = privateError
            {
                return shouldDeferPublicFallback || shouldDeferPublicFallbackForPrivateRecovery(publicKey: publicKey)
            }
        }

        return shouldDeferPublicFallback || shouldDeferPublicFallbackForPrivateRecovery(publicKey: publicKey)
    }

    func shouldDeferPublicFallbackForPrivateRecovery(publicKey: String) -> Bool {
        let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
        return shouldDeferPublicFallbackForPrivateRecovery(contactState: state.contacts[normalizedKey])
    }

    func shouldDeferPublicFallbackForPrivateRecovery(contactState: ContactState?) -> Bool {
        guard let contactState else { return false }

        return contactState.recoveryStartedAt != nil ||
            contactState.mainRecoveryAttemptId != nil ||
            contactState.responderRecoveryAttemptId != nil ||
            contactState.awaitingRecoveredRemoteEndpoints
    }

    func clearAwaitingRecoveredRemoteEndpoints(publicKey: String) {
        guard state.contacts[publicKey]?.awaitingRecoveredRemoteEndpoints == true else {
            return
        }

        state.contacts[publicKey]?.awaitingRecoveredRemoteEndpoints = false
        persistState(markWalletBackup: true)
    }

    private func privatePaymentAttempt(to publicKey: String, wallet: WalletViewModel) async -> Result<PublicPaykitPaymentLaunchResult, Error> {
        do {
            let result = try await beginPrivatePayment(
                to: publicKey,
                wallet: wallet
            )
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    func beginPrivatePayment(to publicKey: String, wallet: WalletViewModel) async throws -> PublicPaykitPaymentLaunchResult {
        let generation = stateGeneration
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey),
              let linkId = try await establishedLinkId(for: normalizedKey, maxAdvanceSteps: 5, generation: generation)
        else {
            throw PrivatePaykitError.privateUnavailable
        }

        if state.contacts[normalizedKey]?.lastLocalPayloadHash == nil {
            try await publishLocalEndpointsBestEffort(
                to: normalizedKey,
                linkId: linkId,
                wallet: wallet,
                generation: generation,
                context: "payment",
                fetchedRemoteCount: 0
            )
        }

        var fetchedCount = 0
        var staleFetchError: Error?
        do {
            fetchedCount = try await fetchRemoteEndpoints(publicKey: normalizedKey, linkId: linkId, generation: generation)
        } catch {
            try Task.checkCancellation()
            if shouldCountAsStaleLinkFailure(error) {
                Logger.warn(
                    "Private Paykit link is stale for \(PubkyPublicKeyFormat.redacted(normalizedKey)); using cached private endpoints if available while recovery retries: \(error)",
                    context: "PrivatePaykit"
                )
                staleFetchError = error
                schedulePendingPublicationRetry(for: normalizedKey, wallet: wallet)
            } else {
                Logger.warn(
                    "Failed to refresh private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(normalizedKey)); using cached private endpoints if available: \(error)",
                    context: "PrivatePaykit"
                )
            }
        }

        if staleFetchError == nil {
            let publishLinkId = activeHandlesByContact[normalizedKey]?.linkId ?? linkId
            try await publishLocalEndpointsBestEffort(
                to: normalizedKey,
                linkId: publishLinkId,
                wallet: wallet,
                generation: generation,
                context: "payment",
                fetchedRemoteCount: fetchedCount
            )
        }

        let cachedResult = await cachedPrivatePaymentResult(publicKey: normalizedKey)
        if case .opened = cachedResult {
            clearAwaitingRecoveredRemoteEndpoints(publicKey: normalizedKey)
            return cachedResult
        }

        if let staleFetchError {
            throw staleFetchError
        }

        return cachedResult
    }

    func privatePayableEndpoints(from endpoints: [PublicPaykitService.Endpoint], publicKey: String) async -> [PublicPaykitService.Endpoint] {
        let payableEndpoints = await PublicPaykitService.payableEndpoints(from: endpoints)
        var reusableEndpoints: [PublicPaykitService.Endpoint] = []
        var staleLightningPaymentHashes = Set<String>()

        for endpoint in payableEndpoints {
            if endpoint.methodId == .bitcoinLightningBolt11 {
                guard let paymentHash = await paymentHash(forBolt11: endpoint.value) else {
                    continue
                }

                guard PublicPaykitService.hasLightningRouteHints(bolt11: endpoint.value) else {
                    staleLightningPaymentHashes.insert(paymentHash)
                    Logger.warn(
                        "Ignoring private Paykit Lightning endpoint without route hints from \(PubkyPublicKeyFormat.redacted(publicKey))",
                        context: "PrivatePaykit"
                    )
                    continue
                }

                if await hasAttemptedOutboundBolt11Payment(paymentHash: paymentHash) {
                    staleLightningPaymentHashes.insert(paymentHash)
                    Logger.warn(
                        "Ignoring already-attempted private Paykit Lightning endpoint from \(PubkyPublicKeyFormat.redacted(publicKey))",
                        context: "PrivatePaykit"
                    )
                    continue
                }

                reusableEndpoints.append(endpoint)
                continue
            }

            guard PublicPaykitService.MethodId.onchainPreferenceOrder.contains(endpoint.methodId) else {
                reusableEndpoints.append(endpoint)
                continue
            }

            do {
                let isUsed = try await CoreService.shared.utility.isAddressUsed(address: endpoint.value)
                guard !isUsed else {
                    Logger.warn(
                        "Ignoring used private Paykit on-chain endpoint from \(PubkyPublicKeyFormat.redacted(publicKey))",
                        context: "PrivatePaykit"
                    )
                    continue
                }
                reusableEndpoints.append(endpoint)
            } catch {
                Logger.warn(
                    "Failed to verify private Paykit on-chain endpoint usage for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }

        if !staleLightningPaymentHashes.isEmpty {
            await discardRemoteLightningEndpoints(publicKey: publicKey, paymentHashes: staleLightningPaymentHashes)
        }

        return reusableEndpoints
    }

    @discardableResult
    func fetchRemoteEndpoints(publicKey: String, linkId: String, generation: UInt64) async throws -> Int {
        do {
            return try await readRemoteEndpoints(publicKey: publicKey, linkId: linkId, generation: generation)
        } catch {
            try Task.checkCancellation()
            if shouldCountAsStaleLinkFailure(error),
               let restoredLinkId = try? await restoreLinkHandleForReadRetry(publicKey: publicKey, generation: generation)
            {
                do {
                    Logger.info(
                        "Retrying private Paykit endpoint fetch after restoring link snapshot for \(PubkyPublicKeyFormat.redacted(publicKey))",
                        context: "PrivatePaykit"
                    )
                    return try await readRemoteEndpoints(publicKey: publicKey, linkId: restoredLinkId, generation: generation)
                } catch {
                    await recordLinkFailure(publicKey: publicKey, error: error, generation: generation)
                    throw error
                }
            }

            await recordLinkFailure(publicKey: publicKey, error: error, generation: generation)
            throw error
        }
    }

    @discardableResult
    func readRemoteEndpoints(publicKey: String, linkId: String, generation: UInt64) async throws -> Int {
        let remotePayload = try await PubkyService.getPrivatePayments(linkId: linkId)
        try ensureCurrentGeneration(generation)
        recordLinkSuccess(publicKey: publicKey)
        try await persistLinkSnapshot(linkId: linkId, publicKey: publicKey, generation: generation)
        try ensureCurrentGeneration(generation)

        guard let remotePayload else {
            // No unread private-payment envelope. Keep the cached map so transient empty reads do not drop the last known endpoints.
            return 0
        }

        return cacheRemoteEndpoints(remotePayload.entries, publicKey: publicKey)
    }

    @discardableResult
    func cacheRemoteEndpoints(_ remoteEntries: [FfiPaymentEntry], publicKey: String) -> Int {
        state.contacts[publicKey, default: ContactState()].remoteEndpoints = remoteEntries.map(StoredPaymentEntry.init(entry:))
        persistState(markWalletBackup: true)
        return remoteEntries.count
    }

    func discardRemoteLightningEndpoints(publicKey: String, paymentHashes: Set<String>) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey),
              var contactState = state.contacts[normalizedKey],
              !paymentHashes.isEmpty
        else { return }

        var filteredEntries: [StoredPaymentEntry] = []
        var didRemoveEndpoint = false

        for entry in contactState.remoteEndpoints {
            guard entry.methodId == PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                  let endpoint = PublicPaykitService.parseEndpoint(methodId: entry.methodId, endpointData: entry.endpointData),
                  let paymentHash = await paymentHash(forBolt11: endpoint.value),
                  paymentHashes.contains(paymentHash)
            else {
                filteredEntries.append(entry)
                continue
            }

            didRemoveEndpoint = true
        }

        guard didRemoveEndpoint else { return }

        contactState.remoteEndpoints = filteredEntries
        state.contacts[normalizedKey] = contactState
        persistState(markWalletBackup: true)
    }

    func discardRemoteOnchainEndpoints(publicKey: String, addresses: Set<String>) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey),
              var contactState = state.contacts[normalizedKey],
              !addresses.isEmpty
        else { return }

        let previousCount = contactState.remoteEndpoints.count
        contactState.remoteEndpoints = contactState.remoteEndpoints.filter { entry in
            guard PublicPaykitService.MethodId.onchainPreferenceOrder.contains(where: { $0.rawValue == entry.methodId }),
                  let endpoint = PublicPaykitService.parseEndpoint(methodId: entry.methodId, endpointData: entry.endpointData)
            else {
                return true
            }

            return !addresses.contains(endpoint.value)
        }

        guard contactState.remoteEndpoints.count != previousCount else { return }

        state.contacts[normalizedKey] = contactState
        persistState(markWalletBackup: true)
    }
}
