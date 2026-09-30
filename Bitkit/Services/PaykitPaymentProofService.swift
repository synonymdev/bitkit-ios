import BitkitCore
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
    var walletId: String = WalletScope.default
}

protocol PaykitHardwareTransactionLookingUp: Sendable {
    func hasWallet(walletId: String) -> Bool
    func transactionDetail(walletId: String, txid: String) async throws -> TransactionDetail
}

struct PaykitHardwareTransactionLookup: PaykitHardwareTransactionLookingUp {
    func hasWallet(walletId: String) -> Bool {
        (try? HwWalletManager.persistedFundingAccount(walletId: walletId)) != nil
    }

    func transactionDetail(walletId: String, txid: String) async throws -> TransactionDetail {
        let account = try HwWalletManager.persistedFundingAccount(walletId: walletId)
        let electrumUrl = OnChainHwService.getElectrumUrl()
        let network = OnChainHwService.appDefaultCoinType
        return try await OnChainHwService.shared.getTransactionDetail(
            extendedKey: account.xpub, electrumUrl: electrumUrl, txid: txid,
            network: network, scriptType: account.accountType
        )
    }
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
    var onchainWalletId: String?
    var onchainMatchingTransactionIdsBeforeAttempt: Set<String>?
    var onchainAcceptanceVerified: Bool?
    /// Device-local acknowledgement: backup restore reruns local activity proof.
    var onchainLocalFollowupComplete: Bool?

