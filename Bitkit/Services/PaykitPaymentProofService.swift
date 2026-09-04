import Combine
import CryptoKit
import Foundation
import LDKNode
import Paykit

enum PaykitPaymentProofKind: String, Codable {
    case lightning = "bitcoin-bolt11-preimage"
    case onchain = "bitcoin-onchain-txid"

    init?(paymentEndpointIdentifier: String) {
        guard let method = PublicPaykitService.MethodId(rawValue: paymentEndpointIdentifier) else { return nil }
        self = method.onchainNetwork == nil ? .lightning : .onchain
    }
}

struct PaykitOnchainPaymentResolution: Equatable {
    let identity: String
    let requestId: PaykitPaymentRequest.ID
    let transactionId: String
}

struct PendingPaykitPaymentProof: Codable, Equatable {
    let identity: String
    let requestId: PaykitPaymentRequest.ID
    let paymentEndpointIdentifier: String
    let kind: PaykitPaymentProofKind
    let billingPeriod: PaykitBillingPeriod?
    var paymentStarted: Bool
    var paymentIdentifier: String?
    var proofData: String?
    var onchainAddress: String?
    var onchainAmountSats: UInt64?
    var onchainMatchingTransactionIdsBeforeAttempt: Set<String>?

    init(
        identity: String,
        requestId: PaykitPaymentRequest.ID,
        paymentEndpointIdentifier: String,
        kind: PaykitPaymentProofKind,
        billingPeriod: PaykitBillingPeriod? = nil,
        paymentStarted: Bool = false,
        paymentIdentifier: String?,
        proofData: String?,
        onchainAddress: String? = nil,
        onchainAmountSats: UInt64? = nil,
        onchainMatchingTransactionIdsBeforeAttempt: Set<String>? = nil
    ) {
        self.identity = identity
        self.requestId = requestId
        self.paymentEndpointIdentifier = paymentEndpointIdentifier
        self.kind = kind
        self.billingPeriod = billingPeriod
        self.paymentStarted = paymentStarted
        self.paymentIdentifier = paymentIdentifier
        self.proofData = proofData
        self.onchainAddress = onchainAddress
        self.onchainAmountSats = onchainAmountSats
        self.onchainMatchingTransactionIdsBeforeAttempt = onchainMatchingTransactionIdsBeforeAttempt
    }
}

protocol PaykitPaymentProofStoring: Sendable {
    func load() async throws -> [PendingPaykitPaymentProof]
    func save(_ proofs: [PendingPaykitPaymentProof]) async throws
}

struct PaykitPaymentProofStore: PaykitPaymentProofStoring {
    private struct State: Codable {
        var proofs: [PendingPaykitPaymentProof]
    }

    func load() async throws -> [PendingPaykitPaymentProof] {
        guard let data = try Keychain.load(key: .paykitPendingPaymentProofs) else { return [] }
        do {
            return try JSONDecoder().decode(State.self, from: data).proofs
        } catch {
            Logger.warn("Discarding invalid pending Paykit payment proof state: \(error)", context: "PaykitPaymentProof")
            try? Keychain.delete(key: .paykitPendingPaymentProofs)
            return []
        }
    }

    func save(_ proofs: [PendingPaykitPaymentProof]) async throws {
        guard !proofs.isEmpty else {
            try Keychain.delete(key: .paykitPendingPaymentProofs)
            return
        }
        try Keychain.upsert(
            key: .paykitPendingPaymentProofs,
            data: JSONEncoder().encode(State(proofs: proofs))
        )
    }
}

protocol PaykitPaymentProofSdkHandling: Sendable {
    func identityStatus() async throws -> Paykit.IdentityStatus?
    func paymentRequests() async throws -> [Paykit.PaymentRequestRecord]
    func processPendingPrivateMessages() async throws -> [Paykit.OutboundPrivateCounterpartySendReport]
    func submitPaymentProof(
        counterparty: String,
        counterpartyReceiverPath: String,
        paymentRequestId: String,
        proof: Paykit.PaymentProofSubmission
    ) async throws -> Paykit.PaymentRequestRecord
}

