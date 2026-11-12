import Foundation

/// Prepares a payment request read from an NFC tag or a nearby device for the scanner.
enum ScannedPaymentRequest {
    private static let bitcoinWithoutAddress = "bitcoin:?"
    private static let lightningParams = ["lightning", "lno"]

    /// A BIP 321 URI may leave the address out and carry only a Lightning request
    /// (`bitcoin:?lightning=<invoice>`, used by Numo and planned by Square). The scanner rejects a `bitcoin:` URI
    /// without an address, so that form becomes `lightning:<invoice>`. Anything else is returned trimmed and unchanged.
    static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(bitcoinWithoutAddress) else { return trimmed }
        var params: [String: String] = [:]
        for pair in trimmed.dropFirst(bitcoinWithoutAddress.count).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            let key = parts[0].lowercased()
            if params[key] == nil {
                params[key] = String(parts[1])
            }
        }
        guard let request = lightningParams.lazy.compactMap({ params[$0] }).first else { return trimmed }
        return "lightning:\(request)"
    }
}
