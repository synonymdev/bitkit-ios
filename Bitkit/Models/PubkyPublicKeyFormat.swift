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
}
