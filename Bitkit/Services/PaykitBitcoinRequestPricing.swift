import Foundation
import Paykit

enum PaykitBitcoinRequestPricing {
    private static let maxSignificantDigits = 38

    struct BitcoinPayment {
        let amountSats: UInt64
        let endpointIdentifiers: [String]
    }

    static func bitcoinPayment(terms: PaymentRequestTerms, endpoints: [String]) -> BitcoinPayment? {
        guard case let .fixed(rates) = terms.conversion,
              !rates.isEmpty,
              Set(rates.map(\.asset)).count == rates.count,
              let requestedAmount = positiveDecimal(terms.amount.value)
        else { return nil }

        var amountSats: UInt64?
        var payableEndpoints: [String] = []
        for endpoint in endpoints {
            let selector = endpoint.split(separator: "-").prefix(2).joined(separator: "-")
            let rate = rates.first { $0.asset == selector } ?? rates.first { $0.asset == "btc" }
            guard let rateValue = rate?.value ?? (terms.amount.asset == "btc" ? "1" : nil) else { continue }
            guard let multiplier = positiveDecimal(rateValue),
                  significantDigits(terms.amount.value) + significantDigits(rateValue) <= maxSignificantDigits,
                  let sats = sats(amount: requestedAmount, rate: multiplier, lightning: selector == "btc-lightning")
            else { return nil }
            // The send sheet can switch rails without asking the user to approve a different amount.
            guard amountSats == nil || amountSats == sats else { return nil }
            amountSats = sats
            payableEndpoints.append(endpoint)
        }
        guard let amountSats else { return nil }
        return BitcoinPayment(amountSats: amountSats, endpointIdentifiers: payableEndpoints)
    }

    private static func sats(amount: Decimal, rate: Decimal, lightning: Bool) -> UInt64? {
        var amount = amount
        var rate = rate
        var bitcoin = Decimal()
        guard NSDecimalMultiply(&bitcoin, &amount, &rate, .plain) == .noError else { return nil }
        var units = Decimal()
        guard NSDecimalMultiplyByPowerOf10(&units, &bitcoin, lightning ? 11 : 8, .plain) == .noError else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &units, 0, .up)
        guard let integer = UInt64(NSDecimalNumber(decimal: rounded).stringValue), integer > 0 else { return nil }
        // Bitkit pays whole satoshis; never silently round a millisatoshi quote up again.
        guard !lightning || integer.isMultiple(of: 1000) else { return nil }
        let sats = lightning ? integer / 1000 : integer
        return sats <= UInt64.max / 1000 ? sats : nil
    }

    private static func significantDigits(_ value: String) -> Int {
        value.filter { $0 != "." }.drop(while: { $0 == "0" }).reversed().drop(while: { $0 == "0" }).count
    }

    private static func positiveDecimal(_ value: String) -> Decimal? {
        guard value.count <= 80,
              value.range(of: #"\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z"#, options: .regularExpression) != nil,
              value.filter({ $0 != "." }).drop(while: { $0 == "0" }).count <= maxSignificantDigits,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              decimal > 0
        else { return nil }
        return decimal
    }
}
