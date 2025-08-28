import BitkitCore
import Foundation
import SwiftUI

// MARK: - Core Transaction Speed Enum

public enum TransactionSpeed: Equatable, Hashable, RawRepresentable {
    case fast
    case normal
    case slow
    case custom(satsPerVByte: UInt32)

    // MARK: - RawRepresentable Implementation

    public init(rawValue: String) {
        if rawValue == "fast" {
            self = .fast
        } else if rawValue == "normal" {
            self = .normal
        } else if rawValue == "slow" {
            self = .slow
        } else if rawValue.starts(with: "custom_"),
                  let rateStr = rawValue.split(separator: "_").last,
                  let rate = UInt32(rateStr)
        {
            self = .custom(satsPerVByte: rate)
        } else {
            self = .normal
        }
    }

    public var rawValue: String {
        switch self {
        case .fast: return "fast"
        case .normal: return "normal"
        case .slow: return "slow"
        case let .custom(satsPerVByte): return "custom_\(satsPerVByte)"
        }
    }
}

// MARK: - Display Properties

public extension TransactionSpeed {
    var displayTitle: String {
        switch self {
        case .fast: return t("fee__fast__title")
        case .normal: return t("fee__normal__title")
        case .slow: return t("fee__slow__title")
        case .custom: return t("fee__custom__title")
        }
    }

    var displayDescription: String {
        switch self {
        case .fast: return t("fee__fast__description")
        case .normal: return t("fee__normal__description")
        case .slow: return t("fee__slow__description")
        case .custom: return t("fee__custom__description")
        }
    }

    var customSetSpeed: String? {
        guard case let .custom(satsPerVByte) = self else { return nil }
        return "\(satsPerVByte) \(t("common__sat_vbyte_compact"))"
    }
}

// MARK: - Settings Display Properties

public extension TransactionSpeed {
    var displayLabel: String {
        switch self {
        case .fast: return t("settings__fee__fast__label")
        case .normal: return t("settings__fee__normal__label")
        case .slow: return t("settings__fee__slow__label")
        case .custom: return t("settings__fee__custom__label")
        }
    }

    var displayValue: String {
        switch self {
        case .fast: return t("settings__fee__fast__value")
        case .normal: return t("settings__fee__normal__value")
        case .slow: return t("settings__fee__slow__value")
        case .custom: return t("settings__fee__custom__value")
        }
    }
}

// MARK: - UI Properties

public extension TransactionSpeed {
    var iconName: String {
        switch self {
        case .fast: return "speed-fast"
        case .normal: return "speed-normal"
        case .slow: return "speed-slow"
        case .custom: return "gear"
        }
    }

    var iconColor: Color {
        switch self {
        case .fast: return .brandAccent
        case .normal: return .brandAccent
        case .slow: return .brandAccent
        case .custom: return .textSecondary
        }
    }
}

// MARK: - Business Logic

public extension TransactionSpeed {
    /// Returns the fee rate in satoshis per virtual byte for this speed
    /// - Parameter feeRates: Current network fee rates
    /// - Returns: Fee rate in sat/vB
    func getFeeRate(from feeRates: FeeRates) -> UInt32 {
        switch self {
        case .fast: return feeRates.fast
        case .normal: return feeRates.mid
        case .slow: return feeRates.slow
        case let .custom(rate): return rate
        }
    }

    /// Validates if this speed is within acceptable limits
    /// - Parameters:
    ///   - minRate: Minimum acceptable fee rate
    ///   - maxRate: Maximum acceptable fee rate
    /// - Returns: True if the speed is within limits
    func isValid(minRate: UInt32, maxRate: UInt32) -> Bool {
        guard case let .custom(rate) = self else { return true }
        return rate >= minRate && rate <= maxRate
    }
}

// MARK: - Equatable Implementation

public extension TransactionSpeed {
    static func == (lhs: TransactionSpeed, rhs: TransactionSpeed) -> Bool {
        switch (lhs, rhs) {
        case (.fast, .fast), (.normal, .normal), (.slow, .slow):
            return true
        case let (.custom(lhsRate), .custom(rhsRate)):
            return lhsRate == rhsRate
        default:
            return false
        }
    }
}
