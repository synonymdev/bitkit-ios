import Foundation
import Paykit

// MARK: - Payment Resolution

extension PrivatePaykitService {
    func contactPublicKey(forPrivateInvoicePaymentHash paymentHash: String) -> String? {
        guard !paymentHash.isEmpty else { return nil }

        return state.contacts.first { _, contactState in
            localInvoices(contactState).contains { $0.paymentHash == paymentHash } ||
                contactState.receivedInvoicePaymentHashes.contains(paymentHash)
        }?.key
    }

    func beginSavedContactPayment(to publicKey: String, wallet: WalletViewModel) async throws -> PublicPaykitPaymentLaunchResult {
        guard let normalizedKey = knownSavedContact(publicKey) else {
            return try await PublicPaykitService.beginPayment(to: publicKey)
        }

        return try await beginContactPayment(to: normalizedKey, receiverPath: PaykitReceiverPath.wallet, wallet: wallet)
    }

    func beginPaymentRequest(_ request: PaykitPaymentRequest, wallet: WalletViewModel) async throws -> PublicPaykitPaymentLaunchResult {
        guard !request.isExpired(at: Date()) else {
            throw PaykitPaymentRequestError.requestExpired
        }
        guard let publicKey = PubkyPublicKeyFormat.normalized(request.counterparty) else {
            throw PrivatePaykitError.invalidPublicKey
        }

        return try await beginContactPayment(
            to: publicKey,
            receiverPath: request.counterpartyReceiverPath,
            paymentRequest: request,
            wallet: wallet
        )
    }

