import Combine
import Foundation
import LDKNode
import Paykit

protocol PaykitAllowanceSdkHandling: Sendable {
    func linkedPeers() async throws -> [LinkedPeerRecord]
    func listAllowances(filter: Paykit.AllowanceFilter) async throws -> [Paykit.AllowanceRecord]
    func proposeAllowance(
        counterparty: String,
        counterpartyReceiverPath: String,
        localRole: Paykit.AllowanceLocalRole,
        terms: Paykit.AllowanceTerms
    ) async throws -> Paykit.AllowanceRecord
    func acceptAllowance(counterparty: String, counterpartyReceiverPath: String, allowanceId: String) async throws -> Paykit.AllowanceRecord
    func rejectAllowance(counterparty: String, counterpartyReceiverPath: String, allowanceId: String) async throws -> Paykit.AllowanceRecord
    func endAllowance(counterparty: String, counterpartyReceiverPath: String, allowanceId: String) async throws -> Paykit.AllowanceRecord
    @discardableResult
    func receivePrivateMessages(counterparty: String, counterpartyReceiverPath: String) async throws -> Paykit.PrivateStreamIntakeReport
    @discardableResult
    func processOutboundPrivateMessages(counterparty: String, counterpartyReceiverPath: String) async throws -> Paykit.OutboundPrivateSendReport
    func allowanceAccountingState() async throws -> Paykit.AllowanceAccountingState?
    func reconcileAllowanceAccounting(_ reconciliation: Paykit.AllowanceAccountingReconciliation) async throws -> Paykit.AllowanceAccountingState
    func evaluateAllowanceCandidates(scope: Paykit.PaymentRequestScope, trustedTime: String) async throws -> [Paykit.AllowanceCandidate]
    func acceptPaymentRequestAutomatically(
        scope: Paykit.PaymentRequestScope,
        selection: Paykit.AllowanceSelectionInput,
        checks: Paykit.PaymentExecutionChecks
    ) async throws -> Paykit.AllowanceAssociationRecord
    func reserveAutomaticPayment(
        occurrence: Paykit.PaymentOccurrence,
        expectedAssociationRevision: UInt64,
        checks: Paykit.PaymentExecutionChecks
    ) async throws -> Paykit.PaymentAttemptDecision
    func reserveManualPayment(occurrence: Paykit.PaymentOccurrence, checks: Paykit.PaymentExecutionChecks) async throws -> Paykit.PaymentAttemptDecision
    func beginPaymentExecution(attemptId: String, checks: Paykit.PaymentExecutionChecks) async throws -> Paykit.PaymentAttemptDecision
    @discardableResult
    func recordPaymentOutcome(_ report: Paykit.PaymentOutcomeReport) async throws -> Paykit.PaymentAttemptRecord
    @discardableResult
    func markPaymentManualOnly(occurrence: Paykit.PaymentOccurrence) async throws -> Paykit.PaymentOccurrenceRecord
}

extension PaykitSdkService: PaykitAllowanceSdkHandling {}

/// Local Allowance state kept per identity: USD labels, the grouping of one grant across a contact's links,
/// and the execution journal that restart recovery reads. The SDK ledger stays authoritative for admission.
struct PaykitAllowanceLocalState: Codable, Equatable {
    struct Group: Codable, Equatable {
        let id: String
        let counterparty: String
        let limits: PaykitAllowanceLimits
        var allowanceIds: [String]
        let createdAt: Date
    }

    enum Stage: String, Codable {
        case prepared
        case submitted
        case sending
        case sent
        case succeeded
        case failed
        case unknown
    }

    struct JournalEntry: Codable, Equatable {
        let attemptId: String
        let isAutomatic: Bool
        let requestId: PaykitPaymentRequest.ID
        let allowanceId: String?
        let amountSats: UInt64
        let paymentEndpointIdentifier: String
        var paymentHash: String?
        var onchainAddress: String?
        var transactionId: String?
        var stage: Stage
        let createdAt: Date
    }

