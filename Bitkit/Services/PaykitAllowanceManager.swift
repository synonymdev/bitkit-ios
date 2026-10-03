import Foundation
import Observation
import Paykit
import UserNotifications

/// One grant as the user sees it. An SDK Allowance binds this wallet's identity to the contact's identity and covers
/// every Paykit app they use, so a grant is one SDK Allowance. The row keeps the USD limits picked when it was made.
struct PaykitAllowanceEntry: Identifiable, Hashable {
    let id: String
    let allowances: [PaykitAllowance]
    let limits: PaykitAllowanceLimits?

    var primary: PaykitAllowance { allowances[0] }

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
    case paymentListPending

    var errorDescription: String? {
        switch self {
        case .contactNotLinked: t("subscriptions__allowance_error_not_linked")
        case .unavailable, .paymentListPending: t("subscriptions__allowance_error_unavailable")
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
    @ObservationIgnored private let canPayNow: @MainActor () -> Bool
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var isProcessingRequests = false
    @ObservationIgnored private var manualRequestIds: [PaykitPaymentRequest.ID: Int] = [:]

    init(
        sdk: any PaykitAllowanceSdkHandling = PaykitSdkService.shared,
        executor: PaykitAllowanceExecutor = .shared,
        now: @escaping () -> Date = { Date() },
        canPayNow: @escaping @MainActor () -> Bool = PaykitAllowanceManager.lightningReady
    ) {
        self.sdk = sdk
        self.executor = executor
        self.now = now
        self.canPayNow = canPayNow
    }

    /// A node that just started lists its channels before they reconnect, and a payment sent then finds no route.
    static func lightningReady() -> Bool {
        guard LightningService.shared.status?.isRunning == true,
              let channels = LightningService.shared.channels
        else { return false }
        return channels.isEmpty || channels.contains(where: \.isUsable)
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
        await executor.activate(identity: identity)
        if identityChanged {
            manualRequestIds = [:]
            await executor.recover(identity: identity)
        }
        await refresh()
    }

    func deactivate() {
        identity = nil
        Task { await executor.activate(identity: nil) }
        allowances = []
        localState = PaykitAllowanceLocalState()
        autoPaidRequestIds = []
        autoPaidSatsByAllowanceId = [:]
        manualRequestIds = [:]
    }

    func refresh() async {
        guard let identity else { return }
        do {
            let records = try await sdk.listAllowances(
                filter: Paykit.AllowanceFilter(counterparty: nil, localRole: nil, states: [])
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

    /// Whether an incoming request is covered by an active Allowance this wallet granted. A request created before the
    /// Allowance was accepted stays manual: it may already have been shown to the user for a decision.
    func coversRequest(_ request: PaykitPaymentRequest) -> Bool {
        allowances.contains { allowance in
            guard allowance.isAllower, allowance.status(at: now()) == .active,
                  PubkyPublicKeyFormat.matches(allowance.counterparty, request.counterparty)
            else { return false }
            guard let acceptedAt = allowance.lastEventAt, let createdAt = request.createdAt else { return true }
            return createdAt >= acceptedAt.addingTimeInterval(-Self.acceptanceClockTolerance)
        }
    }

    private var allowancesSignature: Int {
        var hasher = Hasher()
        for allowance in allowances {
            hasher.combine(allowance.allowanceId)
            hasher.combine(allowance.lifecycleState.rawDescription)
        }
        hasher.combine(autoPaidSatsByAllowanceId.values.reduce(0, +))
        return hasher.finalize()
    }

    // MARK: Lifecycle

    func propose(to contact: PubkyContact, limits: PaykitAllowanceLimits) async throws {
        guard let identity else { throw PaykitAllowanceError.unavailable }
        isWorking = true
        defer { isWorking = false }

        let isLinked = try await sdk.linkedPeers().contains {
            PubkyPublicKeyFormat.matches($0.counterparty, contact.publicKey) && $0.state == .linked
        }
        guard isLinked else { throw PaykitAllowanceError.contactNotLinked }

        let terms = try limits.terms(
            monthAnchor: PaykitAllowanceTime.monthStart(containing: now()),
            allowedPaymentEndpointIdentifiers: Self.allowedPaymentEndpointIdentifiers
        )
        let record = try await sdk.proposeAllowance(counterparty: contact.publicKey, localRole: .allower, terms: terms)
        try? await sdk.processOutboundPrivateMessages(counterparty: contact.publicKey)

        let group = PaykitAllowanceLocalState.Group(
            id: UUID().uuidString.lowercased(),
            counterparty: contact.publicKey,
            limits: limits,
            allowanceIds: [record.allowanceId],
            createdAt: now()
        )
        await executor.updateLocalState(identity: identity) { $0.groups.append(group) }
        Logger.info("Proposed an allowance", context: "PaykitAllowance")
        await refresh()
    }

    func accept(_ entry: PaykitAllowanceEntry) async throws {
        try await respond(to: entry) { allowance in
            try await self.sdk.acceptAllowance(counterparty: allowance.counterparty, allowanceId: allowance.allowanceId)
        }
    }

    func reject(_ entry: PaykitAllowanceEntry) async throws {
        try await respond(to: entry) { allowance in
            try await self.sdk.rejectAllowance(counterparty: allowance.counterparty, allowanceId: allowance.allowanceId)
        }
    }

    func end(_ entry: PaykitAllowanceEntry) async throws {
        isWorking = true
        defer { isWorking = false }
        var endedAny = false
        for allowance in entry.allowances where allowance.canEnd {
            _ = try await sdk.endAllowance(counterparty: allowance.counterparty, allowanceId: allowance.allowanceId)
            endedAny = true
            try? await sdk.processOutboundPrivateMessages(counterparty: allowance.counterparty)
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
            try? await sdk.processOutboundPrivateMessages(counterparty: allowance.counterparty)
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
        let signature = allowancesSignature
        let covered = requests.filter(isAwaitingAutomaticPayment)
        guard !covered.isEmpty else { return false }
        guard canPayNow() else {
            Logger.info("Holding \(covered.count) covered request(s) until the node has a usable channel", context: "PaykitAllowance")
            return false
        }

        isProcessingRequests = true
        defer { isProcessingRequests = false }
        var handledAny = false
        for request in covered {
            let result = await executor.autoPay(request, allowances: allowances, identity: identity)
            Logger.info("Automatic payment pass for a covered request ended as \(result)", context: "PaykitAllowance")
            switch result {
            case .started, .completed:
                handledAny = true
            case .manual, .notCovered:
                manualRequestIds[request.id] = signature
            case .deferred:
                break
            }
        }
        if handledAny {
            await refresh()
        }
        return handledAny
    }

    /// Whether the allowance flow owns the request, so no sheet may open for it. A covered request belongs to the flow
    /// from the moment it arrives, even before the first pass over it, until that pass finds it manual.
    func isAutomaticallyHandling(_ request: PaykitPaymentRequest) async -> Bool {
        if isAwaitingAutomaticPayment(request) { return true }
        return await executor.isHandling(request.id)
    }

    private func isAwaitingAutomaticPayment(_ request: PaykitPaymentRequest) -> Bool {
        request.requiresAcceptance && request.billingPeriod == nil && coversRequest(request) && manualRequestIds[request.id] != allowancesSignature
    }

    static let acceptanceClockTolerance: TimeInterval = 30

    static let allowedPaymentEndpointIdentifiers: [String] = PaykitIssuerInterop.supportedEndpointIdentifiers(
        PublicPaykitService.MethodId.publishableMethodIds.map(\.rawValue),
        network: Env.network
    )
}

/// Allowance outcomes reach the user as a notification banner when notifications are allowed, or as a toast.
enum PaykitAllowanceNotifier {
    @MainActor
    static func post(title: String, body: String, fallback: @escaping @MainActor () -> Void) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                fallback()
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["bitkit_action": "paykit_allowance"]
            do {
                try await center.add(UNNotificationRequest(identifier: "paykit-allowance-\(UUID().uuidString)", content: content, trigger: nil))
            } catch {
                fallback()
            }
        }
    }
}
