import Foundation
import Paykit
import UserNotifications

private struct PaykitPreciseInstant: Comparable, Hashable {
    let seconds: Int64
    let nanoseconds: Int
    let timestamp: String

    var date: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }

    init?(timestamp: String) {
        let canonical = PaykitSubscriptionTimestamp.canonical(timestamp)
        let fraction = PaykitSubscriptionTimestamp.fractionalSeconds(from: canonical) ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsedDate = formatter.date(from: canonical)
        if parsedDate == nil {
            formatter.formatOptions = [.withInternetDateTime]
            parsedDate = formatter.date(from: canonical)
        }
        guard let date = parsedDate else { return nil }

        seconds = Int64(floor(date.timeIntervalSince1970))
        nanoseconds = Int(fraction.padding(toLength: 9, withPad: "0", startingAt: 0)) ?? 0
        self.timestamp = canonical
    }

    init(date: Date) {
        var wholeSeconds = floor(date.timeIntervalSince1970)
        var nanoseconds = Int(((date.timeIntervalSince1970 - wholeSeconds) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            wholeSeconds += 1
            nanoseconds = 0
        }
        seconds = Int64(wholeSeconds)
        self.nanoseconds = nanoseconds
        timestamp = PaykitSubscriptionTimestamp.string(
            from: Date(timeIntervalSince1970: wholeSeconds),
            fractionalSeconds: Self.fractionalSeconds(nanoseconds)
        )
    }

    init(seconds: Int64, nanoseconds: Int) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
        timestamp = PaykitSubscriptionTimestamp.string(
            from: Date(timeIntervalSince1970: TimeInterval(seconds)),
            fractionalSeconds: Self.fractionalSeconds(nanoseconds)
        )
    }

    static func < (lhs: PaykitPreciseInstant, rhs: PaykitPreciseInstant) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }

    private static func fractionalSeconds(_ nanoseconds: Int) -> String? {
        guard nanoseconds != 0 else { return nil }
        return PaykitSubscriptionTimestamp.fractionalSeconds(
            from: "1970-01-01T00:00:00." + String(format: "%09d", nanoseconds) + "Z"
        )
    }
}

struct PaykitBillingPeriod: Codable, Hashable {
    let startsAt: Date
    let endsAt: Date
    private let startsAtTimestamp: String
    private let endsAtTimestamp: String

    init?(sdkPeriod: Paykit.BillingPeriod) {
        guard let preciseStartsAt = PaykitPreciseInstant(timestamp: sdkPeriod.startsAt),
              let preciseEndsAt = PaykitPreciseInstant(timestamp: sdkPeriod.endsAt),
              preciseStartsAt < preciseEndsAt
        else { return nil }

        startsAt = preciseStartsAt.date
        endsAt = preciseEndsAt.date
        startsAtTimestamp = PaykitSubscriptionTimestamp.canonical(sdkPeriod.startsAt)
        endsAtTimestamp = PaykitSubscriptionTimestamp.canonical(sdkPeriod.endsAt)
    }

    init(
        startsAt: Date,
        endsAt: Date,
        startsAtTimestamp: String? = nil,
        endsAtTimestamp: String? = nil
    ) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.startsAtTimestamp = startsAtTimestamp ?? PaykitSubscriptionTimestamp.string(from: startsAt)
        self.endsAtTimestamp = endsAtTimestamp ?? PaykitSubscriptionTimestamp.string(from: endsAt)
    }

    var sdkValue: Paykit.BillingPeriod {
        Paykit.BillingPeriod(
            startsAt: startsAtTimestamp,
            endsAt: endsAtTimestamp
        )
    }

    static func == (lhs: PaykitBillingPeriod, rhs: PaykitBillingPeriod) -> Bool {
        lhs.startsAtTimestamp == rhs.startsAtTimestamp && lhs.endsAtTimestamp == rhs.endsAtTimestamp
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(startsAtTimestamp)
        hasher.combine(endsAtTimestamp)
    }
}

struct PaykitSubscriptionMetadata: Hashable {
    let description: String?
    let benefits: [String]

    init(_ metadata: Paykit.PrivateJsonObject) {
        guard let data = metadata.exportText().data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subscription = object["subscription"] as? [String: Any],
              subscription["version"] as? Int == 1
        else {
            description = nil
            benefits = []
            return
        }

        description = Self.trimmed(subscription["description"] as? String, limit: 1024)
        benefits = (subscription["benefits"] as? [String] ?? [])
            .prefix(8)
            .compactMap { Self.trimmed($0, limit: 160) }
    }

