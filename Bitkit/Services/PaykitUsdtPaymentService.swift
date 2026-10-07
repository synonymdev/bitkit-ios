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
    private(set) var resumableRequests: Set<PaykitPaymentRequest.ID> = []

    private nonisolated(unsafe) static let stateChanged = PassthroughSubject<Void, Never>()
    nonisolated static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        stateChanged.eraseToAnyPublisher()
    }

    func backupSnapshot() throws -> PaykitUsdtStateBackup {
        let state = try load()
        return PaykitUsdtStateBackup(attempts: state.attempts.map(PaykitUsdtStateBackup.Attempt.init),
                                     receipts: state.receipts.map(PaykitUsdtStateBackup.Receipt.init))
    }

    func restoreBackup(_ backup: PaykitUsdtStateBackup) throws {
        var state = try load()
        for attempt in try backup.attempts.map({ try $0.restored() }) {
            if let index = state.attempts.firstIndex(where: { $0.wallet == attempt.wallet && $0.quoteId == attempt.quoteId }) {
                state.attempts[index].paymentStarted = state.attempts[index].paymentStarted || attempt.paymentStarted
                state.attempts[index].proof = state.attempts[index].proof ?? attempt.proof
            } else {
                state.attempts.append(attempt)
            }
        }
        // Restored delivery queues may be older than local payment evidence; reconciliation deduplicates proofs.
        for index in state.attempts.indices {
            state.attempts[index].proofQueued = false
        }
        for receipt in try backup.receipts.map({ try $0.restored() }) where !state.receipts.contains(where: {
            $0.wallet == receipt.wallet && $0.paymentId == receipt.paymentId
        }) {
            state.receipts.append(receipt)
        }
        try save(state)
    }

    func send(_ quote: UsdtQuote, context: ContactPaymentContext, paymentTerms: PaykitRequestPricing.Payment?,
              wallet: UsdtWalletManager, authorize: () async throws -> Void) async throws
    {
        try setPaymentStarted(quoteId: quote.id, started: true)
        do {
            try await authorize()
            try Task.checkCancellation()
            if let request = context.incomingPaymentRequest {
                guard !request.isExpired(at: Date()),
                      request.acceptsPayment(PaykitAmount(asset: .usdt, atomic: quote.amount), paymentTerms: paymentTerms)
                else { throw PaykitPaymentRequestError.amountMismatch }
            }
        } catch {
            try? setPaymentStarted(quoteId: quote.id, started: false)
            throw error
        }
        do {
            try await wallet.send(quote)
        } catch {
            // Core persists signed operations before broadcast. Only this completed send can establish non-submission.
            if !(error is CancellationError), await (try? wallet.storedTransfer(quote.id) == nil) == true {
                try? setPaymentStarted(quoteId: quote.id, started: false)
            }
            throw error
        }
    }

    private func setPaymentStarted(quoteId: String, started: Bool) throws {
        var state = try load()
        guard let index = state.attempts.firstIndex(where: {
            $0.quoteId == quoteId && $0.wallet == activeWallet && $0.identity == activeIdentity
        }) else { throw PaykitPaymentRequestError.requestUnavailable }
        state.attempts[index].paymentStarted = started
        if started, let id = state.attempts[index].requestId { resumableRequests.remove(id) }
        try save(state)
    }

    private func load() throws -> State {
        guard let data = try Keychain.load(key: .paykitUsdtPayments) else { return State() }
        return try JSONDecoder().decode(State.self, from: data)
    }

    private func save(_ state: State) throws {
        try Keychain.upsert(key: .paykitUsdtPayments, data: JSONEncoder().encode(state))
        publish(state)
        Self.stateChanged.send()
    }

    private func publish(_ state: State) {
        attempts = state.attempts.filter { $0.wallet == activeWallet && $0.identity == activeIdentity }
        receipts = state.receipts.filter { $0.wallet == activeWallet && $0.identity == activeIdentity }
    }

    func hasBinding(for requestId: PaykitPaymentRequest.ID) -> Bool {
        attempts.contains { $0.requestId == requestId }
    }

    func paymentProtection(identity: String) throws
        -> (inFlight: Set<PaykitPaymentRequest.ID>, completed: [PaykitPaymentRequest.ID: PaykitPaymentProofKind])
    {
        var inFlight = Set<PaykitPaymentRequest.ID>()
        var completed: [PaykitPaymentRequest.ID: PaykitPaymentProofKind] = [:]
        for attempt in try load().attempts where PubkyPublicKeyFormat.matches(attempt.identity, identity) && !attempt.proofQueued {
            guard let id = attempt.requestId,
                  attempt.wallet != activeWallet || !PubkyPublicKeyFormat.matches(activeIdentity, identity) || !resumableRequests.contains(id)
            else { continue }
            if attempt.paymentStarted || attempt.proof != nil { inFlight.insert(id) }
            if attempt.proof != nil { completed[id] = .usdt }
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
        if !binding.conversionQuoteId.isEmpty { message["conversion_quote_id"] = binding.conversionQuoteId }
        guard try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]).count <= PaykitSdkService.maximumMessageBytes
        else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
    }

    func prepare(context: ContactPaymentContext, quote: UsdtQuote, wallet: UsdtWalletManager,
                 amount: PaykitAmount?, paymentTerms: PaykitRequestPricing.Payment?) async throws
    {
        guard !preparing else { throw PaykitPaymentRequestError.operationInProgress }
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
                  request.acceptsPayment(payment, paymentTerms: paymentTerms)
            else { throw PaykitPaymentRequestError.amountMismatch }
        }
        let owner = wallet.address.lowercased()
        activeWallet = owner
        activeIdentity = identity
        if let previous = try load().attempts.first(where: {
            $0.wallet == owner && $0.identity == identity && request != nil && $0.requestId == request?.id
        }), previous.quoteId != quote.id {
            // Only an unstarted or definitively unexecuted payment may be replaced by a fresh quote.
            let transfer = try await wallet.storedTransfer(previous.quoteId)
            guard (transfer == nil && !previous.paymentStarted) || transfer?.status == .failed || transfer?.status == .replaced else {
                throw PaykitPaymentRequestError.operationInProgress
            }
        }
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
        if let binding { try Self.validateProofSize(binding: binding) }
        let attempt = Attempt(quoteId: quote.id, wallet: owner, identity: identity, contact: context.publicKey,
                              requestId: request?.id, binding: binding, billingPeriod: request?.billingPeriod)
        var state = try load()
        state.attempts.removeAll {
            $0.wallet == owner && $0.identity == identity && ($0.quoteId == quote.id || (request != nil && $0.requestId == request?.id))
        }
        state.attempts.append(attempt)
        try save(state)
    }

    func reconcile(wallet: UsdtWalletManager) async {
        guard !reconciling, wallet.isConfigured else { return }
        reconciling = true
        defer { reconciling = false }
        do {
            guard let identity = try await currentIdentity() else { return }
            _ = try await wallet.paymentEndpoint()
            let owner = wallet.address.lowercased()
            activeWallet = owner
            activeIdentity = identity
            let state = try load()
            publish(state)
            var resumable: [Attempt] = []
            for attempt in state.attempts where attempt.wallet == owner && attempt.identity == identity {
                guard attempt.requestId != nil else { continue }
                let transfer = try await wallet.storedTransfer(attempt.quoteId)
                if (transfer == nil && !attempt.paymentStarted) || transfer?.status == .failed || transfer?
                    .status == .replaced { resumable.append(attempt) }
            }
            guard activeWallet == owner, activeIdentity == identity else { return }
            let currentAttempts = try load().attempts
            resumableRequests = Set(resumable.filter { currentAttempts.contains($0) }.compactMap(\.requestId))
            for attempt in state.attempts where attempt.wallet == owner && attempt.identity == identity && !attempt.proofQueued {
                guard let requestId = attempt.requestId, let binding = attempt.binding else { continue }
                let transfer = try await wallet.storedTransfer(attempt.quoteId)
                guard attempt.proof != nil || transfer?.status == .confirmed else { continue }
                let proof: Proof
                if let saved = attempt.proof { proof = saved }
                else {
                    guard let signed = try await wallet.paymentProof(quoteId: attempt.quoteId, binding: binding) else { continue }
                    proof = Proof(signed)
                    var current = try load()
                    guard let index = current.attempts.firstIndex(where: { $0.quoteId == attempt.quoteId && $0.wallet == owner }) else { continue }
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
                if await PaykitPaymentProofService.shared.submit(pending) {
                    var current = try load()
                    if let index = current.attempts.firstIndex(where: { $0.quoteId == attempt.quoteId && $0.wallet == owner }) {
                        current.attempts[index].proofQueued = true
                        try save(current)
                    }
                }
            }
            for record in try await PaykitSdkService.shared.paymentRequests() where record.localRole == .payee {
                for submission in record.paymentProofs
                    where submission.paymentEndpointIdentifier == PublicPaykitService.MethodId.usdtArbitrum.rawValue
                {
                    let request: PaykitPaymentRequest? = if let sdkPeriod = submission.billingPeriod {
                        if let subscription = PaykitSubscription(record: record), let period = PaykitBillingPeriod(sdkPeriod: sdkPeriod),
                           subscription.recurrence.contains(period)
                        {
                            PaykitPaymentRequest(subscription: subscription, billingPeriod: period,
                                                 lifecycleState: .proofSubmitted, paymentProofKind: .usdt, direction: .outgoing)
                        } else { nil }
                    } else { PaykitPaymentRequest(historyRecord: record, now: Date()) }
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
                        guard let payment = try await wallet.verifyPayment(binding: binding, proof: proof.coreValue) else {
                            try invalidateReceipt(proofEventId: submission.eventId, requestId: request.id, owner: owner, identity: identity)
                            continue
                        }
                        var current = try load()
                        guard !current.receipts.contains(where: {
                            $0.wallet == owner && $0.paymentId == payment.paymentId && ($0.identity != identity || $0.requestId != request.id)
                        }) else { continue }
                        let receivedAt = Date(timeIntervalSince1970: TimeInterval(payment.timestamp))
                        let terms = try request.payment(to: .usdt, at: receivedAt, quoteId: submission.conversionQuoteId)
                        let received = PaykitAmount(asset: .usdt, atomic: payment.amount)
                        current.receipts.removeAll { $0.wallet == owner && $0.identity == identity && $0.paymentId == payment.paymentId }
                        current.receipts.append(Receipt(wallet: owner, identity: identity, requestId: request.id,
                                                        paymentId: payment.paymentId, proofEventId: submission.eventId, verified: true,
                                                        transferId: payment.transferId, amount: received,
                                                        receivedAt: receivedAt, underpaid: received.atomic < terms.amount.atomic,
                                                        afterExpiry: !terms.isValid(at: receivedAt)))
                        try save(current)
                    } catch let error as UsdtError {
                        if case .InvalidPaymentProof = error {
                            try invalidateReceipt(proofEventId: submission.eventId, requestId: request.id, owner: owner, identity: identity)
                            continue
                        }
                        throw error
                    } catch is PaykitAmountError { continue }
                }
            }
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

    private func currentIdentity() async throws -> String? {
        guard let status = try await PaykitSdkService.shared.identityStatus(), status.capability == .privateLinkCapable else { return nil }
        return status.publicKey.flatMap(PubkyPublicKeyFormat.normalized)
    }
}
