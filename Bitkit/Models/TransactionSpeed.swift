import Foundation

public enum TransactionSpeed: Equatable, RawRepresentable {
    case fast
    case medium
    case slow
    case custom(satsPerVByte: UInt32)
    
    public init(rawValue: String) {
        if rawValue == "fast" {
            self = .fast
        } else if rawValue == "medium" {
            self = .medium
        } else if rawValue == "slow" {
            self = .slow
        } else if rawValue.starts(with: "custom_"),
                  let rateStr = rawValue.split(separator: "_").last,
                  let rate = UInt32(rateStr) {
            self = .custom(satsPerVByte: rate)
        } else {
            self = .medium
        }
    }
    
    public var rawValue: String {
        switch self {
        case .fast:
            return "fast"
        case .medium:
            return "medium"
        case .slow:
            return "slow"
        case .custom(let satsPerVByte):
            return "custom_\(satsPerVByte)"
        }
    }
    
    public static func == (lhs: TransactionSpeed, rhs: TransactionSpeed) -> Bool {
        switch (lhs, rhs) {
        case (.fast, .fast), (.medium, .medium), (.slow, .slow):
            return true
        case let (.custom(lhsRate), .custom(rhsRate)):
            return lhsRate == rhsRate
        default:
            return false
        }
    }
}
