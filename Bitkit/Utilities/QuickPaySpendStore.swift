import Foundation

final class QuickPaySpendStore: @unchecked Sendable {
    static let shared = QuickPaySpendStore()

    static let dayKeyDefaultsKey = "quickPaySpendDayKey"
    static let spentSatsDefaultsKey = "quickPaySpentSatsToday"
    static let pendingReservationsDefaultsKey = "quickPayPendingReservations"

    private let defaults: UserDefaults
    private let lock = NSLock()

    struct PendingReservation: Codable, Equatable {
        let amountSats: UInt64
        let dayKey: String
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func dayKey(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func spentSats(forDayKey dayKey: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lockedSpend(forDayKey: dayKey).spentSats
    }

    @discardableResult
    func tryReserve(amountSats: UInt64, dayKey: String, dailyCapSats: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let spend = lockedSpend(forDayKey: dayKey)
        let (total, overflow) = spend.spentSats.addingReportingOverflow(amountSats)
        if overflow || total > dailyCapSats {
            return false
        }

        lockedWrite(dayKey: spend.dayKey, spentSats: total)
        return true
    }

    func release(amountSats: UInt64, dayKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let spend = lockedSpend(forDayKey: dayKey)
        let storedDayKey = defaults.string(forKey: Self.dayKeyDefaultsKey) ?? ""
        guard spend.dayKey == storedDayKey else { return }
        lockedWrite(dayKey: spend.dayKey, spentSats: spend.spentSats > amountSats ? spend.spentSats - amountSats : 0)
    }

    func record(amountSats: UInt64, dayKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let spend = lockedSpend(forDayKey: dayKey)
        let (total, overflow) = spend.spentSats.addingReportingOverflow(amountSats)
        lockedWrite(dayKey: spend.dayKey, spentSats: overflow ? UInt64.max : total)
    }

    func trackPending(paymentHash: String, amountSats: UInt64, dayKey: String) {
        guard !paymentHash.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var pending = lockedPendingReservations()
        pending[paymentHash] = PendingReservation(amountSats: amountSats, dayKey: dayKey)
        lockedWritePending(pending)
    }

    func forgetPending(paymentHash: String) {
        guard !paymentHash.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var pending = lockedPendingReservations()
        pending.removeValue(forKey: paymentHash)
        lockedWritePending(pending)
    }

    func releasePending(paymentHash: String) {
        guard !paymentHash.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var pending = lockedPendingReservations()
        guard let reservation = pending.removeValue(forKey: paymentHash) else { return }
        lockedWritePending(pending)

        let spend = lockedSpend(forDayKey: reservation.dayKey)
        lockedWrite(
            dayKey: spend.dayKey,
            spentSats: spend.spentSats > reservation.amountSats ? spend.spentSats - reservation.amountSats : 0
        )
    }

    private func lockedSpend(forDayKey dayKey: String) -> (dayKey: String, spentSats: UInt64) {
        let storedDayKey = defaults.string(forKey: Self.dayKeyDefaultsKey) ?? ""
        let storedSpend = lockedStoredSpentSats()

        if storedDayKey.isEmpty || dayKey > storedDayKey {
            return (dayKey, 0)
        }
        if dayKey == storedDayKey {
            return (dayKey, storedSpend)
        }
        return (storedDayKey, storedSpend)
    }

    private func lockedStoredSpentSats() -> UInt64 {
        UInt64(max(defaults.integer(forKey: Self.spentSatsDefaultsKey), 0))
    }

    private func lockedWrite(dayKey: String, spentSats: UInt64) {
        defaults.set(dayKey, forKey: Self.dayKeyDefaultsKey)
        defaults.set(Int(clamping: spentSats), forKey: Self.spentSatsDefaultsKey)
    }

    private func lockedPendingReservations() -> [String: PendingReservation] {
        guard let data = defaults.data(forKey: Self.pendingReservationsDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: PendingReservation].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private func lockedWritePending(_ pending: [String: PendingReservation]) {
        if pending.isEmpty {
            defaults.removeObject(forKey: Self.pendingReservationsDefaultsKey)
            return
        }

        defaults.set(try? JSONEncoder().encode(pending), forKey: Self.pendingReservationsDefaultsKey)
    }
}