    private static func trimmed(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}

struct PaykitSubscriptionRecurrence: Hashable {
    private static let maximumPeriods = 10000

    enum Unit: String, Hashable {
        case minute
        case hour
        case day
        case week
        case month
        case year

        var isSupported: Bool {
            switch self {
            case .day, .week, .month, .year:
                true
            case .minute, .hour:
                false
            }
        }
    }

    let every: Int
    let unit: Unit
    let startsAt: Date
    let anchor: Date
    let endsAt: Date?
    private let preciseStartsAt: PaykitPreciseInstant
    private let preciseAnchor: PaykitPreciseInstant
    private let preciseEndsAt: PaykitPreciseInstant?

    var canMaterializePeriods: Bool {
        firstBoundaryIndex(after: preciseStartsAt) != nil
    }

    init?(_ recurrence: Paykit.PaymentRequestRecurrence) {
        guard let every = Int(exactly: recurrence.every), every > 0,
              every <= Int.max / Self.maximumPeriods,
              let unit = Unit(rawValue: recurrence.unit),
              let preciseStartsAt = PaykitPreciseInstant(timestamp: recurrence.startsAt),
              let preciseAnchor = PaykitPreciseInstant(timestamp: recurrence.anchor)
        else { return nil }

        let preciseEndsAt = recurrence.endsAt.flatMap(PaykitPreciseInstant.init)
        if recurrence.endsAt != nil, preciseEndsAt == nil || preciseEndsAt! <= preciseStartsAt {
            return nil
        }

        self.every = every
        self.unit = unit
        self.preciseStartsAt = preciseStartsAt
        self.preciseAnchor = preciseAnchor
        self.preciseEndsAt = preciseEndsAt
        startsAt = preciseStartsAt.date
        anchor = preciseAnchor.date
        endsAt = preciseEndsAt?.date
    }

    func periods(through date: Date, acceptedAt: Date) -> [PaykitBillingPeriod] {
        let preciseDate = PaykitPreciseInstant(date: date)
        let preciseAcceptedAt = PaykitPreciseInstant(date: acceptedAt)
        guard unit.isSupported, preciseStartsAt <= preciseDate else { return [] }

        var periods: [PaykitBillingPeriod] = []
        var start = preciseStartsAt
        guard var index = firstBoundaryIndex(after: preciseStartsAt) else { return [] }

        for _ in 0 ..< Self.maximumPeriods {
            guard start <= preciseDate else { break }
            guard var end = boundary(at: index) else { break }
            index += 1
            if end <= start {
                guard let fallback = addingInterval(to: start) else { break }
                end = fallback
            }
            if let preciseEndsAt {
                guard start < preciseEndsAt else { break }
                end = min(end, preciseEndsAt)
            }
            guard end > start else { break }

            if end > preciseAcceptedAt {
                periods.append(period(startsAt: start, endsAt: end))
            }
            start = end
        }

        return periods
    }

    func nextPeriod(after date: Date) -> PaykitBillingPeriod? {
        let preciseDate = PaykitPreciseInstant(date: date)
        let start: PaykitPreciseInstant
        let endIndex: Int
        if preciseStartsAt > preciseDate {
            start = preciseStartsAt
            guard let index = firstBoundaryIndex(after: start) else { return nil }
            endIndex = index
        } else {
            guard let startIndex = firstBoundaryIndex(after: preciseDate),
                  let boundary = boundary(at: startIndex)
            else { return nil }
            start = boundary
            endIndex = startIndex + 1
        }
        guard var end = boundary(at: endIndex) else { return nil }
        if end <= start {
            guard let fallback = addingInterval(to: start) else { return nil }
            end = fallback
        }
        if let preciseEndsAt {
            guard start < preciseEndsAt else { return nil }
            end = min(end, preciseEndsAt)
        }
        return period(startsAt: start, endsAt: end)
    }

    func upcomingPeriods(after date: Date, limit: Int) -> [PaykitBillingPeriod] {
        guard limit > 0 else { return [] }

        var periods: [PaykitBillingPeriod] = []
        var cursor = date
        for _ in 0 ..< min(limit, Self.maximumPeriods) {
            guard let period = nextPeriod(after: cursor) else { break }
            periods.append(period)
            cursor = period.startsAt
        }
        return periods
    }

