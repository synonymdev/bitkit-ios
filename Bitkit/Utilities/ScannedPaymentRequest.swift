import Foundation

/// Prepares a payment request read from an NFC tag or a nearby device for the scanner.
enum ScannedPaymentRequest {
    private static let bitcoinWithoutAddress = "bitcoin:?"
    private static let lightningParams = ["lightning", "lno"]
    private static let requiredParamPrefix = "req-"

    /// A BIP 321 URI may leave the address out and carry only a Lightning request
    /// (`bitcoin:?lightning=<invoice>`, used by Numo and planned by Square). The scanner rejects a `bitcoin:` URI
    /// without an address, so that form becomes `lightning:<invoice>`. A URI with a required (`req-`) parameter is
    /// kept, since BIP 321 forbids paying it without handling that parameter and the rewrite would drop it. So is a URI
    /// that repeats a parameter, which BIP 321 makes invalid, so the scanner rejects it instead of paying the invoice
    /// alone. Anything else is returned trimmed and unchanged.
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
            guard keys.insert(key).inserted else { return trimmed }
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            params[key] = String(parts[1])
        }
        guard let request = lightningParams.lazy.compactMap({ params[$0] }).first else { return trimmed }
        return "lightning:\(request)"
    }
}
