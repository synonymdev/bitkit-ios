import Foundation
import LDKNode

struct QuickPaySpendReservation: Codable, Equatable {
    let amountCents: Int64
    let dayKey: String
}

struct QuickPayConversionError: Error {}

struct QuickPaySpendRates {
    let satsToUsdCents: (UInt64) -> Int64?
    let usdToSats: (Double) -> UInt64?

    @MainActor
    static func live(_ currency: CurrencyViewModel) -> QuickPaySpendRates {
        QuickPaySpendRates(
            satsToUsdCents: { sats in
                guard let converted = currency.convert(sats: sats, to: QuickPayLimits.usdCurrencyCode) else {
                    return nil
                }
                return QuickPayLimits.usdCents(from: converted)
            },
            usdToSats: { usd in
                currency.convert(fiatAmount: usd, from: QuickPayLimits.usdCurrencyCode)
            }
        )
    }
}

struct QuickPayLedgerRecord: Codable, Equatable {
    let amountCents: Int64
    let dayKey: String
    let invoicePaymentHash: String
    var paymentId: String?
}

struct QuickPayLedger: Codable, Equatable {
    var dayKey: String
    var spentCents: Int64
    var records: [QuickPayLedgerRecord]
}

struct QuickPayCompletionOutcome: Equatable {
    enum Kind: Equatable {
        case none
        case settledSuccess
        case settledFailure
    }

    let kind: Kind
    let invoicePaymentHash: String?

    var wasQuickPay: Bool {
        kind != .none
    }

    static let none = QuickPayCompletionOutcome(kind: .none, invoicePaymentHash: nil)

    static func settledSuccess(invoicePaymentHash: String) -> QuickPayCompletionOutcome {
        QuickPayCompletionOutcome(kind: .settledSuccess, invoicePaymentHash: invoicePaymentHash)
    }

    static func settledFailure(invoicePaymentHash: String) -> QuickPayCompletionOutcome {
        QuickPayCompletionOutcome(kind: .settledFailure, invoicePaymentHash: invoicePaymentHash)
    }
}

struct QuickPayReconcileRow {
    let paymentId: String
    let invoicePaymentHash: String
    let isOutboundBolt11: Bool
    let status: Status

    enum Status {
        case succeeded
        case failed
        case pending
    }

    init(payment: PaymentDetails) {
        paymentId = payment.id
        isOutboundBolt11 = payment.direction == .outbound && {
            if case .bolt11 = payment.kind {
                return true
            }
            return false
        }()
        invoicePaymentHash = {
            if case let .bolt11(hash, _, _, _, _) = payment.kind {
                return String(hash)
            }
            return payment.id
        }()
        status = switch payment.status {
        case .succeeded: .succeeded
        case .failed: .failed
        case .pending: .pending
        }
    }

    init(paymentId: String, invoicePaymentHash: String, isOutboundBolt11: Bool, status: Status) {
        self.paymentId = paymentId
        self.invoicePaymentHash = invoicePaymentHash
        self.isOutboundBolt11 = isOutboundBolt11
        self.status = status
    }
}

final class QuickPaySpendStore: @unchecked Sendable {
    static let shared = QuickPaySpendStore()

    static let ledgerDefaultsKey = "quickPayLedger"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let dayKeyProvider: () -> String

    init(defaults: UserDefaults = .standard, dayKey: @escaping () -> String = { QuickPaySpendStore.dayKey() }) {
        self.defaults = defaults
        dayKeyProvider = dayKey
    }

    static func dayKey(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func spentCentsToday() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return lockedSpend(forDayKey: dayKeyProvider()).spentCents
    }

    func canApply(
        amountSats: UInt64,
        enabled: Bool,
        thresholdUsd: Double,
        multiplier: Double,
        rates: QuickPaySpendRates
    ) -> Bool {
        guard enabled, amountSats > 0 else { return false }
        guard let thresholdSats = rates.usdToSats(thresholdUsd), thresholdSats > 0 else { return false }
        if amountSats > thresholdSats {
            return false
        }
        guard let convertedCents = rates.satsToUsdCents(amountSats) else { return false }

        let reserveCents = QuickPayLimits.reserveCents(convertedCents: convertedCents, thresholdUsd: thresholdUsd, amountSats: amountSats)
        let capCents = QuickPayLimits.capCents(thresholdUsd: thresholdUsd, multiplier: multiplier)

        lock.lock()
        defer { lock.unlock() }
        let spentCents = lockedSpend(forDayKey: dayKeyProvider()).spentCents
        let (total, overflow) = spentCents.addingReportingOverflow(reserveCents)
        if !overflow, total <= capCents {
            return true
        }

        Logger.info(
            "Skipping QuickPay: daily spend '\(spentCents)' + '\(reserveCents)' exceeds cap '\(capCents)'"
        )
        return false
    }

