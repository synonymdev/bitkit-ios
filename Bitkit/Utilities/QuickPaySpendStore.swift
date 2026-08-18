import Foundation

final class QuickPaySpendStore: @unchecked Sendable {
    static let shared = QuickPaySpendStore()

    static let dayKeyDefaultsKey = "quickPaySpendDayKey"
    static let spentUsdDefaultsKey = "quickPaySpentUsdToday"
    static let pendingReservationsDefaultsKey = "quickPayPendingReservations"

    private let defaults: UserDefaults
    private let lock = NSLock()

    struct PendingReservation: Codable, Equatable {
        let amountUsd: Double
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

    func spentUsd(forDayKey dayKey: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return lockedSpentUsd(forDayKey: dayKey)
    }

    @discardableResult
    func tryReserve(amountUsd: Double, dayKey: String, dailyCapUsd: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let spent = lockedSpentUsd(forDayKey: dayKey)
        if spent + amountUsd > dailyCapUsd {
            return false
        }

        lockedWrite(dayKey: dayKey, spentUsd: spent + amountUsd)
        return true
    }

    func release(amountUsd: Double, dayKey: String) {
        lock.lock()
        defer { lock.unlock() }

        guard defaults.string(forKey: Self.dayKeyDefaultsKey) == dayKey else { return }
        let spent = defaults.double(forKey: Self.spentUsdDefaultsKey)
        lockedWrite(dayKey: dayKey, spentUsd: max(spent - amountUsd, 0))
    }

    func record(amountUsd: Double, dayKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let spent = lockedSpentUsd(forDayKey: dayKey)
        lockedWrite(dayKey: dayKey, spentUsd: spent + amountUsd)
    }

    func trackPending(paymentHash: String, amountUsd: Double, dayKey: String) {
        lock.lock()
        defer { lock.unlock() }

        var pending = lockedPendingReservations()
        pending[paymentHash] = PendingReservation(amountUsd: amountUsd, dayKey: dayKey)
        lockedWritePending(pending)
    }

    func forgetPending(paymentHash: String) {
        lock.lock()
        defer { lock.unlock() }

        var pending = lockedPendingReservations()
        pending.removeValue(forKey: paymentHash)
        lockedWritePending(pending)
    }

    func releasePending(paymentHash: String) {
        lock.lock()
        defer { lock.unlock() }

        var pending = lockedPendingReservations()
        guard let reservation = pending.removeValue(forKey: paymentHash) else { return }
        lockedWritePending(pending)

        guard defaults.string(forKey: Self.dayKeyDefaultsKey) == reservation.dayKey else { return }
        let spent = defaults.double(forKey: Self.spentUsdDefaultsKey)
        lockedWrite(dayKey: reservation.dayKey, spentUsd: max(spent - reservation.amountUsd, 0))
    }

    private func lockedSpentUsd(forDayKey dayKey: String) -> Double {
        guard defaults.string(forKey: Self.dayKeyDefaultsKey) == dayKey else { return 0 }
        return defaults.double(forKey: Self.spentUsdDefaultsKey)
    }

    private func lockedWrite(dayKey: String, spentUsd: Double) {
        defaults.set(dayKey, forKey: Self.dayKeyDefaultsKey)
        defaults.set(spentUsd, forKey: Self.spentUsdDefaultsKey)
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