    var groups: [Group] = []
    var journal: [JournalEntry] = []
    var presentedProposalIds: Set<String> = []
    var notifiedRequestIds: Set<String> = []
    var lastTrustedTime: Date?

    func group(containing allowanceId: String) -> Group? {
        groups.first { $0.allowanceIds.contains(allowanceId) }
    }
}

protocol PaykitAllowanceStoring: Sendable {
    func load(identity: String) throws -> PaykitAllowanceLocalState
    func save(_ state: PaykitAllowanceLocalState, identity: String) throws
}

struct PaykitAllowanceKeychainStore: PaykitAllowanceStoring {
    private typealias Stored = [String: PaykitAllowanceLocalState]

    func load(identity: String) throws -> PaykitAllowanceLocalState {
        try loadAll()[identity] ?? PaykitAllowanceLocalState()
    }

    func save(_ state: PaykitAllowanceLocalState, identity: String) throws {
        var all = try loadAll()
        all[identity] = state
        try Keychain.upsert(key: .paykitAllowanceState, data: JSONEncoder().encode(all))
    }

    private func loadAll() throws -> Stored {
        guard let data = try Keychain.load(key: .paykitAllowanceState) else { return [:] }
        do {
            return try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            Logger.warn("Discarding invalid Paykit allowance state: \(error)", context: "PaykitAllowance")
            return [:]
        }
    }
}

/// The side effects of paying one request, behind a protocol so the admission logic is testable without a node.
protocol PaykitAllowancePaying: Sendable {
    func resolve(_ request: PaykitPaymentRequest, eligibleIdentifiers: [String]) async throws -> PrivatePaykitAllowancePayment?
    func consumePaymentList(publicKey: String, context: PrivatePaykitPaymentContext) async throws
    func prepareProof(_ request: PaykitPaymentRequest, paymentEndpointIdentifier: String, allowanceId: String?) async throws
    func associateLightningPayment(_ request: PaykitPaymentRequest, paymentHash: String) async throws
    func markOnchainPaymentStarted(_ request: PaykitPaymentRequest, address: String) async throws
    func payLightning(bolt11: String, sats: UInt64?) async throws
    func payOnchain(address: String, sats: UInt64) async throws -> String
    func completeOnchainPayment(_ request: PaykitPaymentRequest, txid: String, paymentEndpointIdentifier: String) async
    func failLightningPayment(paymentHash: String) async
    func cancelProofPreparation(_ request: PaykitPaymentRequest) async
}

struct PaykitAllowanceLivePayer: PaykitAllowancePaying {
    func resolve(_ request: PaykitPaymentRequest, eligibleIdentifiers: [String]) async throws -> PrivatePaykitAllowancePayment? {
        try await PrivatePaykitService.shared.resolveAllowancePayment(request, eligibleIdentifiers: eligibleIdentifiers)
    }

    func consumePaymentList(publicKey: String, context: PrivatePaykitPaymentContext) async throws {
        try await PrivatePaykitService.shared.consumePrivatePaymentList(publicKey: publicKey, context: context)
    }

    func prepareProof(_ request: PaykitPaymentRequest, paymentEndpointIdentifier: String, allowanceId: String?) async throws {
        guard let kind = PaykitPaymentProofKind(paymentEndpointIdentifier: paymentEndpointIdentifier) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        try await PaykitPaymentProofService.shared.prepare(
            request: request,
            paymentEndpointIdentifier: paymentEndpointIdentifier,
            kind: kind,
            allowanceId: allowanceId
        )
    }

    func associateLightningPayment(_ request: PaykitPaymentRequest, paymentHash: String) async throws {
        try await PaykitPaymentProofService.shared.associateLightningPayment(request, paymentHash: paymentHash)
    }

    func markOnchainPaymentStarted(_ request: PaykitPaymentRequest, address: String) async throws {
        try await PaykitPaymentProofService.shared.markOnchainPaymentStarted(request, address: address)
    }

    func payLightning(bolt11: String, sats: UInt64?) async throws {
        _ = try await LightningService.shared.send(bolt11: bolt11, sats: sats)
    }