extension PaykitSdkService: PaykitPaymentProofSdkHandling {}

enum PaykitLightningPaymentProofStatus: Equatable {
    case pending
    case succeeded(preimage: String?)
    case failed
    case unknown
}

protocol PaykitLightningPaymentProofLookingUp: Sendable {
    func status(paymentHash: String) async -> PaykitLightningPaymentProofStatus
}

struct PaykitLightningPaymentProofLookup: PaykitLightningPaymentProofLookingUp {
    func status(paymentHash: String) async -> PaykitLightningPaymentProofStatus {
        guard let payment = await LightningService.shared.listPayments()?.first(where: {
            $0.id.caseInsensitiveCompare(paymentHash) == .orderedSame
        }), payment.direction == .outbound else {
            return .unknown
        }

        switch payment.status {
        case .pending:
            return .pending
        case .failed:
            return .failed
        case .succeeded:
            guard case let .bolt11(_, preimage, _, _, _) = payment.kind else { return .unknown }
            return .succeeded(preimage: preimage)
        }
    }
}

protocol PaykitOnchainPaymentProofLookingUp: Sendable {
    func existingTransactionIds(address: String, amountSats: UInt64) async throws -> Set<String>
    func transactionId(address: String, amountSats: UInt64, excluding transactionIds: Set<String>) async throws -> String?
}

struct PaykitOnchainPaymentProofLookup: PaykitOnchainPaymentProofLookingUp {
    func existingTransactionIds(address: String, amountSats: UInt64) async throws -> Set<String> {
        try await Set(matchingTransactionIds(address: address, amountSats: amountSats).map { $0.lowercased() })
    }

    func transactionId(address: String, amountSats: UInt64, excluding transactionIds: Set<String>) async throws -> String? {
        try await matchingTransactionIds(address: address, amountSats: amountSats)
            .reversed()
            .first { !transactionIds.contains($0.lowercased()) }
    }

    private func matchingTransactionIds(address: String, amountSats: UInt64) async throws -> [String] {
        guard let payments = await LightningService.shared.listPayments() else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        var transactionIds: [String] = []
        for payment in payments {
            guard payment.direction == .outbound,
                  payment.status != .failed,
                  case let .onchain(txid, _) = payment.kind,
                  let details = try? await CoreService.shared.activity.getTransactionDetails(txid: txid),
                  details.outputs.contains(where: {
                      $0.scriptpubkeyAddress == address && $0.value == amountSats
                  })
            else { continue }
            transactionIds.append(txid)
        }
        return transactionIds
    }
}

