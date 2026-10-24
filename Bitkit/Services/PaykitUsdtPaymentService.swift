import BitkitCore
import Combine
import Foundation
import Observation
import Paykit

/// The request binding survives proof delivery so a retry cannot start another payment.
@Observable @MainActor
final class PaykitUsdtPaymentService {
    static let shared = PaykitUsdtPaymentService()

    struct Proof: Codable, Equatable {
        let type: String
        let chainId: String
        let transactionHash: String
        let receiptLogIndex: String
        let signature: String

        enum CodingKeys: String, CodingKey {
            case type, signature
            case chainId = "chain_id"
            case transactionHash = "transaction_hash"
            case receiptLogIndex = "receipt_log_index"
        }

        init(_ value: UsdtPaymentProof) {
            type = "erc20-transfer-eip712"
            chainId = value.chainId
            transactionHash = value.transactionHash
            receiptLogIndex = value.receiptLogIndex
            signature = value.signature
        }

        var coreValue: UsdtPaymentProof {
            UsdtPaymentProof(chainId: chainId, transactionHash: transactionHash, receiptLogIndex: receiptLogIndex, signature: signature)
        }
    }

    struct Attempt: Codable, Equatable {
        let quoteId: String
        let wallet: String
        let identity: String
        let contact: String
        let requestId: PaykitPaymentRequest.ID?
        let binding: UsdtPaymentProofBinding?
        let billingPeriod: PaykitBillingPeriod?
        var proof: Proof?
        var proofQueued = false
        var paymentStarted = false
    }

    struct Receipt: Codable, Equatable {
        let wallet: String
        let identity: String
        let requestId: PaykitPaymentRequest.ID
        let paymentId: String
        let proofEventId: String
        var verified: Bool
        let transferId: String
        let amount: PaykitAmount
        let receivedAt: Date
        let underpaid: Bool
        let afterExpiry: Bool
        var satisfied: Bool {
            verified && !underpaid && !afterExpiry
        }
    }

    private struct State: Codable {
        var attempts: [Attempt] = []
        var receipts: [Receipt] = []
    }

    private(set) var attempts: [Attempt] = []
    private(set) var receipts: [Receipt] = []
    private var activeWallet: String?
    private var activeIdentity: String?
    private var reconciling = false
    private var preparing = false
    private var stateGeneration = 0
    private var sending = false
    private var reconcilingResumableRequests: Set<PaykitPaymentRequest.ID> = []
    private(set) var resumableRequests: Set<PaykitPaymentRequest.ID> = [] {
        didSet {
            if !reconciling, oldValue != resumableRequests {
                Self.paymentProtectionChanged.send()
            }
        }
    }

    private var releasedAttempts: [Attempt] = []
    private var boundRequestIds: Set<PaykitPaymentRequest.ID>?

