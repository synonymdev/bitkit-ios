import Foundation

enum QuickPayLimits {
    static let usdCurrencyCode = "USD"
    static let thresholdSteps: [Double] = [1, 5, 10, 20, 50]
    static let dailyMultiplierSteps: [Double] = [1, 3, 5, 10, 50]
    static let defaultThresholdUsd: Double = 5
    static let defaultDailyMultiplier: Double = 5

    static func amountWithFeeSats(amountSats: UInt64, feePaidSats: UInt64) -> UInt64 {
        let (total, overflow) = amountSats.addingReportingOverflow(feePaidSats)
        return overflow ? UInt64.max : total
    }

    static func sanitizedMultiplier(_ value: Double) -> Double {
        dailyMultiplierSteps.contains(value) ? value : defaultDailyMultiplier
    }

    static func dailyCapUsdDisplay(thresholdUsd: Double, multiplier: Double) -> Int {
        Int(thresholdUsd) * Int(sanitizedMultiplier(multiplier))
    }

    static func thresholdCents(_ thresholdUsd: Double) -> Int64 {
        Int64(Int(thresholdUsd)) * 100
    }

    static func capCents(thresholdUsd: Double, multiplier: Double) -> Int64 {
        thresholdCents(thresholdUsd) * Int64(Int(sanitizedMultiplier(multiplier)))
    }

    static func reserveCents(convertedCents: Int64, thresholdUsd: Double, amountSats: UInt64) -> Int64 {
        let clamped = min(convertedCents, thresholdCents(thresholdUsd))
        if amountSats == 0 {
            return clamped
        }
        return max(clamped, 1)
    }

    static func usdCents(from converted: ConvertedAmount) -> Int64 {
        var cents = converted.value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &cents, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    @MainActor
    static func paymentAmountSats(app: AppViewModel) -> UInt64? {
        if let lnurlPayData = app.lnurlPayData {
            guard lnurlPayData.isFixedAmount else { return nil }
            return lnurlPayData.minSendableSat
        }

        return app.scannedLightningInvoice?.amountSatoshis
    }
}
