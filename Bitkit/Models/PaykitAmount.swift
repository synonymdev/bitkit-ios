import Foundation

enum PaykitAsset: String, Codable, CaseIterable {
    case btc
    case usd
    case usdt

    var decimals: Int {
        switch self {
        case .btc: 8
        case .usd: 2
        case .usdt: 6
        }
    }
}

enum PaykitAmountError: LocalizedError, Equatable {
    case invalidAmount
    case rateUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAmount: t("wallet__payment_request_mismatch")
        case .rateUnavailable: t("wallet__payment_request_rate_unavailable")
        }
    }
}

struct PaykitExchangeRate: Codable, Equatable, Hashable {
    static let maximumAge: TimeInterval = 10 * 60
    private static let maximumPriceDigits = 18

    let price: String
    let timestamp: Date

    func value(at date: Date) throws -> Decimal {
        guard timestamp <= date, date.timeIntervalSince(timestamp) <= Self.maximumAge,
              price.filter({ $0 != "." }).count <= Self.maximumPriceDigits,
              price.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value > 0
        else { throw PaykitAmountError.rateUnavailable }
        return value
    }
}

struct PaykitAmount: Codable, Hashable {
    let asset: PaykitAsset
    let atomic: UInt64

    init(asset: PaykitAsset, atomic: UInt64) {
        self.asset = asset
        self.atomic = atomic
    }

    init(asset: PaykitAsset, value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2, !parts[0].isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48 ... 57).contains($0) } }),
              let whole = UInt64(parts[0])
        else { throw PaykitAmountError.invalidAmount }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        while fraction.last == "0" {
            fraction.removeLast()
        }
        guard fraction.count <= asset.decimals else { throw PaykitAmountError.invalidAmount }
        let fractional = UInt64(fraction.padding(toLength: asset.decimals, withPad: "0", startingAt: 0)) ?? 0
        let (base, overflow) = whole.multipliedReportingOverflow(by: NSDecimalNumber(decimal: Self.scale(asset)).uint64Value)
        let (atomic, additionOverflow) = base.addingReportingOverflow(fractional)
        guard !overflow, !additionOverflow, atomic > 0 else { throw PaykitAmountError.invalidAmount }
        self.init(asset: asset, atomic: atomic)
    }

    var value: String {
        NSDecimalNumber(decimal: Decimal(atomic) / Self.scale(asset)).stringValue
    }

    func converted(to paymentAsset: PaykitAsset, rate: PaykitExchangeRate?, at date: Date) throws -> PaykitAmount {
        let value = try value(in: paymentAsset, rate: rate, at: date)
        return try PaykitAmount(asset: paymentAsset, atomic: Self.integer(value * Self.scale(paymentAsset), rounding: .up))
    }

    func quoted(to asset: PaykitAsset, multiplier: String) throws -> PaykitAmount {
        guard multiplier.count <= 80,
              multiplier.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "0")).count <= 38,
              multiplier.range(of: "^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$", options: .regularExpression) != nil,
              let rate = Decimal(string: multiplier, locale: Locale(identifier: "en_US_POSIX")),
              !rate.isNaN, rate > 0
        else { throw PaykitAmountError.rateUnavailable }
        var amount = Decimal(atomic)
        var factor = rate
        var product = Decimal()
        guard NSDecimalMultiply(&product, &amount, &factor, .plain) == .noError else { throw PaykitAmountError.invalidAmount }
        let shift = asset.decimals - self.asset.decimals
        var scaled = Decimal()
        guard NSDecimalMultiplyByPowerOf10(&scaled, &product, Int16(shift), .plain) == .noError else {
            throw PaykitAmountError.invalidAmount
        }
        return try PaykitAmount(asset: asset, atomic: Self.integer(scaled, rounding: .up))
    }

    private func value(in target: PaykitAsset, rate: PaykitExchangeRate?, at date: Date) throws -> Decimal {
        let amount = Decimal(atomic) / Self.scale(asset)
        guard (asset == .btc) != (target == .btc) else { return amount }
        guard let rate else { throw PaykitAmountError.rateUnavailable }
        let price = try rate.value(at: date)
        return asset == .btc ? amount * price : amount / price
    }

    private static func scale(_ asset: PaykitAsset) -> Decimal {
        pow(Decimal(10), asset.decimals)
    }

    private static func integer(_ value: Decimal, rounding: Decimal.RoundingMode) throws -> UInt64 {
        guard !value.isNaN else { throw PaykitAmountError.invalidAmount }
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, rounding)
        guard rounded >= 0, rounded <= Decimal(UInt64.max) else { throw PaykitAmountError.invalidAmount }
        return NSDecimalNumber(decimal: rounded).uint64Value
    }
}