    private func firstBoundaryIndex(after date: PaykitPreciseInstant) -> Int? {
        var lowerBound = -Self.maximumPeriods + 1
        var upperBound = Self.maximumPeriods
        while lowerBound < upperBound {
            let index = lowerBound + (upperBound - lowerBound) / 2
            guard let candidate = boundary(at: index) else { return nil }
            if candidate <= date {
                lowerBound = index + 1
            } else {
                upperBound = index
            }
        }

        guard boundary(at: lowerBound).map({ $0 > date }) == true,
              let previous = boundary(at: lowerBound - 1), previous <= date
        else { return nil }
        return lowerBound
    }

    private func boundary(at index: Int) -> PaykitPreciseInstant? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let value = every * index

        let boundaryDate: Date? = switch unit {
        case .minute:
            calendar.date(byAdding: .minute, value: value, to: preciseAnchor.date)
        case .hour:
            calendar.date(byAdding: .hour, value: value, to: preciseAnchor.date)
        case .day:
            calendar.date(byAdding: .day, value: value, to: preciseAnchor.date)
        case .week:
            calendar.date(byAdding: .weekOfYear, value: value, to: preciseAnchor.date)
        case .month:
            Self.monthBoundary(from: preciseAnchor.date, offset: value, calendar: calendar)
        case .year:
            Self.yearBoundary(from: preciseAnchor.date, offset: value, calendar: calendar)
        }
        guard let boundaryDate else { return nil }
        return PaykitPreciseInstant(seconds: Int64(floor(boundaryDate.timeIntervalSince1970)), nanoseconds: preciseAnchor.nanoseconds)
    }

    private func addingInterval(to date: PaykitPreciseInstant) -> PaykitPreciseInstant? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let result: Date? = switch unit {
        case .minute:
            calendar.date(byAdding: .minute, value: every, to: date.date)
        case .hour:
            calendar.date(byAdding: .hour, value: every, to: date.date)
        case .day:
            calendar.date(byAdding: .day, value: every, to: date.date)
        case .week:
            calendar.date(byAdding: .weekOfYear, value: every, to: date.date)
        case .month:
            calendar.date(byAdding: .month, value: every, to: date.date)
        case .year:
            calendar.date(byAdding: .year, value: every, to: date.date)
        }
        guard let result else { return nil }
        return PaykitPreciseInstant(seconds: Int64(floor(result.timeIntervalSince1970)), nanoseconds: date.nanoseconds)
    }

    private func period(startsAt: PaykitPreciseInstant, endsAt: PaykitPreciseInstant) -> PaykitBillingPeriod {
        PaykitBillingPeriod(
            startsAt: startsAt.date,
            endsAt: endsAt.date,
            startsAtTimestamp: startsAt.timestamp,
            endsAtTimestamp: endsAt.timestamp
        )
    }

    private static func monthBoundary(from anchor: Date, offset: Int, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: anchor)
        guard let firstOfAnchorMonth = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)),
              let targetMonth = calendar.date(byAdding: .month, value: offset, to: firstOfAnchorMonth),
              let range = calendar.range(of: .day, in: .month, for: targetMonth)
        else { return nil }

        var target = calendar.dateComponents([.year, .month], from: targetMonth)
        target.day = min(components.day ?? 1, range.count)
        target.hour = components.hour
        target.minute = components.minute
        target.second = components.second
        target.nanosecond = components.nanosecond
        return calendar.date(from: target)
    }

    private static func yearBoundary(from anchor: Date, offset: Int, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: anchor)
        guard let year = components.year, let month = components.month else { return nil }
        let (targetYear, didOverflow) = year.addingReportingOverflow(offset)
        guard !didOverflow,
              let firstOfTargetMonth = calendar.date(from: DateComponents(year: targetYear, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: firstOfTargetMonth)
        else { return nil }

        var target = DateComponents()
        target.year = targetYear
        target.month = month
        target.day = min(components.day ?? 1, range.count)
        target.hour = components.hour
        target.minute = components.minute
        target.second = components.second
        target.nanosecond = components.nanosecond
        return calendar.date(from: target)
    }
}

struct PaykitSubscription: Identifiable, Hashable {
    struct ID: Codable, Hashable {
        let paymentRequestId: String
        let counterparty: String
        let counterpartyReceiverPath: String
    }

