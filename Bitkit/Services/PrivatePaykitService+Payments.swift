import Foundation

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
            try await publishLocalEndpointsBestEffort(
                to: normalizedKey,
                linkId: linkId,
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
            if hadCachedPrivateEndpoint, !shouldCountAsStaleLinkFailure(error) {
                return true
            }
        }

        return await (try? PublicPaykitService.hasPayablePublicEndpoint(publicKey: normalizedKey)) == true
    }

    func beginSavedContactPayment(to publicKey: String, wallet: WalletViewModel) async throws -> PublicPaykitPaymentLaunchResult {
        guard let normalizedKey = knownSavedContact(publicKey) else {
            return try await PublicPaykitService.beginPayment(to: publicKey)
        }

        do {
            let privateResult = try await beginPrivatePayment(
                to: normalizedKey,
                wallet: wallet
            )
            if case .opened = privateResult {
                return privateResult
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.warn(
                "Falling back to public Paykit for \(PubkyPublicKeyFormat.redacted(normalizedKey)) after private payment failed: \(error)",
                context: "PrivatePaykit"
            )
        }

        return try await PublicPaykitService.beginPayment(to: publicKey)
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
        do {
            fetchedCount = try await fetchRemoteEndpoints(publicKey: normalizedKey, linkId: linkId, generation: generation)
        } catch {
            try Task.checkCancellation()
            if shouldCountAsStaleLinkFailure(error) {
                Logger.warn(
                    "Discarding cached private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(normalizedKey)) after stale link failure: \(error)",
                    context: "PrivatePaykit"
                )
                throw error
            }
            Logger.warn(
                "Failed to refresh private Paykit endpoints for \(PubkyPublicKeyFormat.redacted(normalizedKey)); using cached private endpoints if available: \(error)",
                context: "PrivatePaykit"
            )
        }

        try await publishLocalEndpointsBestEffort(
            to: normalizedKey,
            linkId: linkId,
            wallet: wallet,
            generation: generation,
            context: "payment",
            fetchedRemoteCount: fetchedCount
        )

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

    func privatePayableEndpoints(from endpoints: [PublicPaykitService.Endpoint], publicKey: String) async -> [PublicPaykitService.Endpoint] {
        let payableEndpoints = await PublicPaykitService.payableEndpoints(from: endpoints)
        var reusableEndpoints: [PublicPaykitService.Endpoint] = []

        for endpoint in payableEndpoints {
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

        return reusableEndpoints
    }

    @discardableResult
    func fetchRemoteEndpoints(publicKey: String, linkId: String, generation: UInt64) async throws -> Int {
        do {
            let remoteEntries = try await PubkyService.getPrivatePayments(linkId: linkId)
            try ensureCurrentGeneration(generation)
            recordLinkSuccess(publicKey: publicKey)

            guard !remoteEntries.isEmpty else {
                // Paykit returns an empty map when there are no unread private-payment messages.
                // Keep the cached map in that case; the current rc5 API cannot distinguish
                // "no unread update" from a peer intentionally publishing an empty map.
                return 0
            }

            try await persistLinkSnapshot(linkId: linkId, publicKey: publicKey, generation: generation)
            try ensureCurrentGeneration(generation)
            state.contacts[publicKey, default: ContactState()].remoteEndpoints = remoteEntries.map(StoredPaymentEntry.init(entry:))
            persistState(markWalletBackup: true)
            return remoteEntries.count
        } catch {
            await recordLinkFailure(publicKey: publicKey, error: error, generation: generation)
            throw error
        }
    }
}
