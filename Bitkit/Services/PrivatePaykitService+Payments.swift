import Foundation
import Paykit

enum PrivatePaymentListSendOutcome: Equatable {
    case succeeded
    case definitePreBroadcastFailure
    case uncertain
}

extension ContactPaymentContext {
    func resolvePrivatePaymentListConsumption(
        _ outcome: PrivatePaymentListSendOutcome,
        service: PrivatePaykitService = .shared
    ) async {
        guard incomingPaymentRequest != nil, let privatePaymentContext else { return }

        do {
            try await service.resolvePrivatePaymentListConsumption(
                publicKey: publicKey,
                context: privatePaymentContext,
                attemptId: id,
                outcome: outcome
            )
        } catch {
            Logger.error("Failed to resolve private Paykit payment list consumption: \(error)", context: "PrivatePaykit")
        }
    }
}

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

        if prePaymentPublicationKeys.insert(normalizedKey).inserted {
            Task {
                defer { prePaymentPublicationKeys.remove(normalizedKey) }
                guard await canPublishPrivateEndpoints(wallet: wallet) else { return }
                _ = await refreshSavedContactEndpointsReturningError(
                    for: [normalizedKey],
                    wallet: wallet,
                    forceRefreshLightning: false,
                    requireImmediatePublication: false
                )
            }
        }

        var result = try await beginContactPayment(to: normalizedKey, receiverPath: PaykitReceiverPath.wallet)
        for delay in Self.privatePaymentResolutionRetryDelays {
            guard case .waitingForUpdatedPaymentList = result else { return result }
            try await Task.sleep(nanoseconds: delay)
            result = try await beginContactPayment(to: normalizedKey, receiverPath: PaykitReceiverPath.wallet)
        }
        return result
    }

    func beginPaymentRequest(_ request: PaykitPaymentRequest) async throws -> PublicPaykitPaymentLaunchResult {
        guard !request.isExpired(at: Date()) else {
            throw PaykitPaymentRequestError.requestExpired
        }
        guard let publicKey = PubkyPublicKeyFormat.normalized(request.counterparty) else {
            throw PrivatePaykitError.invalidPublicKey
        }

        return try await beginContactPayment(
            to: publicKey,
            receiverPath: request.counterpartyReceiverPath,
            paymentRequest: request
        )
    }

    func beginPaymentRequestWaitingForUpdatedList(_ request: PaykitPaymentRequest) async throws -> PublicPaykitPaymentLaunchResult {
        var result = try await beginPaymentRequest(request)
        for delay in Self.privatePaymentResolutionRetryDelays {
            guard case .waitingForUpdatedPaymentList = result else { return result }
            try await Task.sleep(nanoseconds: delay)
            result = try await beginPaymentRequest(request)
        }
        return result
    }

    private func beginContactPayment(
        to publicKey: String,
        receiverPath: String,
        paymentRequest: PaykitPaymentRequest? = nil
    ) async throws -> PublicPaykitPaymentLaunchResult {
        let consumedVersion = state.contacts[publicKey]?.consumedPrivatePaymentListVersionsByReceiverPath[receiverPath]
        let previousPaymentListVersion = consumedVersion.map(String.init) ?? "none"
        let amount = paymentRequest.map {
            PaymentAmountContext(value: $0.amountValue, asset: PaykitIssuerInterop.bitcoinAsset)
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

            if paymentRequest != nil,
               Self.paymentRequestNeedsPrivateLinkRecovery(resolutionState: resolution.state, linkState: linkState)
            {
                schedulePrivatePaymentRecovery(for: publicKey, receiverPath: receiverPath)
                return .privateLinkPending
            }

            let privateEndpoints = resolvedEndpoints(from: resolution)
            cacheResolvedEndpoints(privateEndpoints, publicKey: publicKey)
            let acceptedIdentifiers = paymentRequest.map { Set($0.acceptedPaymentEndpointIdentifiers) }
            let acceptedEndpoints = privateEndpoints.filter { endpoint in
                acceptedIdentifiers?.contains(endpoint.methodId.rawValue) ?? true
            }

            let payableEndpoints = await privatePayableEndpoints(from: acceptedEndpoints, publicKey: publicKey)

            if !payableEndpoints.isEmpty, let paymentListVersion = resolution.privatePaymentListVersion {
                Logger.info(
                    "Opened private Paykit payment for \(PubkyPublicKeyFormat.redacted(publicKey)) using payment list version \(paymentListVersion) after \(previousPaymentListVersion)",
                    context: "PrivatePaykit"
                )
                return .opened(
                    paymentRequest: PublicPaykitService.paymentRequest(from: payableEndpoints),
                    privatePaymentContext: PrivatePaykitPaymentContext(
                        receiverPath: receiverPath,
                        paymentListVersion: paymentListVersion
                    )
                )
            }

            if resolution.state == .recoveryPending {
                schedulePrivatePaymentRecovery(for: publicKey, receiverPath: receiverPath)
            }

            if resolution.status == .waitingForUpdatedPaymentList {
                Logger.info(
                    "Waiting for a private Paykit payment list newer than \(previousPaymentListVersion) for \(PubkyPublicKeyFormat.redacted(publicKey)); public resolution is disabled for this request",
                    context: "PrivatePaykit"
                )
                schedulePrivatePaymentRecovery(for: publicKey, receiverPath: receiverPath)
                return .waitingForUpdatedPaymentList
            }

            return acceptedEndpoints.isEmpty ? .noEndpoint : .notOpened
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw error
            }

            Logger.warn(
                "Failed to resolve Paykit contact payment for \(PubkyPublicKeyFormat.redacted(publicKey)): " +
                    "reason=\(PaykitResolutionFailureDiagnostics.reason(for: error))",
                context: "PrivatePaykit"
            )

            if paymentRequest != nil, PaykitResolutionFailureDiagnostics.isRecoveryRequired(error) {
                schedulePrivatePaymentRecovery(for: publicKey, receiverPath: receiverPath)
                return .privateLinkPending
            }

            let linkState: LinkedPeerState?
            do {
                linkState = try await currentLinkState(publicKey: publicKey, receiverPath: receiverPath)
            } catch {
                if paymentRequest != nil, PaykitResolutionFailureDiagnostics.isRecoveryRequired(error) {
                    schedulePrivatePaymentRecovery(for: publicKey, receiverPath: receiverPath)
                    return .privateLinkPending
                }
                throw error
            }
            if paymentRequest != nil, Self.paymentRequestNeedsPrivateLinkRecovery(linkState: linkState) {
                schedulePrivatePaymentRecovery(for: publicKey, receiverPath: receiverPath)
                return .privateLinkPending
            }
            guard paymentRequest == nil, canUsePublicPayment(linkState: linkState) else {
                throw error
            }
            return try await PublicPaykitService.beginPayment(to: publicKey)
        }
    }

    func consumePrivatePaymentList(
        publicKey: String,
        context: PrivatePaykitPaymentContext,
        attemptId: UUID
    ) throws {
        guard let publicKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw PrivatePaykitError.invalidPublicKey
        }

        var contactState = state.contacts[publicKey, default: ContactState()]
        let consumedVersion = contactState.consumedPrivatePaymentListVersionsByReceiverPath[context.receiverPath]
        if let consumedVersion,
           context.paymentListVersion <= consumedVersion
        {
            throw PrivatePaykitError.paymentListAlreadyConsumed
        }

        let previousContactState = state.contacts[publicKey]
        contactState.consumedPrivatePaymentListVersionsByReceiverPath[context.receiverPath] = context.paymentListVersion
        contactState.cachedResolvedEndpoints.removeAll()
        state.contacts[publicKey] = contactState
        do {
            try persistStateOrThrow(markWalletBackup: true)
        } catch {
            state.contacts[publicKey] = previousContactState
            throw error
        }

        let consumptionKey = PrivatePaymentListConsumptionKey(
            attemptId: attemptId,
            publicKey: publicKey,
            receiverPath: context.receiverPath
        )
        privatePaymentListConsumptions[consumptionKey] = PrivatePaymentListConsumption(
            paymentListVersion: context.paymentListVersion,
            previousPaymentListVersion: consumedVersion
        )
        Logger.info(
            "Consumed private Paykit payment list version \(context.paymentListVersion) for \(PubkyPublicKeyFormat.redacted(publicKey))",
            context: "PrivatePaykit"
        )
    }

    func resolvePrivatePaymentListConsumption(
        publicKey: String,
        context: PrivatePaykitPaymentContext,
        attemptId: UUID,
        outcome: PrivatePaymentListSendOutcome
    ) throws {
        guard let publicKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw PrivatePaykitError.invalidPublicKey
        }

        let consumptionKey = PrivatePaymentListConsumptionKey(
            attemptId: attemptId,
            publicKey: publicKey,
            receiverPath: context.receiverPath
        )
        guard let consumption = privatePaymentListConsumptions[consumptionKey],
              consumption.paymentListVersion == context.paymentListVersion
        else { return }

        guard outcome == .definitePreBroadcastFailure else {
            privatePaymentListConsumptions[consumptionKey] = nil
            return
        }

        var contactState = state.contacts[publicKey, default: ContactState()]
        guard contactState.consumedPrivatePaymentListVersionsByReceiverPath[context.receiverPath] == context.paymentListVersion else {
            privatePaymentListConsumptions[consumptionKey] = nil
            return
        }

        let previousContactState = state.contacts[publicKey]
        contactState.consumedPrivatePaymentListVersionsByReceiverPath[context.receiverPath] = consumption.previousPaymentListVersion
        state.contacts[publicKey] = contactState
        do {
            try persistStateOrThrow(markWalletBackup: true)
            privatePaymentListConsumptions[consumptionKey] = nil
        } catch {
            state.contacts[publicKey] = previousContactState
            throw error
        }
        Logger.info(
            "Released private Paykit payment list version \(context.paymentListVersion) for \(PubkyPublicKeyFormat.redacted(publicKey))",
            context: "PrivatePaykit"
        )
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

    static func paymentRequestNeedsPrivateLinkRecovery(
        resolutionState: PrivatePaymentResolutionState? = nil,
        linkState: LinkedPeerState?
    ) -> Bool {
        if resolutionState == .recoveryPending {
            return true
        }

        switch linkState {
        case .linking, .recoveryRequired:
            return true
        case nil, .notLinked, .linked, .blocked, .unknown:
            return false
        }
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

    private func resolvedEndpoints(from resolution: PrivateContactPaymentResolution) -> [PublicPaykitService.Endpoint] {
        resolution.payableEndpoints.compactMap {
            return PublicPaykitService.parseEndpoint(identifier: $0.identifier, payload: $0.target.payload)
        }
    }
}

private extension PrivatePaykitService {
    static var privatePaymentResolutionRetryDelays: ArraySlice<UInt64> {
        privateMessageDrainRetryDelays.prefix(3)
    }
}