    func payOnchain(address: String, sats: UInt64) async throws -> String {
        let feeRate = await (try? CoreService.shared.blocktank.fees(refresh: false))?.mid ?? 2
        return try await String(describing: LightningService.shared.send(address: address, sats: sats, satsPerVbyte: max(feeRate, 1)))
    }

    func completeOnchainPayment(_ request: PaykitPaymentRequest, txid: String, paymentEndpointIdentifier: String) async {
        await PaykitPaymentProofService.shared.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: paymentEndpointIdentifier)
    }

    func failLightningPayment(paymentHash: String) async {
        await PaykitPaymentProofService.shared.failLightningPayment(paymentHash: paymentHash)
    }

    func cancelProofPreparation(_ request: PaykitPaymentRequest) async {
        await PaykitPaymentProofService.shared.cancelPreparation(request)
    }
}

enum PaykitAllowanceEvent: Equatable {
    case paidAutomatically(counterparty: String, amountSats: UInt64, paymentId: String)
    case limitReached(counterparty: String, amountSats: UInt64)
    case ledgerChanged
}

enum PaykitAllowanceAutoPayResult: Equatable {
    /// No accepted Allowance covers the request's link.
    case notCovered
    /// An Allowance exists but this request stays on the manual flow (over a limit, ended, no payable endpoint).
    case manual
    /// The payment was handed to the node; the outcome arrives through the payment events.
    case started
    case completed
    /// The payee has not published a payment list newer than the one last paid; the next refresh tries again.
    case deferred
}

enum PaykitAllowanceManualPaymentError: LocalizedError {
    case alreadyRecorded

    var errorDescription: String? {
        t("subscriptions__allowance_payment_in_progress")
    }
}