    private nonisolated(unsafe) static let stateChanged = PassthroughSubject<Void, Never>()
    nonisolated static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        stateChanged.eraseToAnyPublisher()
    }

    private nonisolated(unsafe) static let paymentProtectionChanged = PassthroughSubject<Void, Never>()
    nonisolated static var paymentProtectionChangedPublisher: AnyPublisher<Void, Never> {
        paymentProtectionChanged.eraseToAnyPublisher()
    }

    func backupSnapshot() throws -> PaykitUsdtStateBackup {
        let state = try load()
        return PaykitUsdtStateBackup(attempts: state.attempts.map(PaykitUsdtStateBackup.Attempt.init),
                                     receipts: state.receipts.map(PaykitUsdtStateBackup.Receipt.init))
    }

    func restoreBackup(_ backup: PaykitUsdtStateBackup) throws {
        boundRequestIds = nil
        stateGeneration &+= 1
        activeWallet = nil
        activeIdentity = nil
        releasedAttempts = []
        resumableRequests = []
        reconcilingResumableRequests = []
        var state = try load()
        for attempt in try backup.attempts.map({ try $0.restored() }) {
            if let index = state.attempts.firstIndex(where: { $0.wallet == attempt.wallet && $0.quoteId == attempt.quoteId }) {
                guard state.attempts[index].bindingState == attempt.bindingState else { throw UsdtError.InvalidBackup }
                state.attempts[index].paymentStarted = state.attempts[index].paymentStarted || attempt.paymentStarted ||
                    attempt.proof != nil || attempt.proofQueued
            } else {
                state.attempts.append(attempt)
            }
        }
        // Restored delivery queues may be older than local payment evidence; reconciliation deduplicates proofs.
        for index in state.attempts.indices {
            state.attempts[index].paymentStarted = state.attempts[index].paymentStarted ||
                state.attempts[index].proof != nil || state.attempts[index].proofQueued
            state.attempts[index].proof = nil
            state.attempts[index].proofQueued = false
        }
        for receipt in try backup.receipts.map({ try $0.restored() }) where !state.receipts.contains(where: {
            $0.wallet == receipt.wallet && $0.paymentId == receipt.paymentId
        }) {
            state.receipts.append(receipt)
        }
        // Journal order does not establish which chain evidence is newest. Recreate proofs and
        // verify receipts against the canonical chain before using restored payment evidence.
        for index in state.receipts.indices {
            state.receipts[index].verified = false
        }
        try save(state)
    }

    func pauseForRecoveryRestore() {
        stateGeneration &+= 1
    }

    func resetForWipe() {
        stateGeneration &+= 1
        activeWallet = nil
        activeIdentity = nil
        boundRequestIds = nil
        releasedAttempts = []
        resumableRequests = []
        reconcilingResumableRequests = []
        publish(State())
        Self.paymentProtectionChanged.send()
    }

    func send(_ quote: UsdtQuote, context: ContactPaymentContext, paymentTerms: PaykitRequestPricing.Payment?,
              wallet: UsdtWalletManager, authorize: @escaping @MainActor () async throws -> Void) async throws
    {
        let submissionDeadline = try context.incomingPaymentRequest?.submissionDeadline(quoteId: paymentTerms?.quoteId)
        guard !sending, !preparing else { throw PaykitPaymentRequestError.operationInProgress }
        sending = true
        stateGeneration += 1
        defer { sending = false }
        let wasResumable = try setPaymentStarted(quoteId: quote.id, started: true)
        do {
            try await wallet.send(quote, submissionDeadline: submissionDeadline) {
                do {
                    try await authorize()
                    try Task.checkCancellation()
                    if let request = context.incomingPaymentRequest {
                        guard !request.isExpired(at: Date()),
                              request.acceptsPayment(
                                  PaykitAmount(asset: .usdt, atomic: quote.amount),
                                  method: .usdtArbitrum,
                                  paymentTerms: paymentTerms
                              )
                        else { throw PaykitPaymentRequestError.amountMismatch }
                    }
                } catch {
                    _ = try? self.setPaymentStarted(quoteId: quote.id, started: false, resumable: wasResumable)
                    throw error
                }
            }
        } catch {
            // Core persists signed operations before broadcast. Only this completed send can establish non-submission.
            if !(error is CancellationError), await (try? wallet.storedTransfer(quote.id) == nil) == true {
                _ = try? setPaymentStarted(quoteId: quote.id, started: false, resumable: wasResumable)
            }
            throw error
        }
    }

    @discardableResult
    private func setPaymentStarted(quoteId: String, started: Bool, resumable: Bool = false) throws -> Bool {
        var state = try load()
        guard let index = state.attempts.firstIndex(where: {
            $0.quoteId == quoteId && $0.wallet == activeWallet && $0.identity == activeIdentity
        }) else { throw PaykitPaymentRequestError.requestUnavailable }
        state.attempts[index].paymentStarted = started
        let requestId = state.attempts[index].requestId
        let wasResumable = requestId.map { resumableRequests.contains($0) || reconcilingResumableRequests.contains($0) } ?? false
        if let requestId {
            if started {
                resumableRequests.remove(requestId)
                reconcilingResumableRequests.remove(requestId)
            } else if resumable {
                resumableRequests.insert(requestId)
            }
        }
        try save(state)
        return wasResumable
    }

    private func load() throws -> State {
        guard let data = try Keychain.load(key: .paykitUsdtPayments) else { return State() }
        return try JSONDecoder().decode(State.self, from: data)
    }

    private func save(_ state: State) throws {
        boundRequestIds = nil
        try Keychain.upsert(key: .paykitUsdtPayments, data: JSONEncoder().encode(state))
        publish(state)
        Self.stateChanged.send()
        Self.paymentProtectionChanged.send()
    }

    private func publish(_ state: State) {
        attempts = state.attempts.filter { $0.wallet == activeWallet && $0.identity == activeIdentity }
        receipts = state.receipts.filter { $0.wallet == activeWallet && $0.identity == activeIdentity }
        releasedAttempts.removeAll { !attempts.contains($0) }
        boundRequestIds = Set(state.attempts.filter { !releasedAttempts.contains($0) }.compactMap(\.requestId))
    }

    func hasBinding(for requestId: PaykitPaymentRequest.ID) -> Bool {
        if boundRequestIds == nil {
            guard let state = try? load() else { return true }
            publish(state)
        }
        return boundRequestIds?.contains(requestId) ?? true
    }

    func paymentProtection(identity: String) throws
        -> (inFlight: Set<PaykitPaymentRequest.ID>, completed: [PaykitPaymentRequest.ID: PaykitPaymentProofKind])
    {
        var inFlight = Set<PaykitPaymentRequest.ID>()
        var completed: [PaykitPaymentRequest.ID: PaykitPaymentProofKind] = [:]
        for attempt in try load().attempts where PubkyPublicKeyFormat.matches(attempt.identity, identity) &&
            (activeWallet == nil || attempt.wallet == activeWallet) && !attempt.proofQueued
        {
            guard let id = attempt.requestId,
                  attempt.wallet != activeWallet || !PubkyPublicKeyFormat.matches(activeIdentity, identity) || !resumableRequests.contains(id)
            else { continue }
            if attempt.paymentStarted || attempt.proof != nil {
                inFlight.insert(id)
            }
            if attempt.proof != nil {
                completed[id] = .usdt
            }
        }
        return (inFlight, completed)
    }

    func satisfiedProofs(identity: String) throws -> [PaykitPaymentRequest.ID: Set<String>] {
        guard PubkyPublicKeyFormat.matches(activeIdentity, identity), let activeWallet else { return [:] }
        var proofs: [PaykitPaymentRequest.ID: Set<String>] = [:]
        for receipt in try load().receipts where receipt.wallet == activeWallet &&
            PubkyPublicKeyFormat.matches(receipt.identity, identity) && receipt.satisfied
        {
            proofs[receipt.requestId, default: []].insert(receipt.proofEventId)
        }
        return proofs
    }

    func receipt(for request: PaykitPaymentRequest) -> Receipt? {
        receipts.last { $0.requestId == request.id && $0.proofEventId == request.paymentProofEventId }
    }

    func contact(for transferId: String) -> String? {
        attempts.first { $0.quoteId == transferId }?.contact ?? receipts.first { $0.transferId == transferId }?.requestId.counterparty
    }

    static func binding(request: PaykitPaymentRequest, identity: String, paymentAppId: String, quoteId: String?,
                        period: Paykit.BillingPeriod?) throws -> UsdtPaymentProofBinding
    {
        let local = try PaykitPublicKeys.raw(identity)
        let remote = try PaykitPublicKeys.raw(request.counterparty)
        guard let uuid = UUID(uuidString: request.paymentRequestId) else { throw PaykitPaymentRequestError.requestUnavailable }
        let incoming = request.direction == .incoming
        return UsdtPaymentProofBinding(
            payer: incoming ? local : remote, payee: incoming ? remote : local,
            paymentAppId: paymentAppId,
            paymentRequestId: uuid.uuidString.lowercased(), paymentReference: request.paymentReference,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.usdtArbitrum.rawValue,
            // EIP-712 binds the proof's timestamp strings, not their normalized spelling.
            periodStartsAt: period?.startsAt ?? "", periodEndsAt: period?.endsAt ?? "",
            conversionQuoteId: quoteId ?? ""
        )
    }

    /// Check the complete wire message, including its outer request fields, before spending funds.
    static func validateProofSize(binding: UsdtPaymentProofBinding) throws {
        let placeholder = Proof(UsdtPaymentProof(chainId: "42161", transactionHash: "0x" + String(repeating: "0", count: 64),
                                                 receiptLogIndex: String(repeating: "9", count: 78),
                                                 signature: "0x" + String(repeating: "0", count: 130)))
        var message: [String: Any] = try [
            "version": 1, "kind": "paykit.payment_proof", "app_id": "bitkit", "event_id": UUID().uuidString.lowercased(),
            "payment_request_id": binding.paymentRequestId, "payment_reference": binding.paymentReference,
            "payment_app_id": binding.paymentAppId,
            "payment_endpoint_identifier": binding.paymentEndpointIdentifier,
            "billing_period": NSNull(), "proof": JSONSerialization.jsonObject(with: JSONEncoder().encode(placeholder)),
        ]
        if !binding.periodStartsAt.isEmpty {
            message["billing_period"] = ["starts_at": binding.periodStartsAt, "ends_at": binding.periodEndsAt]
        }
        if !binding.conversionQuoteId.isEmpty {
            message["conversion_quote_id"] = binding.conversionQuoteId
        }
        guard try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]).count <= PaykitSdkService.maximumMessageBytes
        else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
    }

    func prepare(context: ContactPaymentContext, quote: UsdtQuote, wallet: UsdtWalletManager,
                 amount: PaykitAmount?, paymentTerms: PaykitRequestPricing.Payment?) async throws
    {
        guard !preparing, !sending else { throw PaykitPaymentRequestError.operationInProgress }
        preparing = true
        defer { preparing = false }
        guard quote.destination == .arbitrum, quote.amount > 0,
              let endpoint = context.endpoints.first(where: { $0.methodId == .usdtArbitrum }),
              let address = PaykitUsdt.address(from: endpoint.rawPayload),
              address.caseInsensitiveCompare(quote.recipient) == .orderedSame,
              let identity = try await currentIdentity()
        else { throw PaykitPaymentRequestError.requestUnavailable }
        let payment = PaykitAmount(asset: .usdt, atomic: quote.amount)
        guard amount == payment else { throw PaykitPaymentRequestError.amountMismatch }
        let request = context.incomingPaymentRequest
        if let request {
            guard request.acceptedPaymentEndpointIdentifiers.contains(PublicPaykitService.MethodId.usdtArbitrum.rawValue),
                  !request.isExpired(at: Date()),
                  request.acceptsPayment(payment, method: .usdtArbitrum, paymentTerms: paymentTerms)
            else { throw PaykitPaymentRequestError.amountMismatch }
        }
        let owner = wallet.address.lowercased()
        if activeWallet != owner || activeIdentity != identity {
            resumableRequests = []
            reconcilingResumableRequests = []
        }
        activeWallet = owner
        activeIdentity = identity
        let binding: UsdtPaymentProofBinding?
        if let request {
            guard let privateContext = context.privatePaymentContext else {
                throw PaykitPaymentRequestError.requestUnavailable
            }
            binding = try Self.binding(request: request, identity: identity,
                                       paymentAppId: privateContext.paymentAppId(for: PublicPaykitService.MethodId.usdtArbitrum.rawValue),
                                       quoteId: paymentTerms?.quoteId, period: request.billingPeriod?.sdkValue)
        } else {
            binding = nil
        }
        if let binding {
            try Self.validateProofSize(binding: binding)
        }
        let attempt = Attempt(quoteId: quote.id, wallet: owner, identity: identity, contact: context.publicKey,
                              requestId: request?.id, binding: binding, billingPeriod: request?.billingPeriod)
        try await storeAttempt(attempt, storedTransfer: { try await wallet.storedTransfer($0) })
    }

    func storeAttempt(_ attempt: Attempt, storedTransfer: (String) async throws -> UsdtTransfer?) async throws {
        guard !sending else { throw PaykitPaymentRequestError.operationInProgress }
        let generation = stateGeneration
        let state = try load()
        let existing = state.attempts.first { $0.wallet == attempt.wallet && $0.quoteId == attempt.quoteId }
        if let existing, existing.bindingState != attempt.bindingState {
            throw PaykitPaymentRequestError.operationInProgress
        }
        var removable: [Attempt] = []
        for previous in state.attempts where previous.wallet == attempt.wallet && previous.identity == attempt.identity &&
            attempt.requestId != nil && previous.requestId == attempt.requestId && previous.quoteId != attempt.quoteId
        {
            guard previous.proof == nil, !previous.proofQueued else { throw PaykitPaymentRequestError.operationInProgress }
            let transfer = try await storedTransfer(previous.quoteId)
            guard (transfer == nil && !previous.paymentStarted) || transfer?.status == .failed || transfer?.status == .replaced else {
                throw PaykitPaymentRequestError.operationInProgress
            }
            if transfer == nil, !previous.paymentStarted {
                removable.append(previous)
            }
        }
        var current = try load()
        guard stateGeneration == generation, !sending, current.attempts == state.attempts else {
            throw PaykitPaymentRequestError.operationInProgress
        }
        current.attempts.removeAll { removable.contains($0) }
        if existing == nil {
            current.attempts.append(attempt)
        }
        releasedAttempts = []
        try save(current)
    }

    func reconcile(wallet: UsdtWalletManager, sdk: PaykitSdkService = .shared) async {
        guard wallet.canRecoverTransfers else { return }
        guard wallet.isConfigured, UsdtPreference.isEnabled() || (try? wallet.hasStoredWallet) == true else {
            boundRequestIds = nil
            releasedAttempts = []
            resumableRequests = []
            reconcilingResumableRequests = []
            return
        }
        await reconcile(
            context: {
                guard let identity = try await self.currentIdentity(sdk: sdk) else { return nil }
                let endpoint = try await wallet.paymentEndpoint()
                return (endpoint.value.lowercased(), identity)
            },
            storedTransfer: { try await wallet.storedTransfer($0) },
            paymentProof: { try await wallet.paymentProof(quoteId: $0, binding: $1) },
            submitProof: { await PaykitPaymentProofService.shared.submitUsdtProof($0) },
            paymentRequests: { try await sdk.paymentRequests() },
            verifyPayment: { try await wallet.verifyPayment(binding: $0, proof: $1) }
        )
    }

    func reconcile(
        context: () async throws -> (owner: String, identity: String)?,
        storedTransfer: (String) async throws -> UsdtTransfer?,
        paymentProof: (String, UsdtPaymentProofBinding) async throws -> UsdtPaymentProof?,
        submitProof: (PendingPaykitPaymentProof) async -> Bool,
        paymentRequests: () async throws -> [Paykit.PaymentRequestRecord],
        verifyPayment: (UsdtPaymentProofBinding, UsdtPaymentProof) async throws -> UsdtVerifiedPayment?
    ) async {
        guard !reconciling, !sending, !preparing, !UsdtRecoveryRestoreGate.isPending else { return }
        let generation = stateGeneration
        let previousProtection = (activeWallet, activeIdentity, resumableRequests)
        reconciling = true
        defer {
            resumableRequests.formUnion(reconcilingResumableRequests)
            reconcilingResumableRequests = []
            reconciling = false
            if !previousProtection.2.isEmpty || previousProtection != (activeWallet, activeIdentity, resumableRequests) {
                Self.paymentProtectionChanged.send()
            }
        }
        boundRequestIds = nil
        releasedAttempts = []
        reconcilingResumableRequests = resumableRequests
        resumableRequests = []
        do {
            try Task.checkCancellation()
            guard let (owner, identity) = try await context() else { return }
            guard stateGeneration == generation else { return }
            if activeWallet != owner || activeIdentity != identity {
                reconcilingResumableRequests = []
            }
            activeWallet = owner
            activeIdentity = identity
            let state = try load()
            publish(state)
            var released: [Attempt] = []
            for var attempt in state.attempts where attempt.wallet == owner && attempt.identity == identity {
                guard let requestId = attempt.requestId else { continue }
                do {
                    try Task.checkCancellation()
                    let transfer = try await storedTransfer(attempt.quoteId)
                    guard stateGeneration == generation else { return }
                    if transfer == nil, attempt.paymentStarted {
                        var current = try load()
                        guard let index = current.attempts.firstIndex(of: attempt) else { continue }
                        attempt.paymentStarted = false
                        current.attempts[index] = attempt
                        try save(current)
                    }
                    let unexecuted = (transfer == nil && !attempt.paymentStarted) || transfer?.status == .failed || transfer?.status == .replaced
                    if unexecuted, attempt.proof == nil, !attempt.proofQueued {
                        released.append(attempt)
                    } else {
                        reconcilingResumableRequests.remove(requestId)
                    }
                    guard !attempt.proofQueued, let binding = attempt.binding,
                          attempt.proof != nil || transfer?.status == .confirmed else { continue }
                    let proof: Proof
                    if let saved = attempt.proof {
                        proof = saved
                    } else {
                        guard let signed = try await paymentProof(attempt.quoteId, binding) else { continue }
                        guard stateGeneration == generation else { return }
                        proof = Proof(signed)
                        var current = try load()
                        guard let index = current.attempts.firstIndex(where: { $0.quoteId == attempt.quoteId && $0.wallet == owner })
                        else { continue }
                        current.attempts[index].proof = proof
                        try save(current)
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    let data = try String(decoding: encoder.encode(proof), as: UTF8.self)
                    let pending = PendingPaykitPaymentProof(identity: identity, requestId: requestId,
                                                            paymentAppId: binding.paymentAppId,
                                                            paymentEndpointIdentifier: binding.paymentEndpointIdentifier,
                                                            kind: .usdt, billingPeriod: attempt.billingPeriod,
                                                            paymentIdentifier: attempt.quoteId, proofData: data,
                                                            conversionQuoteId: binding.conversionQuoteId.isEmpty ? nil : binding.conversionQuoteId)
                    if await submitProof(pending) {
                        guard stateGeneration == generation else { return }
                        var current = try load()
                        if let index = current.attempts.firstIndex(where: { $0.quoteId == attempt.quoteId && $0.wallet == owner }) {
                            current.attempts[index].proofQueued = true
                            try save(current)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    Logger.warn("Unable to reconcile Paykit USDT payment attempt: \(error)", context: "PaykitUsdt")
                }
            }
            guard stateGeneration == generation, activeWallet == owner, activeIdentity == identity else { return }
            let currentState = try load()
            releasedAttempts = released.filter { currentState.attempts.contains($0) }
            let protected = currentState.attempts.filter {
                $0.wallet == owner && $0.identity == identity && !releasedAttempts.contains($0)
            }
            resumableRequests = Set(releasedAttempts.compactMap(\.requestId)).subtracting(protected.compactMap(\.requestId))
            reconcilingResumableRequests = []
            publish(currentState)
            try Task.checkCancellation()
            for record in try await paymentRequests() where record.localRole == .payee {
                guard stateGeneration == generation else { return }
                for submission in record.paymentProofs
                    where submission.paymentEndpointIdentifier == PublicPaykitService.MethodId.usdtArbitrum.rawValue
                {
                    let request: PaykitPaymentRequest? = if let sdkPeriod = submission.billingPeriod {
                        if let subscription = PaykitSubscription(record: record), let period = PaykitBillingPeriod(sdkPeriod: sdkPeriod),
                           subscription.recurrence.contains(period)
                        {
                            PaykitPaymentRequest(subscription: subscription, billingPeriod: period,
                                                 lifecycleState: .proofSubmitted, paymentProofKind: .usdt, direction: .outgoing)
                        } else {
                            nil
                        }
                    } else {
                        PaykitPaymentRequest(historyRecord: record, now: Date())
                    }
                    guard let request, submission.paymentAppId == "bitkit",
                          request.acceptedPaymentEndpointIdentifiers.contains(submission.paymentEndpointIdentifier),
                          let proof = try? JSONDecoder().decode(Proof.self, from: Data(submission.proof.exportText().utf8)),
                          proof.type == "erc20-transfer-eip712" else { continue }
                    let binding = try Self.binding(
                        request: request,
                        identity: identity,
                        paymentAppId: submission.paymentAppId,
                        quoteId: submission.conversionQuoteId,
                        period: submission.billingPeriod
                    )
                    do {
                        let verified = try await verifyPayment(binding, proof.coreValue)
                        guard stateGeneration == generation else { return }
                        guard let payment = verified else {
                            try invalidateReceipt(proofEventId: submission.eventId, requestId: request.id, owner: owner, identity: identity)
                            continue
                        }
                        var current = try load()
                        guard !current.receipts.contains(where: {
                            $0.wallet == owner && $0.paymentId == payment.paymentId && ($0.identity != identity || $0.requestId != request.id)
                        }) else { continue }
                        let receivedAt = Date(timeIntervalSince1970: TimeInterval(payment.timestamp))
                        let terms = try request.payment(using: .usdtArbitrum, at: receivedAt, quoteId: submission.conversionQuoteId)
                        let received = PaykitAmount(asset: .usdt, atomic: payment.amount)
                        let receipt = Receipt(wallet: owner, identity: identity, requestId: request.id,
                                              paymentId: payment.paymentId, proofEventId: submission.eventId, verified: true,
                                              transferId: payment.transferId, amount: received,
                                              receivedAt: receivedAt, underpaid: received.atomic < terms.amount.atomic,
                                              afterExpiry: !terms.isValid(at: receivedAt))
                        guard !current.receipts.contains(receipt) else { continue }
                        current.receipts.removeAll { $0.wallet == owner && $0.identity == identity && $0.paymentId == payment.paymentId }
                        current.receipts.append(receipt)
                        try save(current)
                    } catch let error as UsdtError {
                        guard stateGeneration == generation else { return }
                        if case .InvalidPaymentProof = error {
                            try invalidateReceipt(proofEventId: submission.eventId, requestId: request.id, owner: owner, identity: identity)
                            continue
                        }
                        throw error
                    } catch is PaykitAmountError { continue }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            Logger.warn("Unable to reconcile Paykit USDT payments: \(error)", context: "PaykitUsdt")
        }
    }

    private func invalidateReceipt(proofEventId: String, requestId: PaykitPaymentRequest.ID, owner: String, identity: String) throws {
        var current = try load()
        guard let index = current.receipts.firstIndex(where: {
            $0.wallet == owner && $0.identity == identity && $0.requestId == requestId && $0.proofEventId == proofEventId && $0.verified
        }) else { return }
        current.receipts[index].verified = false
        try save(current)
    }

    private func currentIdentity(sdk: PaykitSdkService = .shared) async throws -> String? {
        guard let status = try await sdk.identityStatus(), status.capability == .privateLinkCapable else { return nil }
        return status.publicKey.flatMap(PubkyPublicKeyFormat.normalized)
    }
}

private extension PaykitUsdtPaymentService.Attempt {
    var bindingState: Self {
        var value = self
        value.proof = nil
        value.proofQueued = false
        value.paymentStarted = false
        return value
    }
}
