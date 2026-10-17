import Foundation

enum PubkyPublicKeyFormat {
    private static let prefix = "pubky"
    private static let rawKeyLength = 52
    private static let allowedCharacters = Set("ybndrfg8ejkmcpqxot1uwisza345h769")

    static let maximumInputLength = prefix.count + rawKeyLength

    static func bounded(_ input: String) -> String {
        String(input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(maximumInputLength))
    }

    static func normalized(_ input: String) -> String? {
        let boundedInput = bounded(input)
        let rawKey = boundedInput.hasPrefix(prefix) ? String(boundedInput.dropFirst(prefix.count)) : boundedInput

        guard rawKey.count == rawKeyLength else {
            return nil
        }

        guard rawKey.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }

        return "\(prefix)\(rawKey)"
    }

    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs.flatMap(normalized),
              let rhs = rhs.flatMap(normalized)
        else {
            return false
        }

        return lhs == rhs
    }

    static func redacted(_ input: String) -> String {
        let value = normalized(input) ?? input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 12 else {
            return value
        }

        return "\(value.prefix(12))..."
    }

    /// Shortens a pubky for display as `dead...oxyo`: the first and last 4 characters of the key with any
    /// `pubky` or `pk:` prefix removed, so the prefix never appears in the truncated form.
    static func displayTruncated(_ input: String) -> String {
        let rawKey = strippingDisplayPrefix(input)
        guard rawKey.count > displayEdgeLength * 2 else { return rawKey }

        return "\(rawKey.prefix(displayEdgeLength))...\(rawKey.suffix(displayEdgeLength))"
    }

    private static let displayEdgeLength = 4
    private static let displayPrefixes = [prefix, "pk:"]

    private static func strippingDisplayPrefix(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard let matchedPrefix = displayPrefixes.first(where: { lowercased.hasPrefix($0) }) else {
            return trimmed
        }

        return String(trimmed.dropFirst(matchedPrefix.count))
    }
}
