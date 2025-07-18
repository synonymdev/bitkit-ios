import Foundation

extension String {
    /// Truncates a string to a maximum length and adds ellipsis in the middle
    /// - Parameter maxLength: The maximum length of the string
    /// - Returns: The truncated string with ellipsis in the middle
    func ellipsis(maxLength: Int) -> String {
        if count <= maxLength {
            return self
        }
        let start = prefix(maxLength / 2)
        let end = suffix(maxLength / 2)
        return "\(start)...\(end)"
    }
}