    struct Payment: Hashable {
        let billingPeriod: PaykitBillingPeriod
        let proofKind: PaykitPaymentProofKind?
    }

    let paymentRequestId: String
    let counterparty: String
    let counterpartyReceiverPath: String
    let amountValue: String
    let amountSats: UInt64
    let note: String?
    let createdAt: Date?
    let proposalExpiresAt: Date?
    let recurrence: PaykitSubscriptionRecurrence
    let metadata: PaykitSubscriptionMetadata
    let acceptedPaymentEndpointIdentifiers: [String]
    let wasAccepted: Bool
    var lifecycleState: Paykit.PaymentRequestLifecycleState
    let payments: [Payment]

    var paidPeriods: [PaykitBillingPeriod] {
        payments.map(\.billingPeriod)
    }

    var id: ID {
        ID(
            paymentRequestId: paymentRequestId,
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath
        )
    }

    var isProposal: Bool {
        lifecycleState == .proposed
    }

    func isProposalActionable(at date: Date) -> Bool {
        isProposalVisible(at: date) &&
            recurrence.unit.isSupported &&
            recurrence.canMaterializePeriods &&
            !acceptedPaymentEndpointIdentifiers.isEmpty
    }

    func isProposalVisible(at date: Date) -> Bool {
        isProposal &&
            (proposalExpiresAt.map { $0 > date } ?? true) &&
            (recurrence.endsAt.map { $0 > date } ?? true)
    }

    func isActive(at date: Date) -> Bool {
        lifecycleState == .activeRecurring && recurrence.endsAt.map { $0 > date } ?? true
    }

    func isExpired(at date: Date) -> Bool {
        lifecycleState == .canceled || lifecycleState == .rejected || lifecycleState == .proposalExpired ||
            (isProposal && proposalExpiresAt.map { $0 <= date } ?? false) ||
            (recurrence.endsAt.map { $0 <= date } ?? false)
    }

    func withExpiredLifecycle(at date: Date) -> PaykitSubscription {
        guard isProposal,
              proposalExpiresAt.map({ $0 <= date }) == true || recurrence.endsAt.map({ $0 <= date }) == true
        else { return self }
        var subscription = self
        subscription.lifecycleState = .proposalExpired
        return subscription
    }

    init?(record: Paykit.PaymentRequestRecord) {
        guard record.localRole == .payer,
              let terms = record.terms,
              let recurrence = terms.recurrence.flatMap(PaykitSubscriptionRecurrence.init),
              terms.amount.asset == "btc",
              let amountSats = PaykitPaymentRequest.sats(fromBitcoinAmount: terms.amount.value),
              amountSats <= UInt64.max / 1000
        else { return nil }

        let proposalExpiresAt = terms.proposalExpiresAt.flatMap(PaykitPaymentRequest.parseDate)
        if terms.proposalExpiresAt != nil, proposalExpiresAt == nil { return nil }

        paymentRequestId = record.paymentRequestId
        counterparty = record.counterparty
        counterpartyReceiverPath = record.counterpartyReceiverPath
        amountValue = terms.amount.value
        self.amountSats = amountSats
        note = PaykitPaymentRequest.note(from: terms.metadata).map { String($0.prefix(256)) }
        createdAt = record.lastEventAt.flatMap(PaykitPaymentRequest.parseDate)
        self.proposalExpiresAt = proposalExpiresAt
        self.recurrence = recurrence
        metadata = PaykitSubscriptionMetadata(terms.metadata)
        acceptedPaymentEndpointIdentifiers = PaykitPaymentRequest.supportedEndpointIdentifiers(
            terms.acceptedPaymentEndpointIdentifiers
        )
        wasAccepted = record.acceptedEventId != nil || record.state == .activeRecurring || !record.paymentProofs.isEmpty
        lifecycleState = record.state
        payments = record.paymentProofs.compactMap { proof in
            guard let billingPeriod = proof.billingPeriod.flatMap(PaykitBillingPeriod.init) else { return nil }
            return Payment(
                billingPeriod: billingPeriod,
                proofKind: PaykitPaymentProofKind(paymentEndpointIdentifier: proof.paymentEndpointIdentifier)
            )
        }
    }

    func requests(through date: Date, acceptedAt: Date) -> [PaykitPaymentRequest] {
        recurrence.periods(through: date, acceptedAt: acceptedAt).map { period in
            let payment = payments.last { $0.billingPeriod == period }
            return PaykitPaymentRequest(
                subscription: self,
                billingPeriod: period,
                lifecycleState: payment == nil ? .activeRecurring : .proofSubmitted,
                paymentProofKind: payment?.proofKind
            )
        }
    }