    func record(matching hash: String) -> QuickPayLedgerRecord? {
        lock.lock()
        defer { lock.unlock() }
        return lockedRecord(matching: hash)
    }

    func reserveBound(
        paymentHash: String,
        amountSats: UInt64,
        thresholdUsd: Double,
        multiplier: Double,
        rates: QuickPaySpendRates,
        keepHashes: Set<String> = []
    ) throws -> QuickPayLedgerRecord? {
        guard !paymentHash.isEmpty else { return nil }
        guard let thresholdSats = rates.usdToSats(thresholdUsd), thresholdSats > 0, amountSats <= thresholdSats else {
            return nil
        }
        guard let convertedCents = rates.satsToUsdCents(amountSats) else {
            throw QuickPayConversionError()
        }

        let amountCents = QuickPayLimits.reserveCents(convertedCents: convertedCents, thresholdUsd: thresholdUsd, amountSats: amountSats)
        let capCents = QuickPayLimits.capCents(thresholdUsd: thresholdUsd, multiplier: multiplier)

        lock.lock()
        defer { lock.unlock() }

        if lockedRecord(matching: paymentHash) != nil {
            return nil
        }

        let spend = lockedSpend(forDayKey: dayKeyProvider())
        let (total, overflow) = spend.spentCents.addingReportingOverflow(amountCents)
        if overflow || total > capCents {
            return nil
        }

        var ledger = lockedLedger()
        lockedPrune(ledger: &ledger, currentDay: spend.dayKey, keepHashes: keepHashes)
        let record = QuickPayLedgerRecord(
            amountCents: amountCents,
            dayKey: spend.dayKey,
            invoicePaymentHash: paymentHash,
            paymentId: nil
        )
        ledger.dayKey = spend.dayKey
        ledger.spentCents = total
        ledger.records.append(record)
        lockedWriteLedger(ledger)
        return record
    }

    func markSubmitted(invoicePaymentHash: String, paymentId: String?) {
        guard !invoicePaymentHash.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var ledger = lockedLedger()
        guard let index = lockedRecordIndex(in: ledger, matching: invoicePaymentHash) else { return }
        ledger.records[index].paymentId = paymentId
        lockedWriteLedger(ledger)
    }

    @discardableResult
    func signalCompletion(paymentId: String?, paymentHash: String?, success: Bool) -> QuickPayCompletionOutcome {
        lock.lock()
        defer { lock.unlock() }
        var ledger = lockedLedger()
        let keys = [paymentId, paymentHash].compactMap { $0 }.filter { !$0.isEmpty }
        guard let index = keys.compactMap({ key in lockedRecordIndex(in: ledger, matching: key) }).first else {
            return .none
        }
        let record = ledger.records.remove(at: index)
        if !success, record.dayKey == ledger.dayKey {
            ledger.spentCents = max(ledger.spentCents - record.amountCents, 0)
        }
        lockedWriteLedger(ledger)
        return success
            ? .settledSuccess(invoicePaymentHash: record.invoicePaymentHash)
            : .settledFailure(invoicePaymentHash: record.invoicePaymentHash)
    }

    func releaseBound(paymentHash: String) {
        lock.lock()
        defer { lock.unlock() }
        var ledger = lockedLedger()
        guard let index = lockedRecordIndex(in: ledger, matching: paymentHash) else { return }
        let record = ledger.records.remove(at: index)
        if record.dayKey == ledger.dayKey {
            ledger.spentCents = max(ledger.spentCents - record.amountCents, 0)
        }
        lockedWriteLedger(ledger)
    }

    func dropBound(paymentHash: String) {
        lock.lock()
        defer { lock.unlock() }
        var ledger = lockedLedger()
        guard let index = lockedRecordIndex(in: ledger, matching: paymentHash) else { return }
        ledger.records.remove(at: index)
        lockedWriteLedger(ledger)
    }

    func reconcile(
        rows: [QuickPayReconcileRow]?,
        liveSubmittingHashes: Set<String>,
        shouldReleaseFailed: ((QuickPayLedgerRecord, QuickPayReconcileRow) -> Bool)? = nil
    ) {
        guard let rows else { return }

        lock.lock()
        defer { lock.unlock() }
        var ledger = lockedLedger()
        let currentDay = dayKeyProvider()
        lockedPrune(ledger: &ledger, currentDay: currentDay, keepHashes: liveSubmittingHashes)

        var didWrite = false
        var remaining: [QuickPayLedgerRecord] = []
        remaining.reserveCapacity(ledger.records.count)

        for record in ledger.records {
            if liveSubmittingHashes.contains(record.invoicePaymentHash) {
                remaining.append(record)
                continue
            }
            guard let match = Self.ledgerMatch(record: record, rows: rows) else {
                remaining.append(record)
                continue
            }
            switch match.status {
            case .pending:
                remaining.append(record)
            case .succeeded:
                didWrite = true
            case .failed:
                if let shouldReleaseFailed, !shouldReleaseFailed(record, match) {
                    remaining.append(record)
                    continue
                }
                if record.dayKey == ledger.dayKey {
                    ledger.spentCents = max(ledger.spentCents - record.amountCents, 0)
                }
                didWrite = true
            }
        }

        if didWrite || remaining.count != ledger.records.count {
            ledger.records = remaining
            lockedWriteLedger(ledger)
        }
    }

