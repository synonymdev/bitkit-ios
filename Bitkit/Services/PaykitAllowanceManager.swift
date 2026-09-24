import Foundation
import Observation
import Paykit

/// One grant as the user sees it. Bitkit proposes the same terms on each of a contact's links (their wallet, and
/// their Paykit Server folder for Locks and Shop requests), so one row can stand for several SDK Allowances.
struct PaykitAllowanceEntry: Identifiable, Hashable {
    let id: String
    let allowances: [PaykitAllowance]
    let limits: PaykitAllowanceLimits?

    var primary: PaykitAllowance {
        allowances.first { $0.counterpartyReceiverPath == PaykitReceiverPath.wallet } ?? allowances[0]
    }

    var counterparty: String { primary.counterparty }
    var role: PaykitAllowance.Role { primary.role }
    var perPaymentMaxSats: UInt64? { primary.perPaymentMaxSats }
    var monthlyLimitSats: UInt64? { primary.monthlyLimitSats }
    var canEnd: Bool { allowances.contains(where: \.canEnd) }

    func status(at now: Date) -> PaykitAllowance.Status {
        primary.status(at: now)
    }
}

enum PaykitAllowanceError: LocalizedError {
    case contactNotLinked
    case unavailable

    var errorDescription: String? {
        switch self {
        case .contactNotLinked: t("subscriptions__allowance_error_not_linked")
        case .unavailable: t("subscriptions__allowance_error_unavailable")
        }
    }
}

@Observable
@MainActor
final class PaykitAllowanceManager {
    private(set) var allowances: [PaykitAllowance] = []
    private(set) var localState = PaykitAllowanceLocalState()
    private(set) var isWorking = false
    private(set) var autoPaidRequestIds: Set<PaykitPaymentRequest.ID> = []
    private(set) var autoPaidSatsByAllowanceId: [String: UInt64] = [:]

    @ObservationIgnored private let sdk: any PaykitAllowanceSdkHandling
    @ObservationIgnored private let executor: PaykitAllowanceExecutor
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var isProcessingRequests = false

    init(
        sdk: any PaykitAllowanceSdkHandling = PaykitSdkService.shared,
        executor: PaykitAllowanceExecutor = .shared,
        now: @escaping () -> Date = { Date() }
    ) {
        self.sdk = sdk
        self.executor = executor
        self.now = now
    }

    var entries: [PaykitAllowanceEntry] {
        var grouped: [String: [PaykitAllowance]] = [:]
        var order: [String] = []
        for allowance in allowances {
            let key = localState.group(containing: allowance.allowanceId)?.id ?? allowance.allowanceId
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(allowance)
        }
        return order.compactMap { key in
            guard let allowances = grouped[key], !allowances.isEmpty else { return nil }
            let limits = localState.groups.first { $0.id == key }?.limits
            return PaykitAllowanceEntry(id: key, allowances: allowances, limits: limits)
        }
    }

    func entry(id: String) -> PaykitAllowanceEntry? {
        entries.first { $0.id == id }
    }

    func activate(identity: String?) async {
        guard let identity else {
            deactivate()
            return
        }
        let identityChanged = self.identity != identity
        self.identity = identity
        if identityChanged {
            await executor.recover(identity: identity)
        }
        await refresh()
    }

    func deactivate() {
        identity = nil
        allowances = []
        localState = PaykitAllowanceLocalState()
        autoPaidRequestIds = []
        autoPaidSatsByAllowanceId = [:]
    }

    func refresh() async {
        guard let identity else { return }
        do {
            let records = try await sdk.listAllowances(
                filter: Paykit.AllowanceFilter(counterparty: nil, counterpartyReceiverPath: nil, localRole: nil, states: [])
            )
            allowances = records
                .filter { $0.historyStatus == .consistent || $0.historyStatus == .unresolvedReferences }
                .compactMap(PaykitAllowance.init(record:))
        } catch {
            Logger.warn("Failed to list Paykit allowances: \(error)", context: "PaykitAllowance")
        }
        localState = await executor.localState(identity: identity)
        let paid = await executor.succeededAutomaticPayments(identity: identity)
        autoPaidRequestIds = Set(paid.map(\.requestId))
        autoPaidSatsByAllowanceId = paid.reduce(into: [:]) { totals, entry in
            guard let allowanceId = entry.allowanceId else { return }
            totals[allowanceId, default: 0] += entry.amountSats
        }
    }

    func autoPaidSats(for entry: PaykitAllowanceEntry) -> UInt64 {
        entry.allowances.reduce(0) { $0 + (autoPaidSatsByAllowanceId[$1.allowanceId] ?? 0) }
    }

    /// Whether an incoming request is covered by an active Allowance this wallet granted.
    func coversRequest(_ request: PaykitPaymentRequest) -> Bool {
        allowances.contains {
            $0.isAllower && $0.status(at: now()) == .active &&
                PubkyPublicKeyFormat.matches($0.counterparty, request.counterparty) &&
                $0.counterpartyReceiverPath == request.counterpartyReceiverPath
        }
    }

    // MARK: Lifecycle

