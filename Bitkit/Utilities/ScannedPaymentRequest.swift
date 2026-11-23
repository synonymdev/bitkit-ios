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
    /// instead of paying the invoice alone. A repeated `lightning` invoice is valid BIP 321 but not supported here,
    /// since the rewrite would have to pick one of them, so that URI is kept too. Offers (`lno`), which the decoder
    /// does not read, may repeat and are skipped when an invoice is present. A URI whose `amount` differs from the
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
            // BOLT12 offers (`lno`) may repeat beside the invoice; only a second BOLT11 invoice is ambiguous.
            guard keys.insert(key).inserted || (!singletonParams.contains(key) && key != "lightning") else {
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

    /// Prefixes the app or the decoder removes from the front of a request, after deleting every `bitkit://`.
    private static let decoderWrappers = ["lightning:", "lnurl:", "lnurlw:", "lnurlc:", "lnurlp:"]
    private static let bech32Charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let bech32Generator: [UInt32] = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]

    /// Whether a `bitcoin:` request carries a required (`req-`) parameter. The app does not support any, and
    /// bitkit-core rc15 ignores them on a URI with an address, so a request from a nearby source that has one is
    /// refused rather than paid without the parameter. The app and the decoder strip wrappers (`bitkit://` and the
    /// Lightning schemes) before decoding, repeatedly in the decoder's case, so every wrapper is removed here and the
    /// request is checked as the `bitcoin:` URI the decoder receives.
    nonisolated static func hasRequiredParameter(_ uri: String) -> Bool {
        // The decoder deletes every `bitkit://` in a deep link, which can turn a key into `req-`.
        var lowercase = uri.lowercased().replacingOccurrences(of: "bitkit://", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        while let wrapper = decoderWrappers.first(where: { lowercase.hasPrefix($0) }) {
            lowercase = String(lowercase.dropFirst(wrapper.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lowercase.hasPrefix("bitcoin:"), let query = lowercase.split(separator: "?", maxSplits: 1).dropFirst().first else {
            return false
        }
        return query.split(separator: "&").contains { $0.hasPrefix(requiredParamPrefix) }
    }

    /// Whether `value` is a BOLT11 invoice for a network the decoder reads as one (`lnbc`, `lnbcrt`, `lntb`,
    /// `lntbs`): its human-readable part is the network and an optional amount, and its bech32 checksum holds. Checked
    /// without the decoder, which would resolve a Lightning address such as `lnbc@example.com` over the network.
    nonisolated static func isBolt11Invoice(_ value: some StringProtocol) -> Bool {
        let lowercase = value.lowercased()
        guard let separator = lowercase.lastIndex(of: "1") else { return false }
        let hrp = lowercase[..<separator]
        let network = ["lnbcrt", "lntbs", "lnbc", "lntb"].first { hrp.hasPrefix($0) }
        guard let network else { return false }
        var amount = hrp.dropFirst(network.count)
        if let last = amount.last, "munp".contains(last) {
            amount = amount.dropLast()
        }
        guard amount.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        let data = lowercase[lowercase.index(after: separator)...].compactMap { bech32Charset.firstIndex(of: $0) }
        guard data.count >= 6, data.count == lowercase.distance(from: separator, to: lowercase.endIndex) - 1 else {
            return false
        }
        let hrpBytes = hrp.unicodeScalars.map { UInt32($0.value) }
        let values = hrpBytes.map { $0 >> 5 } + [0] + hrpBytes.map { $0 & 31 } + data.map { UInt32($0) }
        var checksum: UInt32 = 1
        for value in values {
            let top = checksum >> 25
            checksum = (checksum & 0x1FFFFFF) << 5 ^ value
            for (bit, generator) in bech32Generator.enumerated() where (top >> bit) & 1 == 1 {
                checksum ^= generator
            }
        }
        return checksum == 1
    }
}