    private func beginContactPayment(
        to publicKey: String,
        receiverPath: String,
        paymentRequest: PaykitPaymentRequest? = nil,
        wallet: WalletViewModel
    ) async throws -> PublicPaykitPaymentLaunchResult {
        guard try await hasLiveSessionForCurrentProfile() else {
            if paymentRequest != nil {
                throw PrivatePaykitError.privateUnavailable
            }
            return try await PublicPaykitService.beginPayment(to: publicKey)
        }

        if paymentRequest == nil, await canPublishPrivateEndpoints(wallet: wallet) {
            _ = await refreshSavedContactEndpointsReturningError(
                for: [publicKey],
                wallet: wallet,
                forceRefreshLightning: false,
                requireImmediatePublication: false
            )
        }

        let consumedVersion = state.contacts[publicKey]?.consumedPrivatePaymentListVersionsByReceiverPath[receiverPath]
        let amount = paymentRequest.map {
            PaymentAmountContext(value: $0.amountValue, asset: "btc")
        }

        do {
            let prepared = try await PaykitSdkService.shared.prepareAndResolvePrivateContactPayment(
                counterparty: publicKey,
                receiverPath: receiverPath,
                amount: amount,
                afterPrivatePaymentListVersion: consumedVersion
            )
            let resolution = prepared.resolution
            let linkState = try await currentLinkState(
                publicKey: publicKey,
                receiverPath: receiverPath,
                preparedState: prepared.linkReport?.state
            )

            if paymentRequest == nil, canUsePublicPayment(linkState: linkState, resolution: resolution) {
                return try await PublicPaykitService.beginPayment(to: publicKey)
            }

            let privateEndpoints = resolvedEndpoints(from: resolution)
            cacheResolvedEndpoints(privateEndpoints, publicKey: publicKey)
            let acceptedIdentifiers = paymentRequest.map { Set($0.acceptedPaymentEndpointIdentifiers) }
            let acceptedEndpoints = privateEndpoints.filter { endpoint in
                acceptedIdentifiers?.contains(endpoint.methodId.rawValue) ?? true
            }

            let payableEndpoints = await privatePayableEndpoints(from: acceptedEndpoints, publicKey: publicKey)

            if !payableEndpoints.isEmpty, let paymentListVersion = resolution.privatePaymentListVersion {
                return .opened(
                    paymentRequest: PublicPaykitService.paymentRequest(from: payableEndpoints),
                    privatePaymentContext: PrivatePaykitPaymentContext(
                        receiverPath: receiverPath,
                        paymentListVersion: paymentListVersion
                    )
                )
            }

            if resolution.state == .recoveryPending {
                schedulePrivatePaymentRecovery(for: publicKey)
            }

            if resolution.status == .waitingForUpdatedPaymentList {
                schedulePrivatePaymentRecovery(for: publicKey)
                return .waitingForUpdatedPaymentList
            }

            return acceptedEndpoints.isEmpty ? .noEndpoint : .notOpened
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw error
            }

            Logger.warn(
                "Failed to resolve Paykit contact payment for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)",
                context: "PrivatePaykit"
            )

            let linkState = try await currentLinkState(publicKey: publicKey, receiverPath: receiverPath)
            guard paymentRequest == nil, canUsePublicPayment(linkState: linkState) else {
                throw error
            }
            return try await PublicPaykitService.beginPayment(to: publicKey)
        }
    }

    func consumePrivatePaymentList(publicKey: String, context: PrivatePaykitPaymentContext) throws {
        guard let publicKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw PrivatePaykitError.invalidPublicKey
        }

        var contactState = state.contacts[publicKey, default: ContactState()]
        if let consumedVersion = contactState.consumedPrivatePaymentListVersionsByReceiverPath[context.receiverPath],
           context.paymentListVersion <= consumedVersion
        {
            throw PrivatePaykitError.paymentListAlreadyConsumed
        }

        contactState.consumedPrivatePaymentListVersionsByReceiverPath[context.receiverPath] = context.paymentListVersion
        contactState.cachedResolvedEndpoints.removeAll()
        state.contacts[publicKey] = contactState
        try persistStateOrThrow(markWalletBackup: true)
    }

    private func currentLinkState(
        publicKey: String,
        receiverPath: String,
        preparedState: LinkedPeerState? = nil
    ) async throws -> LinkedPeerState? {
        if let preparedState {
            return preparedState
        }

        return try await PaykitSdkService.shared.linkedPeers().first {
            PubkyPublicKeyFormat.matches($0.counterparty, publicKey) && $0.counterpartyReceiverPath == receiverPath
        }?.state
    }

    private func canUsePublicPayment(
        linkState: LinkedPeerState?,
        resolution: PrivateContactPaymentResolution? = nil
    ) -> Bool {
        if let resolution,
           resolution.status == .waitingForUpdatedPaymentList || resolution.state != .noPrivateEndpoint
        {
            return false
        }

        switch linkState {
        case nil, .notLinked, .linking:
            return true
        case .linked, .recoveryRequired, .blocked, .unknown:
            return false
        }
    }

    private func hasLiveSessionForCurrentProfile() async throws -> Bool {
        guard let status = try await PaykitSdkService.shared.identityStatus() else { return false }
        return status.liveSessionAvailable
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

                guard PublicPaykitService.hasLightningRouteHints(bolt11: endpoint.value),
                      await !hasAttemptedOutboundBolt11Payment(paymentHash: paymentHash)
                else {
                    staleLightningPaymentHashes.insert(paymentHash)
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
                if !isUsed {
                    reusableEndpoints.append(endpoint)
                }
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

    func discardRemoteLightningEndpoints(publicKey: String, paymentHashes: Set<String>) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey),
              var contactState = state.contacts[normalizedKey],
              !paymentHashes.isEmpty
        else { return }

        let previousCount = contactState.cachedResolvedEndpoints.count
        var filteredEntries: [StoredPaymentEntry] = []

        for entry in contactState.cachedResolvedEndpoints {
            guard entry.methodId == PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                  let endpoint = PublicPaykitService.parseEndpoint(methodId: entry.methodId, endpointData: entry.endpointData),
                  let paymentHash = await paymentHash(forBolt11: endpoint.value),
                  paymentHashes.contains(paymentHash)
            else {
                filteredEntries.append(entry)
                continue
            }
        }

        guard filteredEntries.count != previousCount else { return }

        contactState.cachedResolvedEndpoints = filteredEntries
        state.contacts[normalizedKey] = contactState
        persistState(markWalletBackup: true)
    }

    func discardRemoteOnchainEndpoints(publicKey: String, addresses: Set<String>) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey),
              var contactState = state.contacts[normalizedKey],
              !addresses.isEmpty
        else { return }

        let previousCount = contactState.cachedResolvedEndpoints.count
        contactState.cachedResolvedEndpoints = contactState.cachedResolvedEndpoints.filter { entry in
            guard PublicPaykitService.MethodId.onchainPreferenceOrder.contains(where: { $0.rawValue == entry.methodId }),
                  let endpoint = PublicPaykitService.parseEndpoint(methodId: entry.methodId, endpointData: entry.endpointData)
            else {
                return true
            }

            return !addresses.contains(endpoint.value)
        }

        guard contactState.cachedResolvedEndpoints.count != previousCount else { return }

        state.contacts[normalizedKey] = contactState
        persistState(markWalletBackup: true)
    }

    private func resolvedEndpoints(from resolution: PrivateContactPaymentResolution) -> [PublicPaykitService.Endpoint] {
        resolution.payableEndpoints.compactMap {
            return PublicPaykitService.parseEndpoint(identifier: $0.identifier, payload: $0.target.payload)
        }
    }
}
