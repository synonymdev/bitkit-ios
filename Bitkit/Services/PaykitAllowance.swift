import Foundation
import Paykit

/// An Allowance between this wallet and one contact link, built from the SDK record.
/// Eligibility always runs on real time: allowance code never reads `DemoClock`.
struct PaykitAllowance: Identifiable, Hashable {
    struct ID: Codable, Hashable {
        let counterparty: String
        let counterpartyReceiverPath: String
        let allowanceId: String
    }

    enum Role: String, Codable, Hashable {
        case allower
        case allowee
    }

    enum Status: Hashable {
        /// Sent by this wallet; the other side has not answered yet.
        case awaitingAnswer
        /// Received; this wallet must accept or decline.
        case awaitingMyAnswer
        case active
        case notYetActive
        case expired
        case declined
        case ended
        case conflicted
    }

    let id: ID
    let role: Role
    let lifecycleState: Paykit.AllowanceLifecycleState
    let isProposedByMe: Bool
    let perPaymentMaxSats: UInt64?
    let monthlyLimitSats: UInt64?
    let monthlyAnchor: Date?
    let activeFrom: Date?
    let expiresAt: Date?
    let allowedPaymentEndpointIdentifiers: [String]?
    let lastEventAt: Date?

    var counterparty: String { id.counterparty }
    var counterpartyReceiverPath: String { id.counterpartyReceiverPath }
    var allowanceId: String { id.allowanceId }

    init?(record: Paykit.AllowanceRecord) {
        guard let localRole = record.localRole,
              let role = Role(localRole),
              let terms = record.terms,
              terms.asset() == PaykitIssuerInterop.bitcoinAsset
        else { return nil }

        let monthly = terms.periodLimits().first { Self.isMonthly($0.period()) }
        id = ID(
            counterparty: record.counterparty,
            counterpartyReceiverPath: record.counterpartyReceiverPath,
            allowanceId: record.allowanceId
        )
        self.role = role
        lifecycleState = record.state
        isProposedByMe = record.proposalOutboundMessageId != nil
        perPaymentMaxSats = terms.perPaymentAmount().flatMap { Self.sats(fromBitcoinAmount: $0.maximum()) }
        monthlyLimitSats = monthly?.amountLimit().flatMap { Self.sats(fromBitcoinAmount: $0) }
        monthlyAnchor = monthly?.period().anchor().flatMap(PaykitAllowanceTime.parse)
        activeFrom = terms.activeFrom().flatMap(PaykitAllowanceTime.parse)
        expiresAt = terms.expiresAt().flatMap(PaykitAllowanceTime.parse)
        allowedPaymentEndpointIdentifiers = terms.allowedPaymentEndpointIdentifiers()
        lastEventAt = record.lastEventAt.flatMap(PaykitAllowanceTime.parse)
    }

    init(
        id: ID,
        role: Role,
        lifecycleState: Paykit.AllowanceLifecycleState,
        isProposedByMe: Bool,
        perPaymentMaxSats: UInt64?,
        monthlyLimitSats: UInt64?,
        monthlyAnchor: Date?,
        activeFrom: Date? = nil,
        expiresAt: Date? = nil,
        allowedPaymentEndpointIdentifiers: [String]? = nil,
        lastEventAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.lifecycleState = lifecycleState
        self.isProposedByMe = isProposedByMe
        self.perPaymentMaxSats = perPaymentMaxSats
        self.monthlyLimitSats = monthlyLimitSats
        self.monthlyAnchor = monthlyAnchor
        self.activeFrom = activeFrom
        self.expiresAt = expiresAt
        self.allowedPaymentEndpointIdentifiers = allowedPaymentEndpointIdentifiers
        self.lastEventAt = lastEventAt
    }

    func status(at now: Date) -> Status {
        switch lifecycleState {
        case .proposed:
            return isProposedByMe ? .awaitingAnswer : .awaitingMyAnswer
        case .accepted:
            if let expiresAt, now >= expiresAt { return .expired }
            if let activeFrom, now < activeFrom { return .notYetActive }
            return .active
        case .rejected:
            return .declined
        case .ended:
            return .ended
        case .conflicted, .unknown:
            return .conflicted
        }
    }

    /// The payer side: this wallet pays the counterparty's requests automatically.
    var isAllower: Bool { role == .allower }

    var canEnd: Bool {
        switch lifecycleState {
        case .accepted: true
        case .proposed: isProposedByMe
        default: false
        }
    }

    var isAnswerable: Bool {
        lifecycleState == .proposed && !isProposedByMe
    }

    static func isMonthly(_ period: Paykit.AllowancePeriod) -> Bool {
        period.kind() == "anchored" && period.every() == 1 && period.unit() == "month"
    }

