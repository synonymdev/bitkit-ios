import Foundation

extension String {
    private static let lightningSchemePrefixes = [
        "lightning:",
        "lnurl:",
        "lnurlw:",
        "lnurlc:",
        "lnurlp:",
    ]

    /// Workaround until bitkit-core strips LNURL scheme prefixes (bitkit-core#70).
    func removingLightningSchemes() -> String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in Self.lightningSchemePrefixes {
            if let range = value.range(of: prefix, options: [.anchored, .caseInsensitive]) {
                value.removeSubrange(range)
            }
        }
        return value
    }

    enum EllipsisStyle {
        /// Ellipsis in the middle: "ab...de"
        case middle
        /// Ellipsis at the end: "abcde..."
        case end
    }

    /// Truncates a string to a maximum length and adds ellipsis.
    /// - Parameters:
    ///   - maxLength: The maximum length of the string
    ///   - style: `.middle` (default) keeps start and end with "..." in between; `.end` keeps prefix and "..." at the end
    /// - Returns: The truncated string with ellipsis
    func ellipsis(maxLength: Int, style: EllipsisStyle = .middle) -> String {
        if count <= maxLength {
            return self
        }

        switch style {
        case .middle:
            let half = maxLength / 2
            let start = prefix(half)
            let end = suffix(half)
            return "\(start)...\(end)"
        case .end:
            return String(prefix(maxLength)) + "..."
        }
    }
}