    func backupSnapshot() -> (
        dayKey: String,
        spentCents: Int64,
        reservations: [String: QuickPaySpendReservation]
    ) {
        lock.lock()
        defer { lock.unlock() }
        let ledger = lockedLedger()
        var reservations: [String: QuickPaySpendReservation] = [:]
        for record in ledger.records {
            reservations[record.invoicePaymentHash] = QuickPaySpendReservation(
                amountCents: record.amountCents,
                dayKey: record.dayKey
            )
        }
        return (ledger.dayKey, ledger.spentCents, reservations)
    }

    func restoreFromBackup(
        dayKey: String,
        spentCents: Int64,
        reservations: [String: QuickPaySpendReservation]
    ) {
        lock.lock()
        defer { lock.unlock() }
        var records: [QuickPayLedgerRecord] = []
        for (hash, reservation) in reservations {
            records.append(
                QuickPayLedgerRecord(
                    amountCents: reservation.amountCents,
                    dayKey: reservation.dayKey,
                    invoicePaymentHash: hash,
                    paymentId: nil
                )
            )
        }
        lockedWriteLedger(QuickPayLedger(dayKey: dayKey, spentCents: max(spentCents, 0), records: records))
    }

    private func lockedSpend(forDayKey dayKey: String) -> (dayKey: String, spentCents: Int64) {
        var ledger = lockedLedger()
        if ledger.dayKey.isEmpty || dayKey > ledger.dayKey {
            ledger.dayKey = dayKey
            ledger.spentCents = 0
            lockedWriteLedger(ledger)
            return (dayKey, 0)
        }
        if dayKey == ledger.dayKey {
            return (dayKey, ledger.spentCents)
        }
        return (ledger.dayKey, ledger.spentCents)
    }

    private func lockedPrune(ledger: inout QuickPayLedger, currentDay: String, keepHashes: Set<String> = []) {
        guard !currentDay.isEmpty else { return }
        ledger.records.removeAll { $0.dayKey < currentDay && !keepHashes.contains($0.invoicePaymentHash) }
    }

    private func lockedRecord(matching hash: String) -> QuickPayLedgerRecord? {
        guard let index = lockedRecordIndex(in: lockedLedger(), matching: hash) else { return nil }
        return lockedLedger().records[index]
    }

    private func lockedRecordIndex(in ledger: QuickPayLedger, matching hash: String) -> Int? {
        ledger.records.firstIndex {
            $0.invoicePaymentHash == hash || $0.paymentId == hash
        }
    }

    private func lockedLedger() -> QuickPayLedger {
        guard let data = defaults.data(forKey: Self.ledgerDefaultsKey),
              let decoded = try? JSONDecoder().decode(QuickPayLedger.self, from: data)
        else {
            return QuickPayLedger(dayKey: "", spentCents: 0, records: [])
        }
        return decoded
    }

    private func lockedWriteLedger(_ ledger: QuickPayLedger) {
        defaults.set(try? JSONEncoder().encode(ledger), forKey: Self.ledgerDefaultsKey)
    }

    static func ledgerMatch(record: QuickPayLedgerRecord, rows: [QuickPayReconcileRow]) -> QuickPayReconcileRow? {
        let matches = rows.filter { row in
            row.isOutboundBolt11 && (
                row.invoicePaymentHash == record.invoicePaymentHash
                    || row.paymentId == record.invoicePaymentHash
                    || row.paymentId == record.paymentId
                    || (record.paymentId != nil && row.invoicePaymentHash == record.paymentId)
            )
        }
        if matches.isEmpty {
            return nil
        }
        if let paymentId = record.paymentId, let exact = matches.first(where: { $0.paymentId == paymentId }) {
            return exact
        }
        return matches.max { lhs, rhs in
            lhs.status.rank < rhs.status.rank
        }
    }
}

private extension QuickPayReconcileRow.Status {
    var rank: Int {
        switch self {
        case .succeeded: 2
        case .pending: 1
        case .failed: 0
        }
    }
}
