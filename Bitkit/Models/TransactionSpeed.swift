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
                  let rate = UInt32(rateStr)
        {
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
        case let .custom(satsPerVByte):
            return "custom_\(satsPerVByte)"
        }
    }

    public var customSetSpeed: String? {
        switch self {
        case let .custom(satsPerVByte):
            return "\(satsPerVByte) \(NSLocalizedString("common__sat_vbyte_compact", comment: ""))"
        default:
            return nil
        }
    }

    public var displayTitle: String {
        switch self {
        case .fast:
            return NSLocalizedString("fee__fast__title", comment: "")
        case .medium:
            return NSLocalizedString("fee__normal__title", comment: "")
        case .slow:
            return NSLocalizedString("fee__slow__title", comment: "")
        case .custom:
            return NSLocalizedString("fee__custom__title", comment: "")
        }
    }

    public var displayLabel: String {
        switch self {
        case .fast:
            return NSLocalizedString("settings__fee__fast__label", comment: "")
        case .medium:
            return NSLocalizedString("settings__fee__normal__label", comment: "")
        case .slow:
            return NSLocalizedString("settings__fee__slow__label", comment: "")
        case .custom:
            return NSLocalizedString("settings__fee__custom__label", comment: "")
        }
    }

    public var displayValue: String {
        switch self {
        case .fast:
            return NSLocalizedString("settings__fee__fast__value", comment: "")
        case .medium:
            return NSLocalizedString("settings__fee__normal__value", comment: "")
        case .slow:
            return NSLocalizedString("settings__fee__slow__value", comment: "")
        case .custom:
            return NSLocalizedString("settings__fee__custom__value", comment: "")
        }
    }

    public var displayDescription: String {
        switch self {
        case .fast:
            return NSLocalizedString("settings__fee__fast__description", comment: "")
        case .medium:
            return NSLocalizedString("settings__fee__normal__description", comment: "")
        case .slow:
            return NSLocalizedString("settings__fee__slow__description", comment: "")
        case .custom:
            return NSLocalizedString("settings__fee__custom__description", comment: "")
        }
    }

    public var iconName: String {
        switch self {
        case .fast:
            return "speed-fast"
        case .medium:
            return "speed-normal"
        case .slow:
            return "speed-slow"
        case .custom:
            return "gear-six"
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
