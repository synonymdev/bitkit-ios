import Foundation

final class QuickPaySpendStore: @unchecked Sendable {
    static let shared = QuickPaySpendStore()

    static let dayKeyDefaultsKey = "quickPaySpendDayKey"
    static let spentUsdDefaultsKey = "quickPaySpentUsdToday"

    private let defaults: UserDefaults
    private let lock = NSLock()

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

    private func lockedSpentUsd(forDayKey dayKey: String) -> Double {
        guard defaults.string(forKey: Self.dayKeyDefaultsKey) == dayKey else { return 0 }
        return defaults.double(forKey: Self.spentUsdDefaultsKey)
    }

    private func lockedWrite(dayKey: String, spentUsd: Double) {
        defaults.set(dayKey, forKey: Self.dayKeyDefaultsKey)
        defaults.set(spentUsd, forKey: Self.spentUsdDefaultsKey)
    }
}
