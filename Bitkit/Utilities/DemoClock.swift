import Foundation

/// Dev-only offset that moves Paykit subscription scheduling forward, so a recorded demo can show a renewal
/// without waiting a whole billing period. It covers subscription proposals, acceptance, due periods, renewal
/// dates and due notifications. One-time payment requests, invoices, payments and allowance checks keep real time.
enum DemoClock {
    static let offsetDaysKey = "demoClockOffsetDays"
    static let offsetDaysRange = 0 ... 400
    static let offsetDaysPresets = [0, 1, 7, 30, 31, 62, 365]

    static var isAvailable: Bool {
        Env.isDebug
    }

    static func offsetDays(defaults: UserDefaults = .standard, isAvailable: Bool = Self.isAvailable) -> Int {
        guard isAvailable else { return 0 }
        return clampedOffsetDays(defaults.integer(forKey: offsetDaysKey))
    }

    static func clampedOffsetDays(_ days: Int) -> Int {
        min(max(days, offsetDaysRange.lowerBound), offsetDaysRange.upperBound)
    }

    static func subscriptionDate(
        from date: Date,
        defaults: UserDefaults = .standard,
        isAvailable: Bool = Self.isAvailable
    ) -> Date {
        let days = offsetDays(defaults: defaults, isAvailable: isAvailable)
        guard days != 0 else { return date }
        return date.addingTimeInterval(TimeInterval(days) * 24 * 60 * 60)
    }

    static func subscriptionNow() -> Date {
        subscriptionDate(from: Date())
    }
}