    static func sats(fromBitcoinAmount amount: String) -> UInt64? {
        if amount.split(separator: ".").allSatisfy({ $0.allSatisfy { $0 == "0" } }) {
            return 0
        }
        return PaykitPaymentRequest.sats(fromBitcoinAmount: amount)
    }
}

extension PaykitAllowance.Role {
    init?(_ role: Paykit.AllowanceLocalRole) {
        switch role {
        case .allower: self = .allower
        case .allowee: self = .allowee
        case .unknown: return nil
        }
    }
}

/// Limits picked in USD on the Set Allowance sheet, converted once to whole-sat BTC terms.
struct PaykitAllowanceLimits: Codable, Hashable {
    let perPaymentUsd: Decimal
    let monthlyUsd: Decimal
    let perPaymentSats: UInt64
    let monthlySats: UInt64

    static let perPaymentStopsUsd: [Decimal] = [1, 5, 10, 20, 50]
    static let monthlyStopsUsd: [Decimal] = [10, 50, 100, 200, 500]

    /// Terms Bitkit proposes: per-payment range 0...max, an anchored UTC calendar month, and the endpoints Bitkit pays.
    func terms(monthAnchor: Date, allowedPaymentEndpointIdentifiers: [String]) throws -> Paykit.AllowanceTerms {
        let perPayment = try Paykit.AllowanceAmountRange(
            minimum: "0",
            maximum: WalletViewModel.formatBitcoinAmount(sats: perPaymentSats)
        )
        let month = try Paykit.AllowancePeriod(
            kind: "anchored",
            every: 1,
            unit: "month",
            anchor: PaykitAllowanceTime.format(monthAnchor)
        )
        let monthly = try Paykit.AllowancePeriodLimit(
            amountLimit: WalletViewModel.formatBitcoinAmount(sats: monthlySats),
            paymentCountLimit: nil,
            period: month
        )
        return try Paykit.AllowanceTerms(
            asset: PaykitIssuerInterop.bitcoinAsset,
            perPaymentAmount: perPayment,
            periodLimits: [monthly],
            lifetimeAmountLimit: nil,
            activeFrom: nil,
            expiresAt: nil,
            allowedPaymentEndpointIdentifiers: allowedPaymentEndpointIdentifiers
        )
    }
}

enum PaykitAllowanceTime {
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// First instant of the UTC calendar month that contains `date`.
    static func monthStart(containing date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    /// The anchored monthly window `[start, end)` that contains `date`. Anchors on a day that a short month lacks
    /// clamp to that month's last day, as the spec's anchored-period arithmetic does.
    static func monthlyWindow(anchor: Date, containing date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var start = anchor
        if date < anchor {
            while start > date, let previous = calendar.date(byAdding: .month, value: -1, to: start) {
                start = previous
            }
        }
        var index = 0
        while let next = calendar.date(byAdding: .month, value: index + 1, to: anchor), next <= date {
            index += 1
            start = next
        }
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }
}

/// Wallet-side capacity preflight. The SDK checks capacity only after automatic Acceptance, so Bitkit sums this
/// Allowance's live automatic attempts in the current month first and keeps an over-cap request on the manual flow.
enum PaykitAllowanceCapacity {
    struct Attempt: Equatable {
        let allowanceId: String
        let amountSats: UInt64
        let admittedAt: Date
        let isLive: Bool
    }

    static func usedSats(allowanceId: String, attempts: [Attempt], anchor: Date, now: Date) -> UInt64 {
        let window = PaykitAllowanceTime.monthlyWindow(anchor: anchor, containing: now)
        return attempts
            .filter { $0.allowanceId == allowanceId && $0.isLive && $0.admittedAt >= window.start && $0.admittedAt < window.end }
            .reduce(0) { $0 + $1.amountSats }
    }

    static func fits(amountSats: UInt64, allowance: PaykitAllowance, attempts: [Attempt], now: Date) -> Bool {
        if let perPaymentMaxSats = allowance.perPaymentMaxSats, amountSats > perPaymentMaxSats {
            return false
        }
        guard let monthlyLimitSats = allowance.monthlyLimitSats, let anchor = allowance.monthlyAnchor else {
            return true
        }
        let used = usedSats(allowanceId: allowance.allowanceId, attempts: attempts, anchor: anchor, now: now)
        return used + amountSats <= monthlyLimitSats
    }

    static func attempts(from history: Paykit.AllowanceAccountingHistory) -> [Attempt] {
        history.occurrences.flatMap(\.attempts).compactMap { attempt in
            guard attempt.mode == .automatic,
                  let allowanceId = attempt.allowanceId,
                  let admittedAt = PaykitAllowanceTime.parse(attempt.admittedAt),
                  let amountSats = PaykitAllowance.sats(fromBitcoinAmount: attempt.amount.value())
              else { return nil }
            return Attempt(
                allowanceId: allowanceId,
                amountSats: amountSats,
                admittedAt: admittedAt,
                isLive: attempt.status != .failed
            )
        }
    }
}
