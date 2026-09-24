import BitkitCore
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
            contactState.localInvoice?.paymentHash == paymentHash ||
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

        var result = try await beginContactPayment(to: normalizedKey)
        for delay in Self.privatePaymentResolutionRetryDelays {
            guard case .waitingForUpdatedPaymentList = result else { return result }
            try await Task.sleep(nanoseconds: delay)
            result = try await beginContactPayment(to: normalizedKey)
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
        paymentRequest: PaykitPaymentRequest? = nil
    ) async throws -> PublicPaykitPaymentLaunchResult {
        let consumedVersion = state.contacts[publicKey]?.consumedPrivatePaymentListVersion
        let previousPaymentListVersion = consumedVersion.map(String.init) ?? "none"
        do {
            let prepared: PreparedPrivateContactPayment = if let paymentRequest {
                try await PaykitSdkService.shared.prepareAndResolvePrivatePaymentRequest(
                    counterparty: publicKey,
                    paymentRequestId: paymentRequest.paymentRequestId,
                    afterPrivatePaymentListVersion: consumedVersion
                )
            } else {
                try await PaykitSdkService.shared.prepareAndResolvePrivateContactPayment(
                    counterparty: publicKey,
                    afterPrivatePaymentListVersion: consumedVersion
                )
            }
            let resolution = prepared.resolution
            let linkState = try await currentLinkState(
                publicKey: publicKey,
                preparedState: prepared.linkReport?.state
            )

            if paymentRequest == nil, canUsePublicPayment(linkState: linkState, resolution: resolution) {
                return try await PublicPaykitService.beginPayment(to: publicKey)
            }

            if paymentRequest != nil,
               Self.paymentRequestNeedsPrivateLinkRecovery(resolutionState: resolution.state, linkState: linkState)
            {
                schedulePrivatePaymentRecovery(for: publicKey)
                return .privateLinkPending
            }

            let result = await privatePaymentResult(
                publicKey: publicKey,
                paymentRequest: paymentRequest,
                resolution: resolution,
                validateEndpoints: { await self.privatePayableEndpoints(from: $0, publicKey: publicKey) }
            )
            if case .opened = result { return result }

            if resolution.state == .recoveryPending {
                schedulePrivatePaymentRecovery(for: publicKey)
            }

            if resolution.status == .waitingForUpdatedPaymentList {
                Logger.info(
                    "Waiting for a private Paykit payment list newer than \(previousPaymentListVersion) for \(PubkyPublicKeyFormat.redacted(publicKey)); public resolution is disabled for this request",
                    context: "PrivatePaykit"
                )
                schedulePrivatePaymentRecovery(for: publicKey)
                return .waitingForUpdatedPaymentList
            }

            return result
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
                schedulePrivatePaymentRecovery(for: publicKey)
                return .privateLinkPending
            }

            let linkState: LinkedPeerState?
            do {
                linkState = try await currentLinkState(publicKey: publicKey)
            } catch {
                if paymentRequest != nil, PaykitResolutionFailureDiagnostics.isRecoveryRequired(error) {
                    schedulePrivatePaymentRecovery(for: publicKey)
                    return .privateLinkPending
                }
                throw error
            }
            if paymentRequest != nil, Self.paymentRequestNeedsPrivateLinkRecovery(linkState: linkState) {
                schedulePrivatePaymentRecovery(for: publicKey)
                return .privateLinkPending
            }
            guard paymentRequest == nil, canUsePublicPayment(linkState: linkState) else {
                throw error
            }
            return try await PublicPaykitService.beginPayment(to: publicKey)
        }
    }

    func privatePaymentResult(
        publicKey: String,
        paymentRequest: PaykitPaymentRequest?,
        resolution: PrivateContactPaymentResolution,
        validateEndpoints: ([PublicPaykitService.Endpoint]) async -> [PublicPaykitService.Endpoint]
    ) async -> PublicPaykitPaymentLaunchResult {
        let privateEndpoints = resolvedEndpoints(from: resolution)
        let paymentListVersion = resolution.privatePaymentListVersion
        if paymentListVersion != nil {
            cacheResolvedEndpoints(privateEndpoints, publicKey: publicKey)
        }
        let acceptedIdentifiers = paymentRequest.map { Set($0.acceptedPaymentEndpointIdentifiers) }
        let acceptedEndpoints = privateEndpoints.filter { endpoint in
            acceptedIdentifiers?.contains(endpoint.methodId.rawValue) ?? true
        }
        let payableEndpoints = await validateEndpoints(acceptedEndpoints)
        guard !payableEndpoints.isEmpty, paymentListVersion != nil || paymentRequest != nil else {
            return acceptedEndpoints.isEmpty ? .noEndpoint : .notOpened
        }
        Logger.info(
            "Opened private Paykit payment for \(PubkyPublicKeyFormat.redacted(publicKey)) " +
                "using payment list version \(paymentListVersion.map(String.init) ?? "none")",
            context: "PrivatePaykit"
        )
        return .opened(
            paymentRequest: PublicPaykitService.paymentRequest(from: payableEndpoints),
            privatePaymentContext: PrivatePaykitPaymentContext(
                paymentAppsByEndpoint: Dictionary(
                    payableEndpoints.compactMap { endpoint in endpoint.appId.map { (endpoint.methodId.rawValue, $0) } },
                    uniquingKeysWith: { first, _ in first }
                ),
                paymentListVersion: paymentListVersion
            )
        )
    }

    func consumePrivatePaymentList(
        publicKey: String,
        context: PrivatePaykitPaymentContext,
        attemptId: UUID
    ) throws {
        guard let publicKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw PrivatePaykitError.invalidPublicKey
        }
        guard let paymentListVersion = context.paymentListVersion else { return }

        var contactState = state.contacts[publicKey, default: ContactState()]
        let consumedVersion = contactState.consumedPrivatePaymentListVersion
        if let consumedVersion,
           paymentListVersion <= consumedVersion
        {
            throw PrivatePaykitError.paymentListAlreadyConsumed
        }

        let previousContactState = state.contacts[publicKey]
        contactState.consumedPrivatePaymentListVersion = paymentListVersion
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
            publicKey: publicKey
        )
        privatePaymentListConsumptions[consumptionKey] = PrivatePaymentListConsumption(
            paymentListVersion: paymentListVersion,
            previousPaymentListVersion: consumedVersion
        )
        Logger.info(
            "Consumed private Paykit payment list version \(paymentListVersion) for \(PubkyPublicKeyFormat.redacted(publicKey))",
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
        guard let paymentListVersion = context.paymentListVersion else { return }

        let consumptionKey = PrivatePaymentListConsumptionKey(
            attemptId: attemptId,
            publicKey: publicKey
        )
        guard let consumption = privatePaymentListConsumptions[consumptionKey],
              consumption.paymentListVersion == paymentListVersion
        else { return }

        guard outcome == .definitePreBroadcastFailure else {
            privatePaymentListConsumptions[consumptionKey] = nil
            return
        }

        var contactState = state.contacts[publicKey, default: ContactState()]
        guard contactState.consumedPrivatePaymentListVersion == paymentListVersion else {
            privatePaymentListConsumptions[consumptionKey] = nil
            return
        }

        let previousContactState = state.contacts[publicKey]
        contactState.consumedPrivatePaymentListVersion = consumption.previousPaymentListVersion
        state.contacts[publicKey] = contactState
        do {
            try persistStateOrThrow(markWalletBackup: true)
            privatePaymentListConsumptions[consumptionKey] = nil
        } catch {
            state.contacts[publicKey] = previousContactState
            throw error
        }
        Logger.info(
            "Released private Paykit payment list version \(paymentListVersion) for \(PubkyPublicKeyFormat.redacted(publicKey))",
            context: "PrivatePaykit"
        )
    }

    private func currentLinkState(
        publicKey: String,
        preparedState: LinkedPeerState? = nil
    ) async throws -> LinkedPeerState? {
        if let preparedState {
            return preparedState
        }

        return try await PaykitSdkService.shared.linkedPeers().first {
            PubkyPublicKeyFormat.matches($0.counterparty, publicKey)
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

    /// Resolves the payee's current private endpoint for an automatic Allowance payment. Only endpoints the Allowance and
    /// the request both accept qualify, and only ones this wallet can pay without asking: a bolt11 invoice for exactly
    /// the requested amount (or amount-less), or an unused on-chain address. Public endpoints are never used.
    func resolveAllowancePayment(
        _ request: PaykitPaymentRequest,
        eligibleIdentifiers: [String]
    ) async throws -> PrivatePaykitAllowancePayment? {
        guard !request.isExpired(at: Date()),
              let publicKey = PubkyPublicKeyFormat.normalized(request.counterparty)
        else { return nil }

        let consumedVersion = state.contacts[publicKey]?
            .consumedPrivatePaymentListVersionsByReceiverPath[request.counterpartyReceiverPath]
        let prepared = try await PaykitSdkService.shared.prepareAndResolvePrivateContactPayment(
            counterparty: publicKey,
            receiverPath: request.counterpartyReceiverPath,
            amount: PaymentAmountContext(value: request.amountValue, asset: PaykitIssuerInterop.bitcoinAsset),
            afterPrivatePaymentListVersion: consumedVersion
        )
        guard let paymentListVersion = prepared.resolution.privatePaymentListVersion else { return nil }

        let eligible = Set(eligibleIdentifiers).intersection(request.acceptedPaymentEndpointIdentifiers)
        let candidates = resolvedEndpoints(from: prepared.resolution).filter {
            eligible.contains($0.methodId.rawValue) &&
                ($0.methodId == .bitcoinLightningBolt11 || $0.methodId.onchainNetwork != nil)
        }
        let payable = await privatePayableEndpoints(from: candidates, publicKey: publicKey)

        for methodId in PublicPaykitService.MethodId.payablePreferenceOrder {
            guard let endpoint = payable.first(where: { $0.methodId == methodId }) else { continue }
            if methodId == .bitcoinLightningBolt11 {
                guard case let .lightning(invoice) = try? await decode(invoice: endpoint.value),
                      invoice.amountSatoshis == 0 || invoice.amountSatoshis == request.amountSats
                else { continue }
                return PrivatePaykitAllowancePayment(
                    endpoint: endpoint,
                    context: PrivatePaykitPaymentContext(receiverPath: request.counterpartyReceiverPath, paymentListVersion: paymentListVersion),
                    lightningPaymentHash: invoice.paymentHash.hex,
                    lightningInvoiceHasAmount: invoice.amountSatoshis != 0
                )
            }
            return PrivatePaykitAllowancePayment(
                endpoint: endpoint,
                context: PrivatePaykitPaymentContext(receiverPath: request.counterpartyReceiverPath, paymentListVersion: paymentListVersion),
                lightningPaymentHash: nil,
                lightningInvoiceHasAmount: false
            )
        }
        return nil
    }

    private func resolvedEndpoints(from resolution: PrivateContactPaymentResolution) -> [PublicPaykitService.Endpoint] {
        resolution.payableEndpoints.compactMap {
            var endpoint = PublicPaykitService.parseEndpoint(identifier: $0.identifier, payload: $0.target.payload)
            endpoint?.appId = $0.appId
            return endpoint
        }
    }
}

private extension PrivatePaykitService {
    static var privatePaymentResolutionRetryDelays: ArraySlice<UInt64> {
        privateMessageDrainRetryDelays.prefix(3)
    }
}
