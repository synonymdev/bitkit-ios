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
        let rawKey: String
        if boundedInput.count == rawKeyLength {
            rawKey = boundedInput
        } else if boundedInput.count == maximumInputLength,
                  boundedInput.hasPrefix(prefix)
        {
            rawKey = String(boundedInput.dropFirst(prefix.count))
        } else {
            return nil
        }

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

    static func displayTruncated(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare key is never a prefixed one, so its leading characters stay even when they
        // spell "pubky". Anything else keeps the historic behaviour of stripping the prefix.
        let isBareKey = trimmed.count == rawKeyLength
        let rawKey = !isBareKey && trimmed.lowercased().hasPrefix(prefix)
            ? String(trimmed.dropFirst(prefix.count))
            : trimmed
        guard rawKey.count > 10 else { return rawKey }

        return "\(rawKey.prefix(4))...\(rawKey.suffix(4))"
    }
}