    func paymentDueOnAcceptance(at date: Date) -> PaykitPaymentRequest? {
        guard let period = recurrence.periods(through: date, acceptedAt: date).first else { return nil }
        return PaykitPaymentRequest(subscription: self, billingPeriod: period, lifecycleState: .activeRecurring)
    }
}

struct PaykitSubscriptionState: Codable, Equatable {
    var acceptedAt: [PaykitSubscription.ID: Date] = [:]
    var presentedProposalIds: Set<PaykitSubscription.ID> = []
    var dismissedPaymentIds: Set<PaykitPaymentRequest.ID> = []
}

protocol PaykitSubscriptionStateStoring {
    func load(identity: String) throws -> PaykitSubscriptionState
    func save(_ subscriptionState: PaykitSubscriptionState, identity: String) throws
}

struct PaykitSubscriptionStateStore: PaykitSubscriptionStateStoring {
    private struct State: Codable {
        var subscriptionsByIdentity: [String: PaykitSubscriptionState]
    }

    func load(identity: String) throws -> PaykitSubscriptionState {
        guard let normalizedIdentity = PubkyPublicKeyFormat.normalized(identity),
              let data = try Keychain.load(key: .paykitSubscriptionState)
        else { return PaykitSubscriptionState() }

        return try JSONDecoder().decode(State.self, from: data).subscriptionsByIdentity[normalizedIdentity] ?? PaykitSubscriptionState()
    }

    func save(_ subscriptionState: PaykitSubscriptionState, identity: String) throws {
        guard let normalizedIdentity = PubkyPublicKeyFormat.normalized(identity) else { return }
        var state: State = if let data = try Keychain.load(key: .paykitSubscriptionState) {
            try JSONDecoder().decode(State.self, from: data)
        } else {
            State(subscriptionsByIdentity: [:])
        }
        state.subscriptionsByIdentity[normalizedIdentity] = subscriptionState
        try Keychain.upsert(key: .paykitSubscriptionState, data: JSONEncoder().encode(state))
    }
}

protocol PaykitSubscriptionNotificationCenter: Sendable {
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
}

private struct SystemPaykitSubscriptionNotificationCenter: PaykitSubscriptionNotificationCenter {
    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

actor PaykitSubscriptionNotificationScheduler {
    private static let maximumNotifications = 32
    private let center: any PaykitSubscriptionNotificationCenter
    private var generation = 0
    private var retainedIdentifiers: Set<String> = []

    init(center: any PaykitSubscriptionNotificationCenter = SystemPaykitSubscriptionNotificationCenter()) {
        self.center = center
    }

    func synchronize(
        _ subscriptions: [PaykitSubscription],
        acceptedAt: [PaykitSubscription.ID: Date],
        pendingRequestIds: Set<PaykitPaymentRequest.ID>,
        payerIdentity: String,
        notificationsEnabled: Bool,
        now: Date
    ) async {
        generation += 1
        let currentGeneration = generation
        let notifications: [(PaykitSubscription, PaykitBillingPeriod)] = notificationsEnabled ? Array(subscriptions
            .filter {
                $0.isActive(at: now) &&
                    $0.recurrence.unit.isSupported &&
                    acceptedAt[$0.id] != nil
            }
            .flatMap { subscription in
                subscription.recurrence.upcomingPeriods(
                    after: now,
                    limit: Self.maximumNotifications
                ).map { (subscription, $0) }
            }
            .sorted { $0.1.startsAt < $1.1.startsAt }
            .prefix(Self.maximumNotifications)) : []

        let desiredIdentifiers = Set(notifications.map {
            PaykitSubscriptionNotificationIdentifier.identifier(identity: payerIdentity, subscription: $0.0, period: $0.1)
        })
        let unpaidIdentifiers: Set<String> = notificationsEnabled ? Set(pendingRequestIds.compactMap {
            PaykitSubscriptionNotificationIdentifier.identifier(identity: payerIdentity, requestId: $0)
        }) : []
        retainedIdentifiers = desiredIdentifiers.union(unpaidIdentifiers)

        let pending = await center.pendingNotificationRequests()
        guard generation == currentGeneration else { return }

        let existingIdentifiers = Set(pending.map(\.identifier))
        await center.removePendingNotificationRequests(
            withIdentifiers: existingIdentifiers.filter {
                $0.hasPrefix(PaykitSubscriptionNotificationIdentifier.prefix) && !retainedIdentifiers.contains($0)
            }
        )

        for (subscription, period) in notifications {
            guard generation == currentGeneration else { return }
            let identifier = PaykitSubscriptionNotificationIdentifier.identifier(
                identity: payerIdentity,
                subscription: subscription,
                period: period
            )
            guard !existingIdentifiers.contains(identifier) else { continue }
            let content = UNMutableNotificationContent()
            content.title = t("subscriptions__payment_due_title")
            content.body = t("subscriptions__payment_due_description")
            content.sound = .default
            content.userInfo = [
                "bitkit_action": "paykit_subscription_due",
                "payer_identity": payerIdentity,
                "payment_request_id": subscription.paymentRequestId,
                "counterparty": subscription.counterparty,
                "counterparty_receiver_path": subscription.counterpartyReceiverPath,
                "billing_period_starts_at": PaykitSubscriptionTimestamp.string(from: period.startsAt),
            ]
            let interval = max(1, period.startsAt.timeIntervalSince(now))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
            guard generation == currentGeneration else {
                if !retainedIdentifiers.contains(identifier) {
                    await center.removePendingNotificationRequests(withIdentifiers: [identifier])
                }
                return
            }
        }
    }

    func cancel() async {
        generation += 1
        let currentGeneration = generation
        retainedIdentifiers = []
        let pending = await center.pendingNotificationRequests()
        guard generation == currentGeneration else { return }
        await center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(PaykitSubscriptionNotificationIdentifier.prefix) }
        )
    }
}