    var hasUnsupportedOnchainWallet: Bool {
        kind == .onchain && onchainWalletId != nil && onchainWalletId != WalletScope.default
    }

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
        onchainWalletId: String? = nil,
        onchainMatchingTransactionIdsBeforeAttempt: Set<String>? = nil,
        onchainAcceptanceVerified: Bool? = false,
        onchainLocalFollowupComplete: Bool? = false
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
        self.onchainWalletId = onchainWalletId
        self.onchainMatchingTransactionIdsBeforeAttempt = onchainMatchingTransactionIdsBeforeAttempt
        self.onchainAcceptanceVerified = onchainAcceptanceVerified
        self.onchainLocalFollowupComplete = onchainLocalFollowupComplete
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
        return try JSONDecoder().decode(State.self, from: data).proofs
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

private actor PaykitProofMutationLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        if isLocked {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isLocked = true
        }
        defer {
            if waiters.isEmpty {
                isLocked = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        return try await operation()
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
    private let hardwareTransactionLookup: any PaykitHardwareTransactionLookingUp
    private let hardwareFollowup: @Sendable (PendingPaykitPaymentProof, TransactionDetail?) async throws -> Void
    private let attemptService: OnchainSendAttemptService
    private let logInfo: @Sendable (String) -> Void
    private let logWarning: @Sendable (String) -> Void
    private let mutationLock = PaykitProofMutationLock()

    func backupSnapshot() async throws -> [PaykitPaymentStateBackup.Proof] {
        try await store.load().map(PaykitPaymentStateBackup.Proof.init)
    }

    func restoreBackup(_ proofs: [PaykitPaymentStateBackup.Proof]) async throws {
        let restoredProofs = try proofs.map { try $0.restored() }
        let unsupportedWalletProofCount = restoredProofs.filter {
            $0.hasUnsupportedOnchainWallet && $0.onchainWalletId.map { hardwareTransactionLookup.hasWallet(walletId: $0) } != true
        }.count
        if unsupportedWalletProofCount > 0 {
            logWarning("Retained \(unsupportedWalletProofCount) pending Paykit payment proof(s) for another wallet")
        }
        try await mutationLock.withLock { try await persist(restoredProofs) }
    }

    init(
        sdk: any PaykitPaymentProofSdkHandling = PaykitSdkService.shared,
        store: any PaykitPaymentProofStoring = PaykitPaymentProofStore(),
        lightningPaymentLookup: any PaykitLightningPaymentProofLookingUp = PaykitLightningPaymentProofLookup(),
        hardwareTransactionLookup: any PaykitHardwareTransactionLookingUp = PaykitHardwareTransactionLookup(),
        hardwareFollowup: @escaping @Sendable (PendingPaykitPaymentProof, TransactionDetail?) async throws -> Void = PaykitPaymentProofService
            .restoreHardwareActivity,
        attemptService: OnchainSendAttemptService = .shared,
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
        self.hardwareTransactionLookup = hardwareTransactionLookup
        self.hardwareFollowup = hardwareFollowup
        self.attemptService = attemptService
        self.logInfo = logInfo
        self.logWarning = logWarning
    }

    func prepare(
        request: PaykitPaymentRequest,
        paymentEndpointIdentifier: String,
        kind: PaykitPaymentProofKind
    ) async throws {
        if try await attemptService.hasAttempt(for: request.id) {
            if kind == .onchain, try await attemptService.acceptedTransactionId(for: request.id) != nil {
                return
            }
            throw PaykitPaymentRequestError.operationInProgress
        }
        let proof = try await pendingProof(request: request, paymentEndpointIdentifier: paymentEndpointIdentifier, kind: kind)
        try await mutationLock.withLock { try await prepareLocked(request: request, proof: proof) }
    }

    private func prepareLocked(request: PaykitPaymentRequest, proof: PendingPaykitPaymentProof) async throws {
        if try await attemptService.hasAttempt(for: request.id) {
            if proof.kind == .onchain, try await attemptService.acceptedTransactionId(for: request.id) != nil {
                return
            }
            throw PaykitPaymentRequestError.operationInProgress
        }
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
                !$0.hasUnsupportedOnchainWallet &&
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

        let records = try await sdk.paymentRequests()
        if records.contains(where: { record in
            guard record.localRole == .payer,
                  record.paymentRequestId == request.paymentRequestId,
                  PubkyPublicKeyFormat.matches(record.counterparty, request.counterparty),
                  record.counterpartyReceiverPath == request.counterpartyReceiverPath
            else { return false }
            return (request.billingPeriod == nil && record.state == .proofSubmitted) || record.paymentProofs.contains {
                Self.billingPeriod($0.billingPeriod, matches: request.billingPeriod)
            }
        }) {
            throw PaykitPaymentRequestError.operationInProgress
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
        let identity = try await currentIdentity()
        try await mutationLock.withLock {
            try await associateLightningPaymentLocked(request, paymentHash: paymentHash, identity: identity)
        }
    }

    private func associateLightningPaymentLocked(_ request: PaykitPaymentRequest, paymentHash: String, identity: String) async throws {
        if try await attemptService.hasAttempt(for: request.id) {
            throw PaykitPaymentRequestError.operationInProgress
        }
        guard Self.isHex(paymentHash, byteCount: 32) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }

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
    }

    func markOnchainPaymentStarted(
        _ request: PaykitPaymentRequest,
        address: String,
        hardwareWalletId: String? = nil,
        paymentIdentity: String? = nil
    ) async throws {
        let identity = try await currentIdentity()
        try await mutationLock.withLock {
            try await markOnchainPaymentStartedLocked(
                request,
                address: address,
                hardwareWalletId: hardwareWalletId,
                paymentIdentity: paymentIdentity,
                identity: identity
            )
        }
    }

    private func markOnchainPaymentStartedLocked(
        _ request: PaykitPaymentRequest,
        address: String,
        hardwareWalletId: String?,
        paymentIdentity: String?,
        identity: String
    ) async throws {
        if let hardwareWalletId {
            guard hardwareWalletId != WalletScope.default, hardwareTransactionLookup.hasWallet(walletId: hardwareWalletId)
            else { throw PaykitPaymentRequestError.requestUnavailable }
        }
        if hardwareWalletId != nil {
            guard PubkyPublicKeyFormat.matches(identity, paymentIdentity) else { throw PaykitPaymentRequestError.requestUnavailable }
        }
        var pendingProofs = try await loadProofs()
        guard let index = pendingProofs.lastIndex(where: {
            PubkyPublicKeyFormat.matches($0.identity, identity) &&
                $0.requestId == request.id &&
                $0.kind == .onchain &&
                !$0.hasUnsupportedOnchainWallet &&
                !$0.paymentStarted &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        pendingProofs[index].paymentStarted = true
        pendingProofs[index].onchainAddress = address
        pendingProofs[index].onchainAmountSats = request.amountSats
        pendingProofs[index].onchainWalletId = hardwareWalletId
        try await persist(pendingProofs)
    }

    @discardableResult
    func completeHardwareOnchainPayment(_ request: PaykitPaymentRequest, paymentIdentity: String, walletId: String, txid: String) async -> Bool {
        guard let identity = PubkyPublicKeyFormat.normalized(paymentIdentity) else { return false }
        return await completeHardwareOnchainPayment(requestId: request.id, identity: identity, walletId: walletId, txid: txid)
    }

    private func completeHardwareOnchainPayment(
        requestId: PaykitPaymentRequest.ID,
        identity: String,
        walletId: String,
        txid: String,
        deliverInBackground: Bool = true
    ) async -> Bool {
        guard walletId != WalletScope.default, Self.isHex(txid, byteCount: 32) else { return false }
        do {
            let original: PendingPaykitPaymentProof? = try await mutationLock.withLock {
                var proofs = try await loadProofs()
                guard let index = proofs.lastIndex(where: {
                    PubkyPublicKeyFormat.matches($0.identity, identity) && $0.requestId == requestId &&
                        $0.kind == .onchain && $0.paymentStarted && $0.onchainWalletId == walletId &&
                        ($0.paymentIdentifier == nil || $0.paymentIdentifier?.caseInsensitiveCompare(txid) == .orderedSame) &&
                        ($0.proofData == nil || $0.proofData?.caseInsensitiveCompare(txid) == .orderedSame)
                }) else { return nil }
                if proofs[index].paymentIdentifier == nil {
                    proofs[index].paymentIdentifier = txid.lowercased()
                    try await persist(proofs)
                }
                return proofs[index]
            }
            guard let original else { return false }
            var detail: TransactionDetail?
            var completed = original
            if original.onchainAcceptanceVerified != true || original.proofData == nil {
                let observed = try await hardwareTransactionLookup.transactionDetail(walletId: walletId, txid: txid)
                guard observed.txid.caseInsensitiveCompare(txid) == .orderedSame, observed.sent > 0 else { return false }
                detail = observed
                let saved: PendingPaykitPaymentProof? = try await mutationLock.withLock {
                    var proofs = try await loadProofs()
                    guard let index = proofs.firstIndex(of: original) else { return nil }
                    proofs[index].proofData = txid.lowercased()
                    proofs[index].onchainAcceptanceVerified = true
                    try await persist(proofs)
                    return proofs[index]
                }
                guard let saved else { return false }
                completed = saved
            }
            if completed.onchainLocalFollowupComplete != true {
                try await hardwareFollowup(completed, detail)
                let followedUp: PendingPaykitPaymentProof? = try await mutationLock.withLock {
                    var proofs = try await loadProofs()
                    if let index = proofs.firstIndex(of: completed) {
                        proofs[index].onchainLocalFollowupComplete = true
                        try await persist(proofs)
                        return proofs[index]
                    }
                    // Another reconciliation may have acknowledged this exact original proof.
                    return proofs.first {
                        PubkyPublicKeyFormat.matches($0.identity, identity) && $0.requestId == requestId &&
                            $0.onchainWalletId == walletId && $0.kind == .onchain && $0.paymentStarted &&
                            $0.onchainAcceptanceVerified == true && $0.onchainLocalFollowupComplete == true &&
                            $0.paymentIdentifier?.caseInsensitiveCompare(txid) == .orderedSame &&
                            $0.proofData?.caseInsensitiveCompare(txid) == .orderedSame
                    }
                }
                guard let followedUp else { return false }
                completed = followedUp
            }
            if deliverInBackground {
                submitInBackground(completed)
            } else {
                _ = await submit(completed)
            }
            Self.onchainPaymentResolutionSubject.send(PaykitOnchainPaymentResolution(
                identity: completed.identity, requestId: requestId, transactionId: txid.lowercased(), walletId: walletId
            ))
            return true
        } catch {
            logWarning("Hardware Paykit payment remains pending exact transaction/local follow-up: \(error)")
            return false
        }
    }

    nonisolated static func restoreHardwareActivity(_ proof: PendingPaykitPaymentProof, detail: TransactionDetail?) async throws {
        guard proof.onchainAcceptanceVerified == true, let walletId = proof.onchainWalletId, walletId != WalletScope.default,
              let txid = proof.paymentIdentifier, proof.proofData?.caseInsensitiveCompare(txid) == .orderedSame,
              let address = proof.onchainAddress, let amount = proof.onchainAmountSats
        else { throw PaykitPaymentRequestError.requestUnavailable }
        let metadata = try await ServiceQueue.background(.core) {
            try BitkitCore.getPreActivityMetadata(walletId: walletId, searchKey: txid, searchByAddress: false)
        }
        let existing = try await CoreService.shared.activity.getOnchainActivityByTxId(txid: txid, walletId: walletId)
        var observed = detail
        if existing == nil, observed == nil {
            observed = try await PaykitHardwareTransactionLookup().transactionDetail(walletId: walletId, txid: txid)
            guard observed?.txid.caseInsensitiveCompare(txid) == .orderedSame, (observed?.sent ?? 0) > 0
            else { throw OnchainSendAttemptError.localFollowupNotSaved }
        }
        guard let fee = observed?.fee ?? existing?.fee else { throw OnchainSendAttemptError.localFollowupNotSaved }
        let feeRate = metadata?.feeRate ?? existing?.feeRate ?? UInt64(observed?.feeRate ?? 0)
        guard await CoreService.shared.activity.createSentOnchainActivityFromSendResult(
            txid: txid, address: address, amount: amount, fee: fee, feeRate: UInt32(clamping: feeRate),
            // A saved Sent row may already have a later user contact edit, including deletion.
            // Preserve it even if the proof acknowledgement write needs to be retried.
            contact: existing?.txType == .sent ? existing?.contact : proof.requestId.counterparty, walletId: walletId
        ) else { throw OnchainSendAttemptError.localFollowupNotSaved }
        if let tags = metadata?.tags, !tags.isEmpty {
            try await CoreService.shared.activity.appendTags(toActivity: txid, tags, walletId: walletId)
        }
        guard let saved = try await CoreService.shared.activity.getOnchainActivityByTxId(txid: txid, walletId: walletId),
              saved.txType == .sent, saved.txId.caseInsensitiveCompare(txid) == .orderedSame
        else { throw OnchainSendAttemptError.localFollowupNotSaved }
    }

    func resolvedHardwarePayment(requestId: PaykitPaymentRequest.ID, identity: String, walletId: String,
                                 txid: String) async -> PaykitOnchainPaymentResolution?
    {
        guard let active = try? await currentIdentity(), PubkyPublicKeyFormat.matches(active, identity) else { return nil }
        let pending: PendingPaykitPaymentProof?
        do { pending = try await pendingOnchainPayment(requestId: requestId, identity: identity) }
        catch { return nil }
        if let proof = pending,
           proof.onchainWalletId == walletId, proof.onchainAcceptanceVerified == true,
           proof.paymentIdentifier?.caseInsensitiveCompare(txid) == .orderedSame,
           proof.proofData?.caseInsensitiveCompare(txid) == .orderedSame
        {
            guard await completeHardwareOnchainPayment(requestId: requestId, identity: identity, walletId: walletId, txid: txid) else { return nil }
        } else {
            // Delivery can remove the local proof before Pending reopens. Require both
            // exact remote proof and fresh original-wallet observation, never a local row alone.
            guard hardwareTransactionLookup.hasWallet(walletId: walletId),
                  let records = try? await sdk.paymentRequests(), records.contains(where: { Self.hasExactOnchainProof(
                      requestId: requestId,
                      txid: txid,
                      in: $0
                  ) }),
                  let detail = try? await hardwareTransactionLookup.transactionDetail(walletId: walletId, txid: txid),
                  detail.txid.caseInsensitiveCompare(txid) == .orderedSame, detail.sent > 0,
                  let activity = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: txid, walletId: walletId),
                  activity.txType == .sent
            else { return nil }
        }
        return PaykitOnchainPaymentResolution(identity: identity, requestId: requestId, transactionId: txid.lowercased(), walletId: walletId)
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
            let completed: [PendingPaykitPaymentProof] = try await mutationLock.withLock {
                var proofs = try await loadProofs()
                let indexes = proofs.indices
                    .filter { proofs[$0].kind == .lightning && proofs[$0].paymentIdentifier?.caseInsensitiveCompare(paymentHash) == .orderedSame }
                for index in indexes {
                    proofs[index].proofData = preimage.lowercased()
                }
                let completed = indexes.map { proofs[$0] }
                if !completed.isEmpty {
                    do { try await persist(proofs) }
                    catch { logWarning("Failed to persist completed Lightning proof; attempting immediate delivery: \(error)") }
                }
                return completed
            }
            for proof in completed where await !submit(proof) {
                try await mutationLock.withLock {
                    var proofs = try await loadProofs()
                    guard let index = proofs.firstIndex(where: {
                        PubkyPublicKeyFormat.matches($0.identity, proof.identity) && $0.requestId == proof.requestId &&
                            $0.kind == .lightning && $0.paymentIdentifier == proof.paymentIdentifier
                    }) else { return }
                    proofs[index].proofData = proof.proofData
                    try await persist(proofs)
                }
            }
        } catch { logWarning("Failed to complete a Paykit Lightning payment proof: \(error)") }
    }

    @discardableResult
    func completeOnchainPayment(
        _ request: PaykitPaymentRequest,
        txid: String,
        paymentEndpointIdentifier: String
    ) async -> Bool {
        guard let identity = try? await currentIdentity() else { return false }
        return await completeOnchainPayment(
            requestId: request.id,
            identity: identity,
            txid: txid
        )
    }

    private func completeOnchainPayment(
        requestId: PaykitPaymentRequest.ID,
        identity: String,
        txid: String
    ) async -> Bool {
        guard Self.isHex(txid, byteCount: 32) else { return false }
        do {
            // SDK operations can suspend on network. Obtain remote evidence before the
            // storage critical section, then re-read all mutable proof/attempt state there.
            let snapshot = try await loadProofs()
            let hasStartedProof = snapshot.contains {
                PubkyPublicKeyFormat.matches($0.identity, identity) && $0.requestId == requestId &&
                    $0.kind == .onchain && !$0.hasUnsupportedOnchainWallet && $0.paymentStarted
            }
            let hasRemoteProof = hasStartedProof ? false : try await sdk.paymentRequests().contains(where: {
                Self.hasExactOnchainProof(requestId: requestId, txid: txid, in: $0)
            })
            let result: (Bool, PendingPaykitPaymentProof?) = try await mutationLock.withLock {
                var proofs = try await loadProofs()
                if let completed = proofs.last(where: {
                    PubkyPublicKeyFormat.matches($0.identity, identity) && $0.requestId == requestId &&
                        $0.kind == .onchain && !$0.hasUnsupportedOnchainWallet && $0.onchainAcceptanceVerified == true &&
                        $0.paymentStarted && $0.paymentIdentifier?.caseInsensitiveCompare(txid) == .orderedSame &&
                        $0.proofData?.caseInsensitiveCompare(txid) == .orderedSame
                }) {
                    return (true, completed)
                }
                guard try await attemptService.acceptedTransactionId(for: requestId)?.caseInsensitiveCompare(txid) == .orderedSame else { return (
                    false,
                    nil
                ) }
                guard let index = proofs.lastIndex(where: {
                    PubkyPublicKeyFormat.matches($0.identity, identity) && $0.requestId == requestId &&
                        $0.kind == .onchain && !$0.hasUnsupportedOnchainWallet && $0.paymentStarted &&
                        (($0.paymentIdentifier == nil && $0.proofData == nil) ||
                            ($0.paymentIdentifier?.caseInsensitiveCompare(txid) == .orderedSame &&
                                $0.proofData?.caseInsensitiveCompare(txid) == .orderedSame))
                }) else { return (hasRemoteProof, nil) }
                proofs[index].paymentIdentifier = txid.lowercased()
                proofs[index].proofData = txid.lowercased()
                proofs[index].onchainAcceptanceVerified = true
                try await persist(proofs)
                return (true, proofs[index])
            }
            guard result.0 else { return false }
            await resumeAcceptedRequestFollowup(requestId: requestId, txid: txid)
            if let completed = result.1 {
                submitInBackground(completed)
                Self.onchainPaymentResolutionSubject.send(PaykitOnchainPaymentResolution(
                    identity: completed.identity, requestId: requestId, transactionId: txid.lowercased()
                ))
            }
            return true
        } catch {
            logWarning("Failed to retain a completed Paykit on-chain proof for retry: \(error)")
            return false
        }
    }

    func failLightningPayment(paymentHash: String) async {
        await removeProofs {
            $0.kind == .lightning && $0.paymentIdentifier?.caseInsensitiveCompare(paymentHash) == .orderedSame
        }
    }

    func failLightningPayment(paymentHash: String, submissionError: Error) async -> Bool {
        let underlyingError = (submissionError as? AppError)?.underlyingError ?? submissionError
        if let serviceError = underlyingError as? CustomServiceError {
            guard serviceError == .nodeNotSetup || serviceError == .nodeNotStarted else { return false }
        } else if let nodeError = underlyingError as? NodeError {
            switch nodeError {
            case .NotRunning, .InvalidInvoice, .InvalidAmount, .PaymentSendingFailed:
                break
            default:
                return false
            }
        } else {
            return false
        }
        await failLightningPayment(paymentHash: paymentHash)
        return true
    }

    func failOnchainPayment(_ request: PaykitPaymentRequest) async {
        await removeRequestProofs(request) {
            $0.kind == .onchain &&
                !$0.hasUnsupportedOnchainWallet &&
                $0.paymentStarted &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }
    }

    func cancelHardwarePaymentBeforeDispatch(_ request: PaykitPaymentRequest, paymentIdentity: String, walletId: String) async {
        guard let identity = PubkyPublicKeyFormat.normalized(paymentIdentity), walletId != WalletScope.default,
              hardwareTransactionLookup.hasWallet(walletId: walletId) else { return }
        // Called only by the coordinator after authorization fails before its first native dispatch.
        // A profile switch does not change ownership of the original prepared operation.
        await removeProofs {
            PubkyPublicKeyFormat.matches($0.identity, identity) && $0.requestId == request.id &&
                $0.kind == .onchain && $0.onchainWalletId == walletId && $0.paymentStarted &&
                $0.paymentIdentifier == nil && $0.proofData == nil && $0.onchainAcceptanceVerified != true
        }
    }

    func cancelPreparation(_ request: PaykitPaymentRequest) async {
        await removeRequestProofs(request) {
            !$0.hasUnsupportedOnchainWallet &&
                !$0.paymentStarted &&
                $0.paymentIdentifier == nil &&
                $0.proofData == nil
        }
    }

    func reconcile() async {
        do {
            var pendingProofs = try await loadProofs()
            let acceptedRequest = try await attemptService.acceptedRequestAttempt()
            guard !pendingProofs.isEmpty || acceptedRequest != nil else { return }
            guard let identityStatus = try await sdk.identityStatus(),
                  identityStatus.liveSessionAvailable,
                  let publicKey = identityStatus.publicKey,
                  let identity = PubkyPublicKeyFormat.normalized(publicKey)
            else { return }

            if let acceptedRequest, let requestId = acceptedRequest.requestId, let txid = acceptedRequest.txid {
                let hasSavedProof = pendingProofs.contains {
                    PubkyPublicKeyFormat.matches($0.identity, identity) && $0.requestId == requestId &&
                        $0.kind == .onchain && !$0.hasUnsupportedOnchainWallet && $0.onchainAcceptanceVerified == true &&
                        $0.paymentStarted && $0.paymentIdentifier?.caseInsensitiveCompare(txid) == .orderedSame &&
                        $0.proofData?.caseInsensitiveCompare(txid) == .orderedSame
                }
                var hasDurableProof = hasSavedProof
                if !hasDurableProof {
                    hasDurableProof = try await sdk.paymentRequests().contains(where: {
                        Self.hasExactOnchainProof(requestId: requestId, txid: txid, in: $0)
                    })
                }
                if hasDurableProof {
                    await resumeAcceptedRequestFollowup(requestId: requestId, txid: txid)
                }
            }
            pendingProofs = await removingSettledUnsupportedWalletProofs(from: pendingProofs, identity: identity)
            let identityProofs = pendingProofs.filter {
                PubkyPublicKeyFormat.matches($0.identity, identity)
            }
            for proof in identityProofs {
                do {
                    if proof.kind == .onchain, proof.paymentStarted,
                       let walletId = proof.onchainWalletId, walletId != WalletScope.default,
                       let txid = proof.paymentIdentifier
                    {
                        guard hardwareTransactionLookup.hasWallet(walletId: walletId) else { continue }
                        _ = await completeHardwareOnchainPayment(
                            requestId: proof.requestId, identity: proof.identity, walletId: walletId, txid: txid,
                            deliverInBackground: false
                        )
                        continue
                    }
                    guard !proof.hasUnsupportedOnchainWallet else { continue }
                    if proof.proofData != nil {
                        if proof.kind == .onchain, proof.onchainAcceptanceVerified != true {
                            if proof.paymentStarted,
                               let txid = try await attemptService.acceptedTransactionId(for: proof.requestId),
                               proof.paymentIdentifier?.caseInsensitiveCompare(txid) == .orderedSame,
                               proof.proofData?.caseInsensitiveCompare(txid) == .orderedSame
                            {
                                _ = await completeOnchainPayment(requestId: proof.requestId, identity: proof.identity, txid: txid)
                            }
                            continue
                        }
                        await submit(proof)
                        continue
                    }
                    if proof.kind == .onchain,
                       proof.paymentStarted,
                       let txid = try await attemptService.acceptedTransactionId(for: proof.requestId)
                    {
                        _ = await completeOnchainPayment(requestId: proof.requestId, identity: proof.identity, txid: txid)
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

    private func resumeAcceptedRequestFollowup(requestId: PaykitPaymentRequest.ID, txid: String) async {
        do {
            _ = try await attemptService.resumeAcceptedRequestSend(requestId: requestId, txid: txid)
        } catch {
            logWarning("Accepted Paykit payment local follow-up remains guarded: \(error)")
        }
    }

    private static func hasExactOnchainProof(requestId: PaykitPaymentRequest.ID, txid: String, in record: Paykit.PaymentRequestRecord) -> Bool {
        record.localRole == .payer && record.paymentRequestId == requestId.paymentRequestId &&
            PubkyPublicKeyFormat.matches(record.counterparty, requestId.counterparty) &&
            record.counterpartyReceiverPath == requestId.counterpartyReceiverPath && record.paymentProofs.contains { proof in
                proof.billingPeriod.flatMap(PaykitBillingPeriod.init)?.startsAt == requestId.billingPeriodStartsAt &&
                    Self.proofValues(proof.proof.exportText()) == [
                        "type": PaykitPaymentProofKind.onchain.rawValue,
                        "data": txid.lowercased(),
                    ]
            }
    }

    private func removingSettledUnsupportedWalletProofs(
        from pendingProofs: [PendingPaykitPaymentProof],
        identity: String
    ) async -> [PendingPaykitPaymentProof] {
        let candidates = pendingProofs.filter {
            $0.hasUnsupportedOnchainWallet && PubkyPublicKeyFormat.matches($0.identity, identity) &&
                $0.onchainWalletId.map { hardwareTransactionLookup.hasWallet(walletId: $0) } != true
        }
        guard !candidates.isEmpty else { return pendingProofs }

        do {
            let records = try await sdk.paymentRequests()
            guard let identityStatus = try await sdk.identityStatus(),
                  identityStatus.liveSessionAvailable,
                  PubkyPublicKeyFormat.matches(identityStatus.publicKey, identity)
            else { return pendingProofs }

            return try await mutationLock.withLock {
                let currentProofs = try await loadProofs()
                let remainingProofs = currentProofs.filter { proof in
                    !candidates.contains(proof) || !Self.hasSubmittedRemoteProof(matching: proof, in: records)
                }
                if remainingProofs != currentProofs {
                    try await persist(remainingProofs)
                }
                return remainingProofs
            }
        } catch {
            logWarning("Failed to reconcile Paykit payment proofs for another wallet: \(error)")
            return await (try? loadProofs()) ?? pendingProofs
        }
    }

    private static func hasSubmittedRemoteProof(
        matching pendingProof: PendingPaykitPaymentProof,
        in records: [Paykit.PaymentRequestRecord]
    ) -> Bool {
        records.contains { record in
            guard record.localRole == .payer,
                  record.paymentRequestId == pendingProof.requestId.paymentRequestId,
                  PubkyPublicKeyFormat.matches(record.counterparty, pendingProof.requestId.counterparty),
                  record.counterpartyReceiverPath == pendingProof.requestId.counterpartyReceiverPath,
                  pendingProof.billingPeriod != nil || record.state == .proofSubmitted
            else { return false }

            return record.paymentProofs.contains { remoteProof in
                let billingPeriodMatches = if let billingPeriod = pendingProof.billingPeriod {
                    remoteProof.billingPeriod.flatMap(PaykitBillingPeriod.init) == billingPeriod
                } else {
                    remoteProof.billingPeriod == nil
                }
                guard billingPeriodMatches,
                      remoteProof.paymentEndpointIdentifier == pendingProof.paymentEndpointIdentifier,
                      let values = proofValues(remoteProof.proof.exportText()),
                      values["type"] == PaykitPaymentProofKind.onchain.rawValue,
                      let transactionId = values["data"],
                      isHex(transactionId, byteCount: 32)
                else { return false }

                return [pendingProof.paymentIdentifier, pendingProof.proofData]
                    .compactMap { $0 }
                    .allSatisfy { $0.caseInsensitiveCompare(transactionId) == .orderedSame }
            }
        }
    }

    func completedRequestProofKindsAwaitingSubmission(identity: String) async -> [PaykitPaymentRequest.ID: PaykitPaymentProofKind] {
        do {
            return try await loadProofs().reduce(into: [:]) { result, proof in
                guard PubkyPublicKeyFormat.matches(proof.identity, identity), proof.proofData != nil,
                      proof.kind != .onchain || proof.onchainAcceptanceVerified == true
                else { return }
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

    func pendingOnchainPayment(requestId: PaykitPaymentRequest.ID, identity: String) async throws -> PendingPaykitPaymentProof? {
        try await loadProofs().last {
            PubkyPublicKeyFormat.matches($0.identity, identity) && $0.requestId == requestId && $0.kind == .onchain && $0.paymentStarted
        }
    }

    func protectedRequestIdsForSubscriptionCancellation(
        identity: String,
        subscriptionId: PaykitSubscription.ID
    ) async throws -> Set<PaykitPaymentRequest.ID> {
        return try await mutationLock.withLock {
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
                !belongsToSubscription($0) || $0.hasUnsupportedOnchainWallet || $0.paymentStarted || $0.paymentIdentifier != nil || $0
                    .proofData != nil
            }
            if remainingProofs != proofs {
                try await persist(remainingProofs)
            }
            return protectedRequestIds
        }
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
        guard !pendingProof.hasUnsupportedOnchainWallet ||
            pendingProof.onchainWalletId.map({ hardwareTransactionLookup.hasWallet(walletId: $0) }) == true,
            let proofData = pendingProof.proofData else { return false }
        guard pendingProof.kind != .onchain || pendingProof.onchainAcceptanceVerified == true else { return false }
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
                        allowanceId: nil,
                        conversionQuoteId: nil,
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
        Self.proofStateChangedSubject.send()
    }

    private func submitInBackground(_ proof: PendingPaykitPaymentProof) {
        Task { [weak self] in await self?.submit(proof) }
    }

    private func removeRequestProofs(_ proof: PendingPaykitPaymentProof) async {
        await removeProofs {
            PubkyPublicKeyFormat.matches($0.identity, proof.identity) &&
                $0.requestId == proof.requestId &&
                (!$0.hasUnsupportedOnchainWallet || $0 == proof)
        }
    }

    private func removeRequestProofs(
        _ request: PaykitPaymentRequest,
        where shouldRemove: (PendingPaykitPaymentProof) -> Bool
    ) async {
        let identity = try? await currentIdentity()
        await mutationLock.withLock {
            await removeRequestProofsLocked(request, identity: identity, where: shouldRemove)
        }
    }

    private func removeRequestProofsLocked(
        _ request: PaykitPaymentRequest,
        identity: String?,
        where shouldRemove: (PendingPaykitPaymentProof) -> Bool
    ) async {
        do {
            let pendingProofs = try await loadProofs()
            let candidates = pendingProofs.filter { $0.requestId == request.id && shouldRemove($0) }
            let candidateIdentities = Set(candidates.compactMap { PubkyPublicKeyFormat.normalized($0.identity) })
            guard let targetIdentity = identity ?? (candidateIdentities.count == 1 ? candidateIdentities.first : nil) else { return }

            let remainingProofs = pendingProofs.filter {
                !($0.requestId == request.id &&
                    PubkyPublicKeyFormat.matches($0.identity, targetIdentity) &&
                    shouldRemove($0))
            }
            guard remainingProofs != pendingProofs else { return }
            try await persist(remainingProofs)
        } catch {
            logWarning("Failed to clear a pending Paykit payment proof: \(error)")
        }
    }

    private func removeProofs(where shouldRemove: (PendingPaykitPaymentProof) -> Bool) async {
        await mutationLock.withLock {
            await removeProofsLocked(where: shouldRemove)
        }
    }

    private func removeProofsLocked(where shouldRemove: (PendingPaykitPaymentProof) -> Bool) async {
        do {
            let pendingProofs = try await loadProofs()
            let remainingProofs = pendingProofs.filter { !shouldRemove($0) }
            guard remainingProofs != pendingProofs else { return }
            try await persist(remainingProofs)
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
