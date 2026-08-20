import Foundation

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

final class QuickPaySpendStore: @unchecked Sendable {
    static let shared = QuickPaySpendStore()

    static let dayKeyDefaultsKey = "quickPaySpendDayKey"
    static let spentCentsDefaultsKey = "quickPaySpentCentsToday"
    static let reservationsDefaultsKey = "quickPayReservations"

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

        let reserveCents = QuickPayLimits.reserveCents(convertedCents: convertedCents, thresholdUsd: thresholdUsd)
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

    func tryReserve(
        amountSats: UInt64,
        thresholdUsd: Double,
        multiplier: Double,
        rates: QuickPaySpendRates
    ) throws -> QuickPaySpendReservation? {
        guard let convertedCents = rates.satsToUsdCents(amountSats) else {
            throw QuickPayConversionError()
        }

        let amountCents = QuickPayLimits.reserveCents(convertedCents: convertedCents, thresholdUsd: thresholdUsd)
        let capCents = QuickPayLimits.capCents(thresholdUsd: thresholdUsd, multiplier: multiplier)

        lock.lock()
        defer { lock.unlock() }

        let spend = lockedSpend(forDayKey: dayKeyProvider())
        let (total, overflow) = spend.spentCents.addingReportingOverflow(amountCents)
        if overflow || total > capCents {
            return nil
        }

        lockedWriteSpend(dayKey: spend.dayKey, spentCents: total)
        return QuickPaySpendReservation(amountCents: amountCents, dayKey: spend.dayKey)
    }

    func remember(paymentHash: String, reservation: QuickPaySpendReservation) {
        guard !paymentHash.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var reservations = lockedReservations()
        reservations[paymentHash] = reservation
        lockedWriteReservations(reservations)
    }

    func reservation(paymentHash: String) -> QuickPaySpendReservation? {
        guard !paymentHash.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }
        return lockedReservations()[paymentHash]
    }

    func release(paymentHash: String) {
        guard !paymentHash.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var reservations = lockedReservations()
        guard let reservation = reservations.removeValue(forKey: paymentHash) else { return }
        lockedWriteReservations(reservations)

        let spend = lockedSpend(forDayKey: reservation.dayKey)
        guard reservation.dayKey == spend.dayKey else { return }
        lockedWriteSpend(dayKey: spend.dayKey, spentCents: max(spend.spentCents - reservation.amountCents, 0))
    }

    func releaseUnbound(_ reservation: QuickPaySpendReservation) {
        lock.lock()
        defer { lock.unlock() }

        let storedDayKey = lockedStoredDayKey()
        guard reservation.dayKey == storedDayKey else { return }
        lockedWriteSpend(dayKey: storedDayKey, spentCents: max(lockedStoredSpentCents() - reservation.amountCents, 0))
    }

    func clear(paymentHash: String) {
        guard !paymentHash.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var reservations = lockedReservations()
        guard reservations.removeValue(forKey: paymentHash) != nil else { return }
        lockedWriteReservations(reservations)
    }

    func backupSnapshot() -> (dayKey: String, spentCents: Int64, reservations: [String: QuickPaySpendReservation]) {
        lock.lock()
        defer { lock.unlock() }
        return (lockedStoredDayKey(), lockedStoredSpentCents(), lockedReservations())
    }

    func restoreFromBackup(dayKey: String, spentCents: Int64, reservations: [String: QuickPaySpendReservation]) {
        lock.lock()
        defer { lock.unlock() }
        lockedWriteSpend(dayKey: dayKey, spentCents: max(spentCents, 0))
        lockedWriteReservations(reservations)
    }

    private func lockedSpend(forDayKey dayKey: String) -> (dayKey: String, spentCents: Int64) {
        let storedDayKey = lockedStoredDayKey()
        let storedCents = lockedStoredSpentCents()

        if storedDayKey.isEmpty || dayKey > storedDayKey {
            return (dayKey, 0)
        }
        if dayKey == storedDayKey {
            return (dayKey, storedCents)
        }
        return (storedDayKey, storedCents)
    }

    private func lockedStoredDayKey() -> String {
        defaults.string(forKey: Self.dayKeyDefaultsKey) ?? ""
    }

    private func lockedStoredSpentCents() -> Int64 {
        Int64(max(defaults.integer(forKey: Self.spentCentsDefaultsKey), 0))
    }

    private func lockedWriteSpend(dayKey: String, spentCents: Int64) {
        defaults.set(dayKey, forKey: Self.dayKeyDefaultsKey)
        defaults.set(Int(clamping: spentCents), forKey: Self.spentCentsDefaultsKey)
    }

    private func lockedReservations() -> [String: QuickPaySpendReservation] {
        guard let data = defaults.data(forKey: Self.reservationsDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: QuickPaySpendReservation].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private func lockedWriteReservations(_ reservations: [String: QuickPaySpendReservation]) {
        if reservations.isEmpty {
            defaults.removeObject(forKey: Self.reservationsDefaultsKey)
            return
        }

        defaults.set(try? JSONEncoder().encode(reservations), forKey: Self.reservationsDefaultsKey)
    }
}
