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
        Int(thresholdUsd) * Int(multiplier)
    }

    @MainActor
    static func paymentAmountSats(app: AppViewModel) -> UInt64? {
        if let lnurlPayData = app.lnurlPayData {
            guard lnurlPayData.isFixedAmount else { return nil }
            return lnurlPayData.minSendableSat
        }

        return app.scannedLightningInvoice?.amountSatoshis
    }

    @MainActor
    static func dailyCapUsd(
        thresholdUsd: Double,
        multiplier: Double,
        currency: CurrencyViewModel
    ) -> Double? {
        guard let thresholdSats = currency.convert(fiatAmount: thresholdUsd, from: usdCurrencyCode), thresholdSats > 0 else {
            return nil
        }

        let dailyCapSats = thresholdSats * UInt64(max(multiplier, 1).rounded())
        return usdValue(sats: dailyCapSats, currency: currency)
    }

    @MainActor
    static func usdValue(sats: UInt64, currency: CurrencyViewModel) -> Double? {
        guard let converted = currency.convert(sats: sats, to: usdCurrencyCode) else { return nil }
        return (converted.value as NSDecimalNumber).doubleValue
    }
}