actor PaykitPaymentProofService {
    static let shared = PaykitPaymentProofService()

    private static let proofStateChangedSubject = PassthroughSubject<Void, Never>()
    private static let onchainPaymentResolutionSubject = CurrentValueSubject<PaykitOnchainPaymentResolution?, Never>(nil)

    nonisolated static var proofStateChangedPublisher: AnyPublisher<Void, Never> {
        proofStateChangedSubject.eraseToAnyPublisher()
    }

    nonisolated static var onchainPaymentResolutionPublisher: AnyPublisher<PaykitOnchainPaymentResolution, Never> {
        onchainPaymentResolutionSubject.compactMap { $0 }.eraseToAnyPublisher()
    }

    private let sdk: any PaykitPaymentProofSdkHandling
    private let store: any PaykitPaymentProofStoring
    private let lightningPaymentLookup: any PaykitLightningPaymentProofLookingUp
    private let onchainPaymentLookup: any PaykitOnchainPaymentProofLookingUp
    private let logInfo: @Sendable (String) -> Void
    private let logWarning: @Sendable (String) -> Void

    init(
        sdk: any PaykitPaymentProofSdkHandling = PaykitSdkService.shared,
        store: any PaykitPaymentProofStoring = PaykitPaymentProofStore(),
        lightningPaymentLookup: any PaykitLightningPaymentProofLookingUp = PaykitLightningPaymentProofLookup(),
        onchainPaymentLookup: any PaykitOnchainPaymentProofLookingUp = PaykitOnchainPaymentProofLookup(),
        logInfo: @escaping @Sendable (String) -> Void = {
            Logger.info($0, context: "PaykitPaymentProof")
        },
        logWarning: @escaping @Sendable (String) -> Void = {
            Logger.warn($0, context: "PaykitPaymentProof")
        }
    ) {
        self.sdk = sdk
        self.store = store
        self.lightningPaymentLookup = lightningPaymentLookup
        self.onchainPaymentLookup = onchainPaymentLookup
        self.logInfo = logInfo
        self.logWarning = logWarning
    }

    func prepare(
        request: PaykitPaymentRequest,
        paymentEndpointIdentifier: String,
        kind: PaykitPaymentProofKind
    ) async throws {
        let proof = try await pendingProof(
            request: request,
            paymentEndpointIdentifier: paymentEndpointIdentifier,
            kind: kind
        )

        var pendingProofs = try await loadProofs()
        guard !pendingProofs.contains(where: {
            PubkyPublicKeyFormat.matches($0.identity, proof.identity) &&
                $0.requestId == request.id &&
                ($0.paymentStarted || $0.paymentIdentifier != nil || $0.proofData != nil)
        }) else {
            throw PaykitPaymentRequestError.operationInProgress
        }
        pendingProofs.removeAll {
            PubkyPublicKeyFormat.matches($0.identity, proof.identity) &&
                $0.requestId == request.id &&
                !$0.paymentStarted &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }
        pendingProofs.append(proof)
        try await persist(pendingProofs)
    }

    private func pendingProof(
        request: PaykitPaymentRequest,
        paymentEndpointIdentifier: String,
        kind: PaykitPaymentProofKind
    ) async throws -> PendingPaykitPaymentProof {
        guard request.acceptedPaymentEndpointIdentifiers.contains(paymentEndpointIdentifier),
              Self.endpoint(paymentEndpointIdentifier, supports: kind),
              let identityStatus = try await sdk.identityStatus(),
              identityStatus.liveSessionAvailable,
              let publicKey = identityStatus.publicKey,
              let identity = PubkyPublicKeyFormat.normalized(publicKey)
        else {
            throw PaykitPaymentRequestError.requestUnavailable
        }

        return PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: paymentEndpointIdentifier,
            kind: kind,
            billingPeriod: request.billingPeriod,
            paymentIdentifier: nil,
            proofData: nil
        )
    }

    func associateLightningPayment(_ request: PaykitPaymentRequest, paymentHash: String) async throws {
        guard Self.isHex(paymentHash, byteCount: 32) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }

        let identity = try await currentIdentity()
        var pendingProofs = try await loadProofs()
        guard let index = pendingProofs.lastIndex(where: {
            PubkyPublicKeyFormat.matches($0.identity, identity) &&
                $0.requestId == request.id &&
                $0.kind == .lightning &&
                !$0.paymentStarted &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        pendingProofs[index].paymentStarted = true
        pendingProofs[index].paymentIdentifier = paymentHash.lowercased()
        try await persist(pendingProofs)
        Self.proofStateChangedSubject.send()
    }

    func markOnchainPaymentStarted(_ request: PaykitPaymentRequest, address: String) async throws {
        let identity = try await currentIdentity()
        let existingTransactionIds = try await onchainPaymentLookup.existingTransactionIds(
            address: address,
            amountSats: request.amountSats
        )
        var pendingProofs = try await loadProofs()
        guard let index = pendingProofs.lastIndex(where: {
            PubkyPublicKeyFormat.matches($0.identity, identity) &&
                $0.requestId == request.id &&
                $0.kind == .onchain &&
                !$0.paymentStarted &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        pendingProofs[index].paymentStarted = true
        pendingProofs[index].onchainAddress = address
        pendingProofs[index].onchainAmountSats = request.amountSats
        pendingProofs[index].onchainMatchingTransactionIdsBeforeAttempt = existingTransactionIds
        try await persist(pendingProofs)
        Self.proofStateChangedSubject.send()
    }

    func completeLightningPayment(paymentHash: String, preimage: String?) async {
        guard let preimage,
              Self.preimage(preimage, matchesPaymentHash: paymentHash)
        else {
            if preimage != nil {
                logWarning("Ignored a Paykit Lightning proof whose preimage did not match its payment hash")
            }
            return
        }

        do {
            var pendingProofs = try await loadProofs()
            let indexes = pendingProofs.indices.filter {
                pendingProofs[$0].kind == .lightning &&
                    pendingProofs[$0].paymentIdentifier?.caseInsensitiveCompare(paymentHash) == .orderedSame
            }
            guard !indexes.isEmpty else { return }
            for index in indexes {
                pendingProofs[index].proofData = preimage.lowercased()
            }
            let completedProofs = indexes.map { pendingProofs[$0] }
            await persistAndSubmit(completedProofs, allProofs: pendingProofs)
        } catch {
            logWarning("Failed to complete a Paykit Lightning payment proof: \(error)")
        }
    }

    func completeOnchainPayment(
        _ request: PaykitPaymentRequest,
        txid: String,
        paymentEndpointIdentifier: String
    ) async {
        guard let identity = try? await currentIdentity() else { return }
        let fallbackProof = try? await pendingProof(
            request: request,
            paymentEndpointIdentifier: paymentEndpointIdentifier,
            kind: .onchain
        )
        await completeOnchainPayment(
            requestId: request.id,
            identity: identity,
            txid: txid,
            fallbackProof: fallbackProof
        )
    }

    private func completeOnchainPayment(
        requestId: PaykitPaymentRequest.ID,
        identity: String,
        txid: String,
        fallbackProof: PendingPaykitPaymentProof? = nil
    ) async {
        guard Self.isHex(txid, byteCount: 32) else {
            logWarning("Ignored a Paykit on-chain proof with an invalid transaction id")
            return
        }

        do {
            var pendingProofs = try await loadProofs()
            guard let index = pendingProofs.lastIndex(where: {
                PubkyPublicKeyFormat.matches($0.identity, identity) &&
                    $0.requestId == requestId &&
                    $0.kind == .onchain &&
                    $0.paymentStarted &&
                    $0.paymentIdentifier == nil &&
                    $0.proofData == nil
            }) else { return }
            pendingProofs[index].paymentIdentifier = txid.lowercased()
            pendingProofs[index].proofData = txid.lowercased()
            let completedProof = pendingProofs[index]
            let didPersist: Bool
            do {
                try await persist(pendingProofs)
                didPersist = true
            } catch {
                didPersist = false
                logWarning("Failed to persist a completed Paykit payment proof; attempting immediate delivery: \(error)")
            }
            if didPersist {
                submitInBackground(completedProof)
            } else {
                persistAndSubmitInBackground(completedProof, allProofs: pendingProofs)
            }
            Self.onchainPaymentResolutionSubject.send(PaykitOnchainPaymentResolution(
                identity: completedProof.identity,
                requestId: requestId,
                transactionId: txid.lowercased()
            ))
        } catch {
            logWarning("Failed to load a Paykit on-chain payment proof; attempting immediate delivery: \(error)")
            guard var fallbackProof else { return }
            fallbackProof.paymentStarted = true
            fallbackProof.paymentIdentifier = txid.lowercased()
            fallbackProof.proofData = txid.lowercased()
            submitInBackground(fallbackProof)
            Self.onchainPaymentResolutionSubject.send(PaykitOnchainPaymentResolution(
                identity: fallbackProof.identity,
                requestId: requestId,
                transactionId: txid.lowercased()
            ))
        }
    }

    func failLightningPayment(paymentHash: String) async {
        await removeProofs {
            $0.kind == .lightning && $0.paymentIdentifier?.caseInsensitiveCompare(paymentHash) == .orderedSame
        }
    }

    func failOnchainPayment(_ request: PaykitPaymentRequest) async {
        await removeRequestProofs(request) {
            $0.kind == .onchain &&
                $0.paymentStarted &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }
    }

    func cancelPreparation(_ request: PaykitPaymentRequest) async {
        await removeRequestProofs(request) {
            !$0.paymentStarted &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }
    }

    func reconcile() async {
        do {
            let pendingProofs = try await loadProofs()
            guard !pendingProofs.isEmpty else { return }
            guard let identityStatus = try await sdk.identityStatus(),
                  identityStatus.liveSessionAvailable,
                  let publicKey = identityStatus.publicKey,
                  let identity = PubkyPublicKeyFormat.normalized(publicKey)
            else { return }

            let identityProofs = pendingProofs.filter {
                PubkyPublicKeyFormat.matches($0.identity, identity)
            }
            for proof in identityProofs {
                do {
                    if proof.proofData != nil {
                        await submit(proof)
                        continue
                    }
                    if proof.kind == .onchain,
                       proof.paymentStarted,
                       let address = proof.onchainAddress,
                       let amountSats = proof.onchainAmountSats,
                       let txid = try await onchainPaymentLookup.transactionId(
                           address: address,
                           amountSats: amountSats,
                           excluding: proof.onchainMatchingTransactionIdsBeforeAttempt ?? []
                       )
                    {
                        await completeOnchainPayment(requestId: proof.requestId, identity: proof.identity, txid: txid)
                        continue
                    }
                    guard proof.kind == PaykitPaymentProofKind.lightning, let paymentHash = proof.paymentIdentifier else { continue }
                    switch await lightningPaymentLookup.status(paymentHash: paymentHash) {
                    case .pending, .unknown:
                        continue
                    case .failed:
                        await failLightningPayment(paymentHash: paymentHash)
                    case let .succeeded(preimage):
                        await completeLightningPayment(paymentHash: paymentHash, preimage: preimage)
                    }
                } catch {
                    logWarning("Failed to reconcile a pending Paykit payment proof: \(error)")
                }
            }
        } catch {
            logWarning("Failed to reconcile pending Paykit payment proofs: \(error)")
        }
    }

    func completedRequestProofKindsAwaitingSubmission(identity: String) async -> [PaykitPaymentRequest.ID: PaykitPaymentProofKind] {
        do {
            return try await loadProofs().reduce(into: [:]) { result, proof in
                guard PubkyPublicKeyFormat.matches(proof.identity, identity), proof.proofData != nil else { return }
                result[proof.requestId] = proof.kind
            }
        } catch {
            logWarning("Failed to inspect pending Paykit payment proofs: \(error)")
            return [:]
        }
    }

    func inFlightRequestIds(identity: String) async -> Set<PaykitPaymentRequest.ID> {
        do {
            return try await Set(loadProofs().compactMap { proof in
                guard PubkyPublicKeyFormat.matches(proof.identity, identity), proof.paymentStarted else { return nil }
                return proof.requestId
            })
        } catch {
            logWarning("Failed to inspect in-flight Paykit payment proofs: \(error)")
            return []
        }
    }

    func protectedRequestIdsForSubscriptionCancellation(
        identity: String,
        subscriptionId: PaykitSubscription.ID
    ) async throws -> Set<PaykitPaymentRequest.ID> {
        let proofs = try await loadProofs()
        let belongsToSubscription: (PendingPaykitPaymentProof) -> Bool = {
            PubkyPublicKeyFormat.matches($0.identity, identity) &&
                $0.requestId.billingPeriodStartsAt != nil &&
                $0.requestId.paymentRequestId == subscriptionId.paymentRequestId &&
                $0.requestId.counterparty == subscriptionId.counterparty &&
                $0.requestId.counterpartyReceiverPath == subscriptionId.counterpartyReceiverPath
        }
        let protectedRequestIds: Set<PaykitPaymentRequest.ID> = Set(proofs.compactMap { proof in
            guard belongsToSubscription(proof) else { return nil }
            guard proof.paymentStarted || proof.paymentIdentifier != nil || proof.proofData != nil else { return nil }
            return proof.requestId
        })
        let remainingProofs = proofs.filter {
            !belongsToSubscription($0) || $0.paymentStarted || $0.paymentIdentifier != nil || $0.proofData != nil
        }
        if remainingProofs != proofs {
            try await persist(remainingProofs)
            Self.proofStateChangedSubject.send()
        }
        return protectedRequestIds
    }

    func consumeOnchainPaymentResolution(_ resolution: PaykitOnchainPaymentResolution) {
        guard Self.onchainPaymentResolutionSubject.value == resolution else { return }
        Self.onchainPaymentResolutionSubject.send(nil)
    }

    private func currentIdentity() async throws -> String {
        guard let identityStatus = try await sdk.identityStatus(),
              let publicKey = identityStatus.publicKey,
              let identity = PubkyPublicKeyFormat.normalized(publicKey)
        else { throw PaykitPaymentRequestError.requestUnavailable }
        return identity
    }

    @discardableResult
    private func submit(_ pendingProof: PendingPaykitPaymentProof) async -> Bool {
        guard let proofData = pendingProof.proofData else { return false }
        do {
            guard let identityStatus = try await sdk.identityStatus(),
                  identityStatus.liveSessionAvailable,
                  PubkyPublicKeyFormat.matches(identityStatus.publicKey, pendingProof.identity)
            else { return false }

            let records = try await sdk.paymentRequests()
            guard let request = records.first(where: {
                $0.paymentRequestId == pendingProof.requestId.paymentRequestId &&
                    PubkyPublicKeyFormat.matches($0.counterparty, pendingProof.requestId.counterparty) &&
                    $0.counterpartyReceiverPath == pendingProof.requestId.counterpartyReceiverPath
            }) else { return false }

            let proofText = try Self.proofText(kind: pendingProof.kind, data: proofData)
            let isAlreadyQueued = request.paymentProofs.contains(where: {
                Self.billingPeriod($0.billingPeriod, matches: pendingProof.billingPeriod) &&
                    $0.paymentEndpointIdentifier == pendingProof.paymentEndpointIdentifier &&
                    Self.proofValues($0.proof.exportText()) == Self.proofValues(proofText)
            })

            if !isAlreadyQueued {
                _ = try await sdk.submitPaymentProof(
                    counterparty: pendingProof.requestId.counterparty,
                    counterpartyReceiverPath: pendingProof.requestId.counterpartyReceiverPath,
                    paymentRequestId: pendingProof.requestId.paymentRequestId,
                    proof: Paykit.PaymentProofSubmission(
                        billingPeriod: pendingProof.billingPeriod?.sdkValue,
                        paymentEndpointIdentifier: pendingProof.paymentEndpointIdentifier,
                        proof: Paykit.PrivateJsonObject(text: proofText)
                    )
                )
                logInfo("Queued a Paykit payment proof for private delivery")
                do {
                    _ = try await sdk.processPendingPrivateMessages()
                } catch {
                    logWarning("Paykit payment proof remains queued for private delivery: \(error)")
                }
            }
            await removeRequestProofs(pendingProof)
            return true
        } catch {
            logWarning("Failed to queue a Paykit payment proof: \(error)")
            return false
        }
    }

    private func loadProofs() async throws -> [PendingPaykitPaymentProof] {
        try await store.load()
    }

    private func persist(_ proofs: [PendingPaykitPaymentProof]) async throws {
        try await store.save(proofs)
    }

    private func persistAndSubmit(
        _ completedProofs: [PendingPaykitPaymentProof],
        allProofs: [PendingPaykitPaymentProof]
    ) async {
        let didPersist: Bool
        do {
            try await persist(allProofs)
            didPersist = true
        } catch {
            didPersist = false
            logWarning("Failed to persist a completed Paykit payment proof; attempting immediate delivery: \(error)")
        }
        var hasUndeliveredProof = false
        for proof in completedProofs {
            if await !submit(proof) {
                hasUndeliveredProof = true
            }
        }
        if !didPersist, hasUndeliveredProof {
            do {
                try await persist(allProofs)
            } catch {
                logWarning("Failed to retain a completed Paykit payment proof for retry: \(error)")
            }
        }
        if !completedProofs.isEmpty {
            Self.proofStateChangedSubject.send()
        }
    }

    private func submitInBackground(_ proof: PendingPaykitPaymentProof) {
        Task { [weak self] in
            await self?.submit(proof)
        }
    }

    private func persistAndSubmitInBackground(
        _ proof: PendingPaykitPaymentProof,
        allProofs: [PendingPaykitPaymentProof]
    ) {
        Task { [weak self] in
            await self?.persistAndSubmit([proof], allProofs: allProofs)
        }
    }

    private func removeRequestProofs(_ proof: PendingPaykitPaymentProof) async {
        await removeProofs {
            PubkyPublicKeyFormat.matches($0.identity, proof.identity) && $0.requestId == proof.requestId
        }
    }

    private func removeRequestProofs(
        _ request: PaykitPaymentRequest,
        where shouldRemove: (PendingPaykitPaymentProof) -> Bool
    ) async {
        do {
            let pendingProofs = try await loadProofs()
            let candidates = pendingProofs.filter { $0.requestId == request.id && shouldRemove($0) }
            let candidateIdentities = Set(candidates.compactMap { PubkyPublicKeyFormat.normalized($0.identity) })
            let identity = try? await currentIdentity()
            guard let targetIdentity = identity ?? (candidateIdentities.count == 1 ? candidateIdentities.first : nil) else { return }

            let remainingProofs = pendingProofs.filter {
                !($0.requestId == request.id &&
                    PubkyPublicKeyFormat.matches($0.identity, targetIdentity) &&
                    shouldRemove($0))
            }
            guard remainingProofs != pendingProofs else { return }
            try await persist(remainingProofs)
            Self.proofStateChangedSubject.send()
        } catch {
            logWarning("Failed to clear a pending Paykit payment proof: \(error)")
        }
    }

    private func removeProofs(where shouldRemove: (PendingPaykitPaymentProof) -> Bool) async {
        do {
            let pendingProofs = try await loadProofs()
            let remainingProofs = pendingProofs.filter { !shouldRemove($0) }
            guard remainingProofs != pendingProofs else { return }
            try await persist(remainingProofs)
            Self.proofStateChangedSubject.send()
        } catch {
            logWarning("Failed to clear a pending Paykit payment proof: \(error)")
        }
    }

    private static func endpoint(_ identifier: String, supports kind: PaykitPaymentProofKind) -> Bool {
        guard let methodId = PublicPaykitService.MethodId(rawValue: identifier) else { return false }
        switch kind {
        case .lightning:
            return methodId == .bitcoinLightningBolt11 || methodId == .bitcoinLightningLnurl
        case .onchain:
            return methodId.onchainNetwork != nil
        }
    }

    private static func preimage(_ preimage: String, matchesPaymentHash paymentHash: String) -> Bool {
        guard let bytes = data(hex: preimage), bytes.count == 32 else { return false }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            .caseInsensitiveCompare(paymentHash) == .orderedSame
    }

    private static func isHex(_ value: String, byteCount: Int) -> Bool {
        data(hex: value)?.count == byteCount
    }

    private static func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    private static func proofText(kind: PaykitPaymentProofKind, data: String) throws -> String {
        let encoded = try JSONSerialization.data(
            withJSONObject: ["data": data, "type": kind.rawValue],
            options: [.sortedKeys]
        )
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func proofValues(_ text: String) -> [String: String]? {
        guard let data = text.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return values
    }

    private static func billingPeriod(_ sdkPeriod: Paykit.BillingPeriod?, matches period: PaykitBillingPeriod?) -> Bool {
        switch (sdkPeriod.flatMap(PaykitBillingPeriod.init), period) {
        case (nil, nil):
            true
        case let (sdkPeriod?, period?):
            sdkPeriod == period
        default:
            false
        }
    }
}
