import Foundation

/// Utility methods for BIP21 URI handling
enum Bip21Utils {
    private static let bip21Prefix = "bitcoin:"

    /// Checks if a BIP21 URI is duplicated (contains multiple bitcoin: prefixes).
    /// Workaround for https://github.com/synonymdev/bitkit-core/issues/63
    /// - Parameter input: The string to check
    /// - Returns: true if the input contains duplicated BIP21 URIs, false otherwise
    static func isDuplicatedBip21(_ input: String) -> Bool {
        let lowercased = input.lowercased()
        guard let firstIndex = lowercased.range(of: bip21Prefix)?.upperBound else {
            return false
        }
        return lowercased[firstIndex...].contains(bip21Prefix)
    }
}
