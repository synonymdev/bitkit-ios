import Foundation
import Paykit

/// Immutable request terms. Market rates are only used when creating request terms.
struct PaykitRequestPricing: Hashable {
    var conversion: Paykit.PaymentConversion?
    var deadline: Paykit.PaymentDeadline?
    var quotes: [Paykit.PaymentConversionQuoteRecord] = []

    struct Payment: Codable, Hashable {
        let amount: PaykitAmount
        let quoteId: String?
        let validFrom: Date?
        let expiresAt: Date?

        func isValid(at date: Date) -> Bool {
            (validFrom.map { date >= $0 } ?? true) && (expiresAt.map { date <= $0 } ?? true)
        }
    }

    func payment(
        requested: PaykitAmount,
        asset: PaykitAsset,
        period: PaykitBillingPeriod?,
        at date: Date,
        quoteId: String? = nil
    ) throws -> Payment {
        let deadline = try paymentDeadline(period: period)
        if requested.asset == asset {
            guard quoteId == nil else { throw PaykitAmountError.invalidAmount }
            return Payment(amount: requested, quoteId: nil, validFrom: nil, expiresAt: deadline)
        }
        let rates: [Paykit.ConversionRate]
        var selected: Paykit.PaymentConversionQuoteRecord?
        switch conversion {
        case let .fixed(values):
            guard quoteId == nil else { throw PaykitAmountError.invalidAmount }
            rates = values
        case .perPeriod:
            guard let period else { throw PaykitAmountError.invalidAmount }
            selected = quotes.last { quote in
                guard let quotedPeriod = PaykitBillingPeriod(sdkPeriod: quote.billingPeriod), quotedPeriod == period else { return false }
                if let quoteId { return quote.eventId == quoteId }
                guard let start = PaykitPaymentRequest.parseDate(quote.validFrom),
                      let end = PaykitPaymentRequest.parseDate(quote.expiresAt)
                else { return false }
                return date >= start && date <= end
            }
            guard let selected else { throw PaykitAmountError.rateUnavailable }
            rates = selected.rates
        case nil:
            // External requests without rates can only be paid in their denominating asset.
            throw PaykitAmountError.rateUnavailable
        }
        guard let rate = rates.first(where: { $0.asset == asset.rawValue }) else { throw PaykitAmountError.rateUnavailable }
        let quoteExpiry = selected.flatMap { PaykitPaymentRequest.parseDate($0.expiresAt) }
        return try Payment(
            amount: requested.quoted(to: asset, multiplier: rate.value),
            quoteId: selected?.eventId,
            validFrom: selected.flatMap { PaykitPaymentRequest.parseDate($0.validFrom) },
            expiresAt: [deadline, quoteExpiry].compactMap { $0 }.min()
        )
    }

    func precisePaymentDeadline(period: PaykitBillingPeriod?) -> PaykitPreciseInstant? {
        guard let deadline,
              let timestamp = try? Paykit.paymentDeadlineAt(deadline: deadline, billingPeriod: period?.sdkValue)
        else { return nil }
        return PaykitPreciseInstant(timestamp: timestamp)
    }

    func paymentDeadline(period: PaykitBillingPeriod?) throws -> Date? {
        switch deadline {
        case nil: return nil
        case let .at(timestamp):
            guard period == nil, let date = PaykitPaymentRequest.parseDate(timestamp) else { throw PaykitAmountError.invalidAmount }
            return date
        case let .periodStart(seconds):
            guard let period, seconds <= UInt64(Int64.max) else { throw PaykitAmountError.invalidAmount }
            return period.startsAt.addingTimeInterval(TimeInterval(seconds))
        }
    }

    static func subscriptionEndpoints(requested: PaykitAsset, available: [String]) -> [String] {
        available.filter {
            guard let method = PublicPaykitService.MethodId(rawValue: $0) else { return false }
            switch requested {
            case .btc: return method != .usdtArbitrum
            case .usd: return method == .usdtArbitrum
            case .usdt: return false
            }
        }
    }

    static func rates(
        requested: PaykitAsset,
        endpoints: [String],
        market: PaykitExchangeRate?,
        at date: Date
    ) throws -> [Paykit.ConversionRate] {
        let assets = Set(endpoints.compactMap { PublicPaykitService.MethodId(rawValue: $0) }
            .map { $0 == .usdtArbitrum ? PaykitAsset.usdt : .btc })
        return try assets.sorted { $0.rawValue < $1.rawValue }.filter { $0 != requested }.map { asset in
            var value = Decimal(1)
            if (requested == .btc) != (asset == .btc) {
                guard let market else { throw PaykitAmountError.rateUnavailable }
                let price = try market.value(at: date)
                value = requested == .btc ? price : Decimal(1) / price
                var rounded = Decimal()
                NSDecimalRound(&rounded, &value, 18, .bankers)
                value = rounded
            }
            guard !value.isNaN, value > 0 else { throw PaykitAmountError.rateUnavailable }
            return Paykit.ConversionRate(asset: asset.rawValue, value: NSDecimalNumber(decimal: value).stringValue)
        }
    }
}