/// Runs Allowance admission for incoming requests through the SDK: evaluate, capacity preflight, automatic
/// Acceptance, reserve, begin, pay, record the outcome. The wallet journals every attempt before handoff so a
/// restart resolves it from the node instead of paying again.
actor PaykitAllowanceExecutor {
    static let shared = PaykitAllowanceExecutor()

    private static let eventSubject = PassthroughSubject<PaykitAllowanceEvent, Never>()

    nonisolated static var eventPublisher: AnyPublisher<PaykitAllowanceEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    private let sdk: any PaykitAllowanceSdkHandling
    private let store: any PaykitAllowanceStoring
    private let payer: any PaykitAllowancePaying
    private let lightningLookup: any PaykitLightningPaymentProofLookingUp
    private let now: @Sendable () -> Date
    private var inFlightRequestIds = Set<PaykitPaymentRequest.ID>()
    private(set) var activeIdentity: String?

    init(
        sdk: any PaykitAllowanceSdkHandling = PaykitSdkService.shared,
        store: any PaykitAllowanceStoring = PaykitAllowanceKeychainStore(),
        payer: any PaykitAllowancePaying = PaykitAllowanceLivePayer(),
        lightningLookup: any PaykitLightningPaymentProofLookingUp = PaykitLightningPaymentProofLookup(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sdk = sdk
        self.store = store
        self.payer = payer
        self.lightningLookup = lightningLookup
        self.now = now
    }

    func activate(identity: String?) {
        activeIdentity = identity
    }

    // MARK: Local state

    func localState(identity: String) -> PaykitAllowanceLocalState {
        (try? store.load(identity: identity)) ?? PaykitAllowanceLocalState()
    }

    func updateLocalState(identity: String, _ change: (inout PaykitAllowanceLocalState) -> Void) {
        var state = localState(identity: identity)
        change(&state)
        do {
            try store.save(state, identity: identity)
        } catch {
            Logger.warn("Failed to save Paykit allowance state: \(error)", context: "PaykitAllowance")
        }
    }

    func isHandling(_ requestId: PaykitPaymentRequest.ID) -> Bool {
        inFlightRequestIds.contains(requestId)
    }

    /// Trusted time for eligibility: the real clock, never earlier than the last value given to the SDK,
    /// because the SDK refuses a watermark that moves backwards.
    func trustedTime(identity: String) -> String {
        var date = now()
        updateLocalState(identity: identity) { state in
            if let last = state.lastTrustedTime, last > date {
                date = last
            }
            state.lastTrustedTime = date
        }
        return PaykitAllowanceTime.format(date)
    }

    // MARK: Ledger

    /// Brings the SDK ledger to a reconciled state. A wallet with no ledger attests an empty history: it has never
    /// paid through an Allowance. After a restore, outcomes come from the journal and the node.
    @discardableResult
    func ensureReconciled(identity: String) async throws -> Paykit.AllowanceAccountingState {
        let current = try await sdk.allowanceAccountingState()
        if let current, !current.requiresReconciliation {
            return current
        }

        let history = current?.history ?? Paykit.AllowanceAccountingHistory(associations: [], occurrences: [], watermarks: [])
        var outcomes: [Paykit.PaymentOutcomeReport] = []
        for attempt in history.occurrences.flatMap(\.attempts) {
            if let outcome = await verifiedOutcome(for: attempt, identity: identity) {
                outcomes.append(Paykit.PaymentOutcomeReport(attemptId: attempt.attemptId, outcome: outcome))
            }
        }
        let reconciled = try await sdk.reconcileAllowanceAccounting(
            Paykit.AllowanceAccountingReconciliation(
                expectedRevision: current?.revision,
                history: history,
                outcomes: outcomes,
                trustedTime: trustedTime(identity: identity)
            )
        )
        Logger.info("Reconciled Paykit allowance accounting with \(outcomes.count) verified outcomes", context: "PaykitAllowance")
        return reconciled
    }

    /// Resolves attempts a crash or kill left open. Prepared attempts never got a handoff and are released;
    /// submitted ones are settled from the node. Nothing is paid again.
    func recover(identity: String) async {
        do {
            // No ledger means nothing was ever admitted. Creating one here would also end the rc55 storage layout.
            guard try await sdk.allowanceAccountingState() != nil else { return }
            let state = try await ensureReconciled(identity: identity)
            for attempt in state.history.occurrences.flatMap(\.attempts) {
                switch attempt.status {
                case .prepared:
                    guard attempt.epoch == state.epoch else { continue }
                    try await record(attemptId: attempt.attemptId, outcome: .failed, identity: identity)
                case .submitted, .unknown:
                    guard let outcome = await verifiedOutcome(for: attempt, identity: identity) else {
                        if attempt.status == .submitted {
                            try await record(attemptId: attempt.attemptId, outcome: .unknown, identity: identity)
                        }
                        continue
                    }
                    try await record(attemptId: attempt.attemptId, outcome: outcome, identity: identity)
                case .succeeded, .failed:
                    continue
                }
            }
        } catch {
            Logger.warn("Paykit allowance recovery failed: \(error)", context: "PaykitAllowance")
        }
    }

    private func verifiedOutcome(for attempt: Paykit.PaymentAttemptRecord, identity: String) async -> Paykit.PaymentOutcome? {
        switch attempt.status {
        case .prepared:
            return .failed
        case .succeeded, .failed:
            return nil
        case .submitted, .unknown:
            break
        }

        guard let entry = localState(identity: identity).journal.first(where: { $0.attemptId == attempt.attemptId }) else {
            return nil
        }
        switch entry.stage {
        case .prepared, .submitted:
            // The journal is written before the node call, so no payment left this wallet.
            return .failed
        case .succeeded:
            return .succeeded
        case .failed:
            return .failed
        case .sending, .sent, .unknown:
            break
        }

        if let paymentHash = entry.paymentHash {
            switch await lightningLookup.status(paymentHash: paymentHash) {
            case .succeeded:
                return .succeeded
            case .failed:
                return .failed
            case .pending, .unknown:
                return nil
            }
        }
        return entry.transactionId == nil ? nil : .succeeded
    }

    private func record(attemptId: String, outcome: Paykit.PaymentOutcome, identity: String) async throws {
        try await sdk.recordPaymentOutcome(Paykit.PaymentOutcomeReport(attemptId: attemptId, outcome: outcome))
        updateLocalState(identity: identity) { state in
            guard let index = state.journal.firstIndex(where: { $0.attemptId == attemptId }) else { return }
            switch outcome {
            case .succeeded: state.journal[index].stage = .succeeded
            case .failed: state.journal[index].stage = .failed
            case .unknown: state.journal[index].stage = .unknown
            }
        }
        Self.eventSubject.send(.ledgerChanged)
    }

    func automaticAttempts() async -> [PaykitAllowanceCapacity.Attempt] {
        guard let state = try? await sdk.allowanceAccountingState() else { return [] }
        return PaykitAllowanceCapacity.attempts(from: state.history)
    }

    func succeededAutomaticPayments(identity: String) -> [PaykitAllowanceLocalState.JournalEntry] {
        localState(identity: identity).journal.filter { $0.isAutomatic && $0.stage == .succeeded }
    }

    // MARK: Automatic payment

    func autoPay(
        _ request: PaykitPaymentRequest,
        allowances: [PaykitAllowance],
        identity: String
    ) async -> PaykitAllowanceAutoPayResult {
        guard request.direction == .incoming,
              request.billingPeriod == nil,
              request.lifecycleState == .proposed,
              !inFlightRequestIds.contains(request.id),
              allowances.contains(where: {
                  $0.isAllower && $0.lifecycleState == .accepted &&
                      PubkyPublicKeyFormat.matches($0.counterparty, request.counterparty) &&
                      $0.counterpartyReceiverPath == request.counterpartyReceiverPath
              })
        else { return .notCovered }

        inFlightRequestIds.insert(request.id)
        defer { inFlightRequestIds.remove(request.id) }

        do {
            try await ensureReconciled(identity: identity)
            return try await admitAndPay(request, allowances: allowances, identity: identity)
        } catch {
            Logger.warn("Automatic allowance payment stayed manual: \(error)", context: "PaykitAllowance")
            return .manual
        }
    }

    private func admitAndPay(
        _ request: PaykitPaymentRequest,
        allowances: [PaykitAllowance],
        identity: String
    ) async throws -> PaykitAllowanceAutoPayResult {
        let scope = Paykit.PaymentRequestScope(
            counterparty: request.counterparty,
            counterpartyReceiverPath: request.counterpartyReceiverPath,
            paymentRequestId: request.paymentRequestId
        )
        let selectionTime = trustedTime(identity: identity)
        let candidates = try await sdk.evaluateAllowanceCandidates(scope: scope, trustedTime: selectionTime)
        guard let candidate = candidates.first(where: { $0.blocked == nil }),
              let allowance = allowances.first(where: { $0.allowanceId == candidate.allowanceId })
        else {
            let reasons = candidates.compactMap { $0.blocked.map { String(describing: $0) } }
            Logger.info("No eligible allowance for an incoming request: \(reasons)", context: "PaykitAllowance")
            return .manual
        }

        let attempts = await automaticAttempts()
        guard PaykitAllowanceCapacity.fits(amountSats: request.amountSats, allowance: allowance, attempts: attempts, now: now()) else {
            Logger.info("Allowance monthly limit reached; the request stays on the manual flow", context: "PaykitAllowance")
            notifyLimitReached(request, identity: identity)
            return .manual
        }

        let resolvedPayment: PrivatePaykitAllowancePayment?
        do {
            resolvedPayment = try await payer.resolve(request, eligibleIdentifiers: candidate.eligiblePaymentEndpointIdentifiers)
        } catch PaykitAllowanceError.paymentListPending {
            Logger.info("Deferred an incoming request until the payee publishes a new payment list", context: "PaykitAllowance")
            return .deferred
        }
        guard let payment = resolvedPayment else {
            Logger.info("No payable private endpoint for an allowance payment; leaving it manual", context: "PaykitAllowance")
            return .manual
        }

        let endpointIdentifier = payment.endpoint.methodId.rawValue
        let association = try await sdk.acceptPaymentRequestAutomatically(
            scope: scope,
            selection: Paykit.AllowanceSelectionInput(allowanceId: candidate.allowanceId, expectedRevision: nil, trustedTime: selectionTime),
            checks: checks(request, endpointIdentifier: endpointIdentifier, trustedTime: selectionTime)
        )
        try? await sdk.processOutboundPrivateMessages(counterparty: request.counterparty, counterpartyReceiverPath: request.counterpartyReceiverPath)

        let occurrence = Paykit.PaymentOccurrence(request: scope, billingPeriod: nil)
        let reservation = try await sdk.reserveAutomaticPayment(
            occurrence: occurrence,
            expectedAssociationRevision: association.revisions.last?.revision ?? 1,
            checks: checks(request, endpointIdentifier: endpointIdentifier, trustedTime: trustedTime(identity: identity))
        )
        guard case let .ready(prepared) = reservation else {
            if case let .blocked(reason) = reservation {
                Logger.info("Allowance reservation blocked: \(reason)", context: "PaykitAllowance")
            }
            try? await sdk.markPaymentManualOnly(occurrence: occurrence)
            notifyLimitReached(request, identity: identity)
            return .manual
        }

        journal(
            PaykitAllowanceLocalState.JournalEntry(
                attemptId: prepared.attemptId,
                isAutomatic: true,
                requestId: request.id,
                allowanceId: prepared.allowanceId,
                amountSats: request.amountSats,
                paymentEndpointIdentifier: endpointIdentifier,
                paymentHash: payment.lightningPaymentHash,
                onchainAddress: payment.endpoint.methodId.onchainNetwork == nil ? nil : payment.endpoint.value,
                transactionId: nil,
                stage: .prepared,
                createdAt: now()
            ),
            identity: identity
        )

        // Begin fetches nothing, so pull the link first: an End or a cancellation must be seen before the handoff.
        try? await sdk.receivePrivateMessages(counterparty: request.counterparty, counterpartyReceiverPath: request.counterpartyReceiverPath)
        let handoff = try await sdk.beginPaymentExecution(
            attemptId: prepared.attemptId,
            checks: checks(request, endpointIdentifier: endpointIdentifier, trustedTime: trustedTime(identity: identity))
        )
        guard case let .ready(submitted) = handoff else {
            try await record(attemptId: prepared.attemptId, outcome: .failed, identity: identity)
            return .manual
        }
        setStage(.submitted, attemptId: submitted.attemptId, identity: identity)

        do {
            try await payer.consumePaymentList(publicKey: request.counterparty, context: payment.context)
            try await payer.prepareProof(request, paymentEndpointIdentifier: endpointIdentifier, allowanceId: submitted.allowanceId)
        } catch {
            await payer.cancelProofPreparation(request)
            try await record(attemptId: submitted.attemptId, outcome: .failed, identity: identity)
            throw error
        }

        if let paymentHash = payment.lightningPaymentHash {
            return try await payLightning(request, payment: payment, paymentHash: paymentHash, attemptId: submitted.attemptId, identity: identity)
        }
        return try await payOnchain(request, payment: payment, attemptId: submitted.attemptId, identity: identity)
    }

    private func payLightning(
        _ request: PaykitPaymentRequest,
        payment: PrivatePaykitAllowancePayment,
        paymentHash: String,
        attemptId: String,
        identity: String
    ) async throws -> PaykitAllowanceAutoPayResult {
        do {
            try await payer.associateLightningPayment(request, paymentHash: paymentHash)
        } catch {
            await payer.cancelProofPreparation(request)
            try await record(attemptId: attemptId, outcome: .failed, identity: identity)
            throw error
        }

        setStage(.sending, attemptId: attemptId, identity: identity)
        do {
            try await payer.payLightning(bolt11: payment.endpoint.value, sats: payment.lightningInvoiceHasAmount ? nil : request.amountSats)
        } catch {
            // LDK rejected the payment before routing it.
            await payer.failLightningPayment(paymentHash: paymentHash)
            try await record(attemptId: attemptId, outcome: .failed, identity: identity)
            throw error
        }
        setStage(.sent, attemptId: attemptId, identity: identity)
        Logger.info("Handed an allowance payment to the node", context: "PaykitAllowance")
        return .started
    }

    private func payOnchain(
        _ request: PaykitPaymentRequest,
        payment: PrivatePaykitAllowancePayment,
        attemptId: String,
        identity: String
    ) async throws -> PaykitAllowanceAutoPayResult {
        let address = payment.endpoint.value
        do {
            try await payer.markOnchainPaymentStarted(request, address: address)
        } catch {
            await payer.cancelProofPreparation(request)
            try await record(attemptId: attemptId, outcome: .failed, identity: identity)
            throw error
        }

        setStage(.sending, attemptId: attemptId, identity: identity)
        let txid: String
        do {
            txid = try await payer.payOnchain(address: address, sats: request.amountSats)
        } catch {
            if PaykitPaymentProofService.isDefiniteOnchainPreBroadcastFailure(error) {
                await payer.cancelProofPreparation(request)
                try await record(attemptId: attemptId, outcome: .failed, identity: identity)
            } else {
                try await record(attemptId: attemptId, outcome: .unknown, identity: identity)
            }
            throw error
        }

        updateLocalState(identity: identity) { state in
            guard let index = state.journal.firstIndex(where: { $0.attemptId == attemptId }) else { return }
            state.journal[index].transactionId = txid
        }
        await payer.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: payment.endpoint.methodId.rawValue)
        try await record(attemptId: attemptId, outcome: .succeeded, identity: identity)
        Self.eventSubject.send(.paidAutomatically(counterparty: request.counterparty, amountSats: request.amountSats, paymentId: txid))
        return .completed
    }

    /// Called from the node's payment events for every outbound Lightning payment; only journaled ones are Allowance work.
    func lightningPaymentSettled(paymentHash: String, succeeded: Bool) async {
        guard let identity = activeIdentity else { return }
        let entries = localState(identity: identity).journal.filter {
            $0.paymentHash?.caseInsensitiveCompare(paymentHash) == .orderedSame &&
                [.sending, .sent, .unknown, .submitted].contains($0.stage)
        }
        for entry in entries {
            do {
                try await record(attemptId: entry.attemptId, outcome: succeeded ? .succeeded : .failed, identity: identity)
                if succeeded, entry.isAutomatic {
                    Self.eventSubject.send(
                        .paidAutomatically(counterparty: entry.requestId.counterparty, amountSats: entry.amountSats, paymentId: paymentHash.lowercased())
                    )
                }
            } catch {
                Logger.warn("Failed to record an allowance payment outcome: \(error)", context: "PaykitAllowance")
            }
        }
    }

    // MARK: Manual payments

    /// Reports a user-approved payment of an incoming request to the shared ledger before it leaves the wallet.
    /// Throws `alreadyRecorded` when another live attempt exists for the request, so the same request is never paid twice.
    func beginManualPayment(_ request: PaykitPaymentRequest, paymentEndpointIdentifier: String) async throws -> String? {
        guard let identity = activeIdentity, request.billingPeriod == nil, request.direction == .incoming else { return nil }
        do {
            try await ensureReconciled(identity: identity)
            let scope = Paykit.PaymentRequestScope(
                counterparty: request.counterparty,
                counterpartyReceiverPath: request.counterpartyReceiverPath,
                paymentRequestId: request.paymentRequestId
            )
            let occurrence = Paykit.PaymentOccurrence(request: scope, billingPeriod: nil)
            let decision = try await sdk.reserveManualPayment(
                occurrence: occurrence,
                checks: checks(request, endpointIdentifier: paymentEndpointIdentifier, trustedTime: trustedTime(identity: identity))
            )
            guard case let .ready(prepared) = decision else {
                if case .blocked(.paymentAlreadyRecorded) = decision {
                    throw PaykitAllowanceManualPaymentError.alreadyRecorded
                }
                Logger.info("Manual payment not reported to the allowance ledger: \(decision)", context: "PaykitAllowance")
                return nil
            }
            journal(
                PaykitAllowanceLocalState.JournalEntry(
                    attemptId: prepared.attemptId,
                    isAutomatic: false,
                    requestId: request.id,
                    allowanceId: nil,
                    amountSats: request.amountSats,
                    paymentEndpointIdentifier: paymentEndpointIdentifier,
                    paymentHash: nil,
                    onchainAddress: nil,
                    transactionId: nil,
                    stage: .prepared,
                    createdAt: now()
                ),
                identity: identity
            )
            let handoff = try await sdk.beginPaymentExecution(
                attemptId: prepared.attemptId,
                checks: checks(request, endpointIdentifier: paymentEndpointIdentifier, trustedTime: trustedTime(identity: identity))
            )
            guard case .ready = handoff else {
                try await record(attemptId: prepared.attemptId, outcome: .failed, identity: identity)
                return nil
            }
            setStage(.submitted, attemptId: prepared.attemptId, identity: identity)
            Logger.info("Reported a manual payment to the allowance ledger", context: "PaykitAllowance")
            return prepared.attemptId
        } catch let error as PaykitAllowanceManualPaymentError {
            throw error
        } catch {
            Logger.warn("Manual payment not reported to the allowance ledger: \(error)", context: "PaykitAllowance")
            return nil
        }
    }

    func manualLightningPaymentSent(attemptId: String, paymentHash: String) {
        guard let identity = activeIdentity else { return }
        updateLocalState(identity: identity) { state in
            guard let index = state.journal.firstIndex(where: { $0.attemptId == attemptId }) else { return }
            state.journal[index].paymentHash = paymentHash.lowercased()
            state.journal[index].stage = .sent
        }
    }

    func finishManualPayment(attemptId: String, outcome: Paykit.PaymentOutcome, transactionId: String? = nil) async {
        guard let identity = activeIdentity else { return }
        if let transactionId {
            updateLocalState(identity: identity) { state in
                guard let index = state.journal.firstIndex(where: { $0.attemptId == attemptId }) else { return }
                state.journal[index].transactionId = transactionId
            }
        }
        do {
            try await record(attemptId: attemptId, outcome: outcome, identity: identity)
        } catch {
            Logger.warn("Failed to record a manual payment outcome: \(error)", context: "PaykitAllowance")
        }
    }

    // MARK: Helpers

    private func checks(_ request: PaykitPaymentRequest, endpointIdentifier: String, trustedTime: String) throws -> Paykit.PaymentExecutionChecks {
        try Paykit.PaymentExecutionChecks(
            trustedTime: trustedTime,
            paymentEndpointIdentifier: endpointIdentifier,
            actualAmount: Paykit.AccountingAmount(value: request.amountValue, asset: PaykitIssuerInterop.bitcoinAsset),
            endpointCurrent: true,
            localEnabled: true,
            recurrenceEligible: true
        )
    }

    private func journal(_ entry: PaykitAllowanceLocalState.JournalEntry, identity: String) {
        updateLocalState(identity: identity) { state in
            state.journal.removeAll { $0.attemptId == entry.attemptId }
            state.journal.append(entry)
            if state.journal.count > 200 {
                state.journal.removeFirst(state.journal.count - 200)
            }
        }
    }

    private func setStage(_ stage: PaykitAllowanceLocalState.Stage, attemptId: String, identity: String) {
        updateLocalState(identity: identity) { state in
            guard let index = state.journal.firstIndex(where: { $0.attemptId == attemptId }) else { return }
            state.journal[index].stage = stage
        }
    }

    private func notifyLimitReached(_ request: PaykitPaymentRequest, identity: String) {
        var isNew = false
        updateLocalState(identity: identity) { state in
            isNew = state.notifiedRequestIds.insert(request.paymentRequestId).inserted
        }
        if isNew {
            Self.eventSubject.send(.limitReached(counterparty: request.counterparty, amountSats: request.amountSats))
        }
    }
}