    func propose(to contact: PubkyContact, limits: PaykitAllowanceLimits) async throws {
        guard let identity else { throw PaykitAllowanceError.unavailable }
        isWorking = true
        defer { isWorking = false }

        let peers = try await sdk.linkedPeers().filter {
            PubkyPublicKeyFormat.matches($0.counterparty, contact.publicKey) && $0.state == .linked
        }
        let receiverPaths = Self.orderedReceiverPaths(peers.map(\.counterpartyReceiverPath))
        guard !receiverPaths.isEmpty else { throw PaykitAllowanceError.contactNotLinked }

        let terms = try limits.terms(
            monthAnchor: PaykitAllowanceTime.monthStart(containing: now()),
            allowedPaymentEndpointIdentifiers: Self.allowedPaymentEndpointIdentifiers
        )
        var allowanceIds: [String] = []
        for receiverPath in receiverPaths {
            do {
                let record = try await sdk.proposeAllowance(
                    counterparty: contact.publicKey,
                    counterpartyReceiverPath: receiverPath,
                    localRole: .allower,
                    terms: terms
                )
                allowanceIds.append(record.allowanceId)
                try? await sdk.processOutboundPrivateMessages(counterparty: contact.publicKey, counterpartyReceiverPath: receiverPath)
            } catch where receiverPath != PaykitReceiverPath.wallet {
                Logger.warn("Could not propose the allowance on a secondary link: \(error)", context: "PaykitAllowance")
            }
        }

        let group = PaykitAllowanceLocalState.Group(
            id: UUID().uuidString.lowercased(),
            counterparty: contact.publicKey,
            limits: limits,
            allowanceIds: allowanceIds,
            createdAt: now()
        )
        await executor.updateLocalState(identity: identity) { $0.groups.append(group) }
        Logger.info("Proposed an allowance on \(allowanceIds.count) link(s)", context: "PaykitAllowance")
        await refresh()
    }

    func accept(_ entry: PaykitAllowanceEntry) async throws {
        try await respond(to: entry) { allowance in
            try await self.sdk.acceptAllowance(
                counterparty: allowance.counterparty,
                counterpartyReceiverPath: allowance.counterpartyReceiverPath,
                allowanceId: allowance.allowanceId
            )
        }
    }

    func reject(_ entry: PaykitAllowanceEntry) async throws {
        try await respond(to: entry) { allowance in
            try await self.sdk.rejectAllowance(
                counterparty: allowance.counterparty,
                counterpartyReceiverPath: allowance.counterpartyReceiverPath,
                allowanceId: allowance.allowanceId
            )
        }
    }

    func end(_ entry: PaykitAllowanceEntry) async throws {
        isWorking = true
        defer { isWorking = false }
        var endedAny = false
        for allowance in entry.allowances where allowance.canEnd {
            _ = try await sdk.endAllowance(
                counterparty: allowance.counterparty,
                counterpartyReceiverPath: allowance.counterpartyReceiverPath,
                allowanceId: allowance.allowanceId
            )
            endedAny = true
            try? await sdk.processOutboundPrivateMessages(
                counterparty: allowance.counterparty,
                counterpartyReceiverPath: allowance.counterpartyReceiverPath
            )
        }
        guard endedAny else { throw PaykitAllowanceError.unavailable }
        await refresh()
    }

    private func respond(to entry: PaykitAllowanceEntry, _ response: (PaykitAllowance) async throws -> Paykit.AllowanceRecord) async throws {
        isWorking = true
        defer { isWorking = false }
        var respondedAny = false
        for allowance in entry.allowances where allowance.isAnswerable {
            _ = try await response(allowance)
            respondedAny = true
            try? await sdk.processOutboundPrivateMessages(
                counterparty: allowance.counterparty,
                counterpartyReceiverPath: allowance.counterpartyReceiverPath
            )
        }
        guard respondedAny else { throw PaykitAllowanceError.unavailable }
        if let identity {
            let ids = entry.allowances.map(\.allowanceId)
            await executor.updateLocalState(identity: identity) { $0.presentedProposalIds.formUnion(ids) }
        }
        await refresh()
    }

    // MARK: Presentation

    func proposalForPresentation() -> PaykitAllowanceEntry? {
        entries.first { entry in
            entry.allowances.contains(where: \.isAnswerable) &&
                !entry.allowances.contains { localState.presentedProposalIds.contains($0.allowanceId) }
        }
    }

    func markProposalPresented(_ entry: PaykitAllowanceEntry) async {
        guard let identity else { return }
        let ids = entry.allowances.map(\.allowanceId)
        await executor.updateLocalState(identity: identity) { $0.presentedProposalIds.formUnion(ids) }
        localState.presentedProposalIds.formUnion(ids)
    }

    // MARK: Automatic payments

    /// Pays incoming requests that an active Allowance covers. Returns whether any request was handled, so the
    /// caller refreshes before presenting the rest for manual payment.
    func processIncomingRequests(_ requests: [PaykitPaymentRequest]) async -> Bool {
        guard let identity, !isProcessingRequests else { return false }
        let covered = requests.filter { $0.requiresAcceptance && coversRequest($0) }
        guard !covered.isEmpty else { return false }

        isProcessingRequests = true
        defer { isProcessingRequests = false }
        var handledAny = false
        for request in covered {
            let result = await executor.autoPay(request, allowances: allowances, identity: identity)
            if result == .started || result == .completed {
                handledAny = true
            }
        }
        if handledAny {
            await refresh()
        }
        return handledAny
    }

    func isAutomaticallyHandling(_ request: PaykitPaymentRequest) async -> Bool {
        await executor.isHandling(request.id)
    }

    static let allowedPaymentEndpointIdentifiers: [String] = PaykitIssuerInterop.supportedEndpointIdentifiers(
        PublicPaykitService.MethodId.publishableMethodIds.map(\.rawValue),
        network: Env.network
    )

    static func orderedReceiverPaths(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths))
        return unique.sorted { lhs, rhs in
            if lhs == PaykitReceiverPath.wallet { return true }
            if rhs == PaykitReceiverPath.wallet { return false }
            return lhs < rhs
        }
    }
}
