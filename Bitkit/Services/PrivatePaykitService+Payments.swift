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
    struct ContactPaymentOperations {
        var prepareContactPayment: (_ publicKey: String, _ afterVersion: UInt64?) async throws -> PreparedPrivateContactPayment = {
            try await PaykitSdkService.shared.prepareAndResolvePrivateContactPayment(counterparty: $0, afterPrivatePaymentListVersion: $1)
        }

        var preparePaymentRequest: (_ publicKey: String, _ paymentRequestId: String, _ afterVersion: UInt64?) async throws
            -> PreparedPrivateContactPayment = {
                try await PaykitSdkService.shared.prepareAndResolvePrivatePaymentRequest(
                    counterparty: $0,
                    paymentRequestId: $1,
                    afterPrivatePaymentListVersion: $2
                )
            }

        var identityStatus: () async throws -> IdentityStatus? = { try await PaykitSdkService.shared.identityStatus(priority: .interactive) }
        /// Read for a payment the user is waiting on, so it does not queue behind background SDK work.
        var linkedPeers: () async throws -> [LinkedPeerRecord] = { try await PaykitSdkService.shared.linkedPeers(priority: .interactive) }
        /// Succeeds when the contact publishes a verified Noise key authorization; a missing one throws `PaykitError.NotFound`.
        var noiseKeyAuthorization: (_ publicKey: String) async throws -> Void = {
            _ = try await PaykitSdkService.shared.paykitNoiseKeyAuthorization(publicKey: $0)
        }

        var isSavedContact: (_ publicKey: String) async throws -> Bool = { try await PaykitSdkService.shared.contactRecord(publicKey: $0) != nil }
        var beginPublicPayment: (_ publicKey: String) async throws -> PublicPaykitPaymentLaunchResult = {
            try await PublicPaykitService.beginPayment(to: $0)
        }
    }

    func contactPublicKey(forPrivateInvoicePaymentHash paymentHash: String) -> String? {
        guard !paymentHash.isEmpty, (try? profileAdmission.snapshot()) != nil else { return nil }
        return storedInvoiceContact(paymentHash: paymentHash)
    }

    func contactPublicKeyForReceipt(paymentHash: String) -> String? {
        guard !paymentHash.isEmpty, (try? profileAdmission.checkReceiptAttribution()) != nil else { return nil }
        return storedInvoiceContact(paymentHash: paymentHash)
    }

    private func storedInvoiceContact(paymentHash: String) -> String? {
        return state.contacts.first { _, contactState in
            contactState.localInvoice?.paymentHash == paymentHash ||
                contactState.receivedInvoicePaymentHashes.contains(paymentHash)
        }?.key
    }

    func beginSavedContactPayment(to publicKey: String, wallet: WalletViewModel) async throws -> PublicPaykitPaymentLaunchResult {
        return try await profileAdmission.withOperation {
            guard let savedContact = try await savedContact(publicKey) else {
                return try await contactPaymentOperations.beginPublicPayment(publicKey)
            }
            let normalizedKey = savedContact.publicKey

            try schedulePrePaymentPublication(for: normalizedKey) {
                _ = await self.refreshSavedContactEndpointsReturningError(
                    for: [normalizedKey],
                    wallet: wallet,
                    forceRefreshLightning: false,
                    requireImmediatePublication: false
                )
            }

            guard try await hasPrivatePaymentPath(normalizedKey, identity: savedContact.identity) else {
                return try await contactPaymentOperations.beginPublicPayment(normalizedKey)
            }

            var result = try await beginContactPayment(to: normalizedKey)
            for delay in Self.privatePaymentResolutionRetryDelays {
                guard case .waitingForUpdatedPaymentList = result else { return result }
                try await Task.sleep(nanoseconds: delay)
                result = try await beginContactPayment(to: normalizedKey)
            }
            return result
        }
    }

    /// Retain the original profile owner while publication waits, and let removal cancel that wait before draining it.
    @discardableResult
    func schedulePrePaymentPublication(for publicKey: String, operation: @escaping () async -> Void) throws -> Task<Void, Never>? {
        guard prePaymentPublicationKeys.insert(publicKey).inserted else { return nil }
        let admission = profileAdmission
        let scope: ProfileOperationAdmission.Scope
        do { scope = try admission.capture() }
        catch {
            prePaymentPublicationKeys.remove(publicKey)
            throw error
        }
        let id = UUID()
        let task = Task {
            defer {
                prePaymentPublicationKeys.remove(publicKey)
                admission.removeCancellationHandler(from: scope, id: id)
                admission.release(scope)
            }
            do { try await admission.withScope(scope, revokeOnCancellation: false) { await operation() } }
            catch { Logger.debug("Prepayment publication stopped: \(error)", context: "PrivatePaykit") }
        }
        admission.onRevocation(of: scope, id: id) { task.cancel() }
        return task
    }

    private func savedContact(_ publicKey: String) async throws -> (publicKey: String, identity: IdentityStatus)? {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return nil }
        let identity = try await contactPaymentOperations.identityStatus().flatMap { $0.publicKey == nil ? nil : $0 }
        if isKnownSavedContact(normalizedKey) {
            guard let identity else { throw PubkyServiceError.sessionNotActive }
            return (normalizedKey, identity)
        }
        guard let identity, try await contactPaymentOperations.isSavedContact(normalizedKey) else { return nil }
        try profileAdmission.checkCurrent()
        if !isDeletingProfile {
            _ = rememberSavedContacts([normalizedKey], replacing: false)
        }
        return (normalizedKey, identity)
    }

    /// A contact has a private payment path once this wallet keeps any private payment state for it, the SDK keeps a link
    /// record for it in any state, or it publishes a Noise key authorization. Only a contact without any of these, whose
    /// authorization is definitely missing, is paid through public endpoints; any other lookup failure throws. A payer whose
    /// identity can only pay publicly pays a contact publicly only without stored private state or a link record, and is
    /// refused otherwise. A signed-out identity still takes the private path, since the SDK resolves cached private payment
    /// details without a live session.
    func hasPrivatePaymentPath(_ publicKey: String, identity: IdentityStatus) async throws -> Bool {
        let hasStoredPrivateState = state.contacts[publicKey]?.hasCacheState == true
        if identity.capability == .publicOnly {
            guard !hasStoredPrivateState, try await !hasLinkRecord(publicKey) else { throw PubkyServiceError.sessionNotActive }
            return false
        }
        if hasStoredPrivateState {
            return true
        }
        if try await hasLinkRecord(publicKey) {
            return true
        }
        do {
            try await contactPaymentOperations.noiseKeyAuthorization(publicKey)
            return true
        } catch PaykitError.NotFound {
            return false
        }
    }

    private func hasLinkRecord(_ publicKey: String) async throws -> Bool {
        try await contactPaymentOperations.linkedPeers().contains { PubkyPublicKeyFormat.matches($0.counterparty, publicKey) }
    }

    func beginPaymentRequest(_ request: PaykitPaymentRequest) async throws -> PublicPaykitPaymentLaunchResult {
        return try await profileAdmission.withOperation {
            guard !request.isExpired(at: Date()) else {
                throw PaykitPaymentRequestError.requestExpired
            }
            guard let publicKey = PubkyPublicKeyFormat.normalized(request.counterparty) else {
                throw PrivatePaykitError.invalidPublicKey
            }

            if let proof = try await PaykitPaymentProofService.shared.retainedHardwarePaymentForRetry(request: request),
               let result = Self.retainedHardwarePaymentLaunchResult(proof: proof, request: request)
            {
                return result
            }

            return try await beginContactPayment(
                to: publicKey,
                paymentRequest: request
            )
        }
    }

    static func retainedHardwarePaymentLaunchResult(
        proof: PendingPaykitPaymentProof, request: PaykitPaymentRequest
    ) -> PublicPaykitPaymentLaunchResult? {
        guard proof.requestId == request.id, proof.retainedHardwareRetry != nil,
              request.matchesOnchainPayment(proof), proof.billingPeriod == request.billingPeriod,
              let address = proof.onchainAddress,
              request.acceptedPaymentEndpointIdentifiers.contains(proof.paymentEndpointIdentifier)
        else { return nil }
        // Reopen the original receipt, never resolve or consume a replacement merchant endpoint.
        return .opened(
            paymentRequest: "bitcoin:" + address,
            privatePaymentContext: PrivatePaykitPaymentContext(
                paymentAppsByEndpoint: [proof.paymentEndpointIdentifier: proof.paymentAppId],
                paymentListVersion: proof.privatePaymentListVersion
            )
        )
    }

    func beginPaymentRequestWaitingForUpdatedList(_ request: PaykitPaymentRequest) async throws -> PublicPaykitPaymentLaunchResult {
        return try await profileAdmission.withOperation {
            var result = try await beginPaymentRequest(request)
            for delay in Self.privatePaymentResolutionRetryDelays {
                guard case .waitingForUpdatedPaymentList = result else { return result }
                try await Task.sleep(nanoseconds: delay)
                result = try await beginPaymentRequest(request)
            }
            return result
        }
    }

    private func beginContactPayment(
        to publicKey: String,
        paymentRequest: PaykitPaymentRequest? = nil
    ) async throws -> PublicPaykitPaymentLaunchResult {
        return try await profileAdmission.withOperation {
            let consumedVersion = state.contacts[publicKey]?.consumedPrivatePaymentListVersion
            let previousPaymentListVersion = consumedVersion.map(String.init) ?? "none"
            do {
                let prepared: PreparedPrivateContactPayment = if let paymentRequest {
                    try await contactPaymentOperations.preparePaymentRequest(publicKey, paymentRequest.paymentRequestId, consumedVersion)
                } else {
                    try await contactPaymentOperations.prepareContactPayment(publicKey, consumedVersion)
                }
                let resolution = prepared.resolution
                let linkState = try await currentLinkState(
                    publicKey: publicKey,
                    preparedState: prepared.linkReport?.state
                )

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
                    validateEndpoints: { endpoints, allowUsedOnchainAddress in
                        await self.privatePayableEndpoints(
                            from: endpoints,
                            publicKey: publicKey,
                            allowUsedOnchainAddress: allowUsedOnchainAddress
                        )
                    }
                )
                if case .opened = result {
                    return result
                }

                if resolution.status == .waitingForUpdatedPaymentList {
                    Logger.info(
                        "Waiting for a private Paykit payment list newer than \(previousPaymentListVersion) for \(PubkyPublicKeyFormat.redacted(publicKey)); public resolution is disabled for this request",
                        context: "PrivatePaykit"
                    )
                    schedulePrivatePaymentRecovery(for: publicKey)
                    return .waitingForUpdatedPaymentList
                }

                if paymentRequest == nil,
                   Self.savedContactPaymentNeedsPrivateLinkRecovery(resolutionState: resolution.state, linkState: linkState)
                {
                    schedulePrivatePaymentRecovery(for: publicKey)
                    return .privateLinkPending
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

                if PaykitResolutionFailureDiagnostics.isRecoveryRequired(error) {
                    schedulePrivatePaymentRecovery(for: publicKey)
                    return .privateLinkPending
                }

                let linkState: LinkedPeerState?
                do {
                    linkState = try await currentLinkState(publicKey: publicKey)
                } catch {
                    if PaykitResolutionFailureDiagnostics.isRecoveryRequired(error) {
                        schedulePrivatePaymentRecovery(for: publicKey)
                        return .privateLinkPending
                    }
                    throw error
                }
                let needsLinkRecovery = paymentRequest == nil
                    ? Self.savedContactPaymentNeedsPrivateLinkRecovery(linkState: linkState)
                    : Self.paymentRequestNeedsPrivateLinkRecovery(linkState: linkState)
                guard needsLinkRecovery else {
                    throw error
                }
                schedulePrivatePaymentRecovery(for: publicKey)
                return .privateLinkPending
            }
        }
    }

    func privatePaymentResult(
        publicKey: String,
        paymentRequest: PaykitPaymentRequest?,
        resolution: PrivateContactPaymentResolution,
        validateEndpoints: ([PublicPaykitService.Endpoint], Bool) async -> [PublicPaykitService.Endpoint]
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
        // Request-bound endpoints have no list version; recurring terms may reuse their fixed address.
        let allowUsedOnchainAddress = paymentRequest?.billingPeriod != nil && paymentListVersion == nil
        let payableEndpoints = await validateEndpoints(acceptedEndpoints, allowUsedOnchainAddress)
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
            ),
            endpoints: payableEndpoints
        )
    }

    /// `expectedPreviousVersion`, when given, makes the consumption fail unless the list consumed so far is still that version.
    func consumePrivatePaymentList(
        publicKey: String,
        context: PrivatePaykitPaymentContext,
        attemptId: UUID,
        owner: String? = nil,
        expectedPreviousVersion: UInt64?? = nil
    ) throws {
        return try profileAdmission.withSynchronousOperation {
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

            if let expectedPreviousVersion, expectedPreviousVersion != consumedVersion {
                throw PrivatePaykitError.paymentListAlreadyConsumed
            }

            let previousContactState = state.contacts[publicKey]
            contactState.consumedPrivatePaymentListVersion = paymentListVersion
            contactState.consumedPrivatePaymentListOwner = owner
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
    }

    func resolvePrivatePaymentListConsumption(
        publicKey: String,
        context: PrivatePaykitPaymentContext,
        attemptId: UUID,
        outcome: PrivatePaymentListSendOutcome
    ) throws {
        return try profileAdmission.withSynchronousOperation {
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
            contactState.consumedPrivatePaymentListOwner = nil
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
    }

    /// Rolls back a list version a failed automatic payment consumed, which a restart may have left without its
    /// in-memory consumption record. A list another payment consumed, or one this attempt never consumed, is left alone.
    func releaseConsumedPaymentList(publicKey: String, version: UInt64, previousVersion: UInt64?, owner: String) throws {
        return try profileAdmission.withSynchronousOperation {
            guard let publicKey = PubkyPublicKeyFormat.normalized(publicKey) else {
                throw PrivatePaykitError.invalidPublicKey
            }
            guard var contactState = state.contacts[publicKey],
                  contactState.consumedPrivatePaymentListVersion == version,
                  contactState.consumedPrivatePaymentListOwner == owner
            else { return }
            let previousContactState = state.contacts[publicKey]
            contactState.consumedPrivatePaymentListVersion = previousVersion
            contactState.consumedPrivatePaymentListOwner = nil
            state.contacts[publicKey] = contactState
            do {
                try persistStateOrThrow(markWalletBackup: true)
            } catch {
                state.contacts[publicKey] = previousContactState
                throw error
            }
            Logger.info(
                "Released private Paykit payment list version \(version) for \(PubkyPublicKeyFormat.redacted(publicKey)) after a failed automatic payment",
                context: "PrivatePaykit"
            )
        }
    }

    func consumedPaymentListVersion(publicKey: String, attemptId: UUID? = nil) -> UInt64? {
        guard let key = PubkyPublicKeyFormat.normalized(publicKey) else { return nil }
        if let attemptId, let consumption = privatePaymentListConsumptions[PrivatePaymentListConsumptionKey(attemptId: attemptId, publicKey: key)] {
            return consumption.previousPaymentListVersion
        }
        return state.contacts[key]?.consumedPrivatePaymentListVersion
    }

    /// Preserve the version captured by a retained signed receipt before it can be retried.
    func retainOriginalPaymentListVersion(publicKey: String, version: UInt64) throws {
        return try profileAdmission.withSynchronousOperation {
            guard let key = PubkyPublicKeyFormat.normalized(publicKey) else { throw PrivatePaykitError.invalidPublicKey }
            var contact = state.contacts[key, default: ContactState()]
            if let consumed = contact.consumedPrivatePaymentListVersion, consumed >= version {
                return
            }
            let previous = state.contacts[key]
            contact.consumedPrivatePaymentListVersion = version
            contact.consumedPrivatePaymentListOwner = nil
            contact.cachedResolvedEndpoints.removeAll()
            state.contacts[key] = contact
            do {
                try persistStateOrThrow(markWalletBackup: true)
            } catch {
                state.contacts[key] = previous
                throw error
            }
        }
    }

    /// The caller must establish an exact receipt that definitely never reached native dispatch.
    func releaseUnsentPaymentListVersion(publicKey: String, version: UInt64, previousVersion: UInt64? = nil) throws {
        return try profileAdmission.withSynchronousOperation {
            guard let key = PubkyPublicKeyFormat.normalized(publicKey) else { throw PrivatePaykitError.invalidPublicKey }
            // A list an automatic payment attempt consumed is that attempt's to give back.
            guard var contact = state.contacts[key], contact.consumedPrivatePaymentListVersion == version,
                  contact.consumedPrivatePaymentListOwner == nil
            else { return }
            let previous = contact
            guard previousVersion.map({ $0 < version }) ?? true else { throw PaykitPaymentRequestError.requestUnavailable }
            contact.consumedPrivatePaymentListVersion = previousVersion
            state.contacts[key] = contact
            do {
                try persistStateOrThrow(markWalletBackup: true)
            } catch {
                state.contacts[key] = previous
                throw error
            }
        }
    }

    private func currentLinkState(
        publicKey: String,
        preparedState: LinkedPeerState? = nil
    ) async throws -> LinkedPeerState? {
        if let preparedState {
            return preparedState
        }

        return try await contactPaymentOperations.linkedPeers().first {
            PubkyPublicKeyFormat.matches($0.counterparty, publicKey)
        }?.state
    }

    /// A saved contact with a private payment path is never paid through public endpoints, so a private link that is not
    /// established yet, or that needs recovery, waits for that link instead.
    static func savedContactPaymentNeedsPrivateLinkRecovery(
        resolutionState: PrivatePaymentResolutionState? = nil,
        linkState: LinkedPeerState?
    ) -> Bool {
        switch linkState {
        case nil, .notLinked:
            true
        case .linking, .linked, .recoveryRequired, .blocked, .unknown:
            paymentRequestNeedsPrivateLinkRecovery(resolutionState: resolutionState, linkState: linkState)
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

    func privatePayableEndpoints(
        from endpoints: [PublicPaykitService.Endpoint],
        publicKey: String,
        allowUsedOnchainAddress: Bool = false,
        isAddressUsed: (String) async throws -> Bool = { try await CoreService.shared.utility.isAddressUsed(address: $0) }
    ) async -> [PublicPaykitService.Endpoint] {
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

            guard PublicPaykitService.MethodId.onchainPreferenceOrder.contains(endpoint.methodId), !allowUsedOnchainAddress else {
                reusableEndpoints.append(endpoint)
                continue
            }

            do {
                let isUsed = try await isAddressUsed(endpoint.value)
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
        return try await profileAdmission.withOperation {
            guard !request.isExpired(at: Date()),
                  let publicKey = PubkyPublicKeyFormat.normalized(request.counterparty)
            else { return nil }

            let consumedVersion = state.contacts[publicKey]?.consumedPrivatePaymentListVersion
            // Resolve through the request, as the manual flow does, so its required app and bound destination apply.
            let prepared = try await PaykitSdkService.shared.prepareAndResolvePrivatePaymentRequest(
                counterparty: publicKey,
                paymentRequestId: request.paymentRequestId,
                afterPrivatePaymentListVersion: consumedVersion
            )
            if prepared.resolution.state == .recoveryPending || prepared.resolution.status == .waitingForUpdatedPaymentList {
                // The last list was already paid from; a new one arrives once the payee sees that payment settle.
                schedulePrivatePaymentRecovery(for: publicKey)
                throw PaykitAllowanceError.paymentListPending
            }
            // Without a payment list version nothing limits how often the payee's endpoints can be paid, so the request asks.
            guard let paymentListVersion = prepared.resolution.privatePaymentListVersion else { return nil }

            let eligible = Set(eligibleIdentifiers).intersection(request.acceptedPaymentEndpointIdentifiers)
            let candidates = resolvedEndpoints(from: prepared.resolution).filter {
                eligible.contains($0.methodId.rawValue) &&
                    ($0.methodId == .bitcoinLightningBolt11 || $0.methodId.onchainNetwork != nil) && $0.appId != nil
            }
            let payable = await privatePayableEndpoints(from: candidates, publicKey: publicKey)

            for methodId in PublicPaykitService.MethodId.payablePreferenceOrder {
                guard let endpoint = payable.first(where: { $0.methodId == methodId }), let appId = endpoint.appId else { continue }
                let context = PrivatePaykitPaymentContext(
                    paymentAppsByEndpoint: [methodId.rawValue: appId],
                    paymentListVersion: paymentListVersion
                )
                if methodId == .bitcoinLightningBolt11 {
                    guard case let .lightning(invoice) = try? await decode(invoice: endpoint.value),
                          invoice.amountSatoshis == 0 || invoice.amountSatoshis == request.allowanceAmountSats
                    else { continue }
                    return PrivatePaykitAllowancePayment(
                        endpoint: endpoint,
                        context: context,
                        lightningPaymentHash: invoice.paymentHash.hex,
                        lightningInvoiceHasAmount: invoice.amountSatoshis != 0
                    )
                }
                return PrivatePaykitAllowancePayment(
                    endpoint: endpoint,
                    context: context,
                    lightningPaymentHash: nil,
                    lightningInvoiceHasAmount: false
                )
            }
            return nil
        }
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
