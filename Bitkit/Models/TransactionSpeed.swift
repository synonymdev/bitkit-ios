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
            return "\(satsPerVByte) \(t("common__sat_vbyte_compact"))"
        default:
            return nil
        }
    }

    public var displayTitle: String {
        switch self {
        case .fast:
            return t("fee__fast__title")
        case .medium:
            return t("fee__normal__title")
        case .slow:
            return t("fee__slow__title")
        case .custom:
            return t("fee__custom__title")
        }
    }

    public var displayLabel: String {
        switch self {
        case .fast:
            return t("settings__fee__fast__label")
        case .medium:
            return t("settings__fee__normal__label")
        case .slow:
            return t("settings__fee__slow__label")
        case .custom:
            return t("settings__fee__custom__label")
        }
    }

    public var displayValue: String {
        switch self {
        case .fast:
            return t("settings__fee__fast__value")
        case .medium:
            return t("settings__fee__normal__value")
        case .slow:
            return t("settings__fee__slow__value")
        case .custom:
            return t("settings__fee__custom__value")
        }
    }

    public var displayDescription: String {
        switch self {
        case .fast:
            return t("settings__fee__fast__description")
        case .medium:
            return t("settings__fee__normal__description")
        case .slow:
            return t("settings__fee__slow__description")
        case .custom:
            return t("settings__fee__custom__description")
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
