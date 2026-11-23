import Foundation

/// Prepares a payment request read from an NFC tag or a nearby device for the scanner.
enum ScannedPaymentRequest {
    private static let bitcoinWithoutAddress = "bitcoin:?"
    private static let lightningParams = ["lightning", "lno"]
    private static let requiredParamPrefix = "req-"
    /// Keys BIP 321 ("Query Keys") says must not repeat. `pop` with `req-pop` also counts as a repeat, and any
    /// `req-` key already keeps the URI. Unknown optional keys may repeat.
    private static let singletonParams: Set = ["amount", "label", "message", "pop"]
    /// BOLT11 prefixes, longest first so `lnbcrt` is not read as `lnbc` with an amount.
    private static let bolt11Prefixes = ["lnbcrt", "lntbs", "lnbc", "lntb", "lnsb"]
    private static let bolt11Multipliers: [Character: Decimal] = [
        "m": Decimal(string: "0.001")!,
        "u": Decimal(string: "0.000001")!,
        "n": Decimal(string: "0.000000001")!,
        "p": Decimal(string: "0.000000000001")!,
    ]

    /// A BIP 321 URI may leave the address out and carry only a Lightning request
    /// (`bitcoin:?lightning=<invoice>`, used by Numo and planned by Square). The scanner rejects a `bitcoin:` URI
    /// without an address, so that form becomes `lightning:<invoice>`. A URI with a required (`req-`) parameter is
    /// kept, since BIP 321 forbids paying it without handling that parameter and the rewrite would drop it. So is a URI
    /// that repeats `amount`, `label`, `message` or `pop`, which BIP 321 makes invalid, so the scanner rejects it
    /// instead of paying the invoice alone. A repeated Lightning request is valid BIP 321 but not supported here, since
    /// the rewrite would have to pick one of them, so that URI is kept too. A URI whose `amount` differs from the
    /// invoice's, or that sets an amount for an amountless invoice, is kept too: the scanner cannot carry the outer
    /// amount, so it rejects the request instead of asking for a different one.
    /// Anything else is returned trimmed and unchanged.
    static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(bitcoinWithoutAddress) else { return trimmed }
        var params: [String: String] = [:]
        var keys: Set<String> = []
        for pair in trimmed.dropFirst(bitcoinWithoutAddress.count).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].lowercased()
            // Checked before empty pairs are skipped, since BIP 321 allows a required key with an empty or no value.
            if key.hasPrefix(requiredParamPrefix) {
                return trimmed
            }
            guard !key.isEmpty else { continue }
            guard keys.insert(key).inserted || !singletonParams.contains(key) && !lightningParams.contains(key) else {
                return trimmed
            }
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            params[key] = String(parts[1])
        }
        guard let request = lightningParams.lazy.compactMap({ params[$0] }).first else { return trimmed }
        if let amount = params["amount"] {
            guard let btc = btcAmount(amount), btc == bolt11Amount(request) else { return trimmed }
        }
        return "lightning:\(request)"
    }

    /// A BIP 321 `amount` in BTC: digits with an optional decimal point. `Decimal(string:)` alone would read the
    /// leading number of `0.0000799BTC` or `0.0000799,50`.
    private static func btcAmount(_ value: String) -> Decimal? {
        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard value.contains(where: \.isNumber),
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        return Decimal(string: value)
    }

    /// The amount in BTC that a BOLT11 invoice states in its human-readable part, or nil when it states none.
    private static func bolt11Amount(_ invoice: String) -> Decimal? {
        let lowercase = invoice.lowercased()
        guard let separator = lowercase.lastIndex(of: "1") else { return nil }
        let hrp = lowercase[..<separator]
        guard let prefix = bolt11Prefixes.first(where: { hrp.hasPrefix($0) }) else { return nil }
        var digits = hrp.dropFirst(prefix.count)
        var multiplier: Decimal = 1
        if let last = digits.last, let value = bolt11Multipliers[last] {
            multiplier = value
            digits = digits.dropLast()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Decimal(string: String(digits)) else {
            return nil
        }
        return value * multiplier
    }
}