enum PaykitSubscriptionNotificationIdentifier {
    static let prefix = "paykit-subscription-"

    static func identifier(identity: String, subscription: PaykitSubscription, period: PaykitBillingPeriod) -> String {
        "\(prefix)\(identity)|\(subscription.counterparty)|" +
            "\(subscription.counterpartyReceiverPath)|\(subscription.paymentRequestId)|" +
            PaykitSubscriptionTimestamp.string(from: period.startsAt)
    }

    static func identifier(identity: String, requestId: PaykitPaymentRequest.ID) -> String? {
        guard let startsAt = requestId.billingPeriodStartsAt else { return nil }
        return "\(prefix)\(identity)|\(requestId.counterparty)|" +
            "\(requestId.counterpartyReceiverPath)|\(requestId.paymentRequestId)|" +
            PaykitSubscriptionTimestamp.string(from: startsAt)
    }
}

enum PaykitSubscriptionTimestamp {
    static func string(from date: Date) -> String {
        string(from: date, fractionalSeconds: nil)
    }

    static func string(from date: Date, fractionalSeconds: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date) + (fractionalSeconds.map { ".\($0)" } ?? "") + "Z"
    }

    static func fractionalSeconds(from timestamp: String) -> String? {
        let timestamp = canonical(timestamp)
        guard let periodIndex = timestamp.firstIndex(of: "."),
              let zoneIndex = timestamp[periodIndex...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        else { return nil }
        let fraction = timestamp[timestamp.index(after: periodIndex) ..< zoneIndex]
        return fraction.isEmpty ? nil : String(fraction)
    }

    static func canonical(_ timestamp: String) -> String {
        guard timestamp.hasSuffix("Z"),
              let periodIndex = timestamp.firstIndex(of: ".")
        else { return timestamp }

        let fractionStart = timestamp.index(after: periodIndex)
        let zoneIndex = timestamp.index(before: timestamp.endIndex)
        let rawFraction = timestamp[fractionStart ..< zoneIndex]
        guard !rawFraction.isEmpty, rawFraction.allSatisfy(\.isNumber) else { return timestamp }

        let nanoseconds = String(rawFraction.prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0)
        guard let lastNonzeroIndex = nanoseconds.lastIndex(where: { $0 != "0" }) else {
            return String(timestamp[..<periodIndex]) + "Z"
        }
        let significantDigits = nanoseconds.distance(from: nanoseconds.startIndex, to: lastNonzeroIndex) + 1
        let canonicalDigits = min(9, ((significantDigits + 2) / 3) * 3)
        return String(timestamp[..<periodIndex]) + "." + String(nanoseconds.prefix(canonicalDigits)) + "Z"
    }
}
