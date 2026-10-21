import Foundation

struct PaykitAmountEntryConversion {
    private var source: PaykitAmount?
    private var result: PaykitAmount?

    mutating func converted(_ amount: PaykitAmount?, to asset: PaykitAsset, rate: PaykitExchangeRate?, at date: Date) throws -> PaykitAmount {
        guard let amount, amount.atomic > 0 else {
            reset()
            return PaykitAmount(asset: asset, atomic: 0)
        }
        let source = amount == result ? source ?? amount : amount
        let converted = try source.converted(to: asset, rate: rate, at: date)
        self.source = source
        result = converted
        return converted
    }

    mutating func reset() {
        source = nil
        result = nil
    }
}

func parsePaykitAmountInput(asset: PaykitAsset, value: String) throws -> PaykitAmount {
    let normalized = value.hasSuffix(".") ? String(value.dropLast()) : value
    return try PaykitAmount(asset: asset, value: normalized)
}
