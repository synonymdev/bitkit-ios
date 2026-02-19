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
    /// Component used to build fee localization keys (e.g. "fee__fast__title", "fee__fast__longTitle").
    var feeKeyComponent: String {
        switch self {
        case .fast: return "fast"
        case .normal: return "normal"
        case .slow: return "slow"
        case .custom: return "custom"
        }
    }

    var title: String { t("fee__\(feeKeyComponent)__title") }
    var longTitle: String { t("fee__\(feeKeyComponent)__longTitle") }
    var description: String { t("fee__\(feeKeyComponent)__description") }
    var shortDescription: String { t("fee__\(feeKeyComponent)__shortDescription") }
    var range: String { t("fee__\(feeKeyComponent)__range") }
    var longRange: String { t("fee__\(feeKeyComponent)__longRange") }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var customSetSpeed: String? {
        guard case let .custom(satsPerVByte) = self else { return nil }
        return "\(satsPerVByte) \(t("common__sat_vbyte_compact"))"
    }

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
    /// Key suffix for fee tier localization (matches "fee__{tier}__{variant}" in Localizable.strings).
    enum FeeTierVariant: String {
        case title
        case longTitle
        case description
        case shortDescription
        case range
        case longRange
    }

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

    /// Tier derived from a fee rate and current estimates (fast/normal/slow/minimum). Use with fee localization keys or getFeeTierLocalized.
    static func feeTierKeyComponent(for feeRate: UInt64, feeEstimates: FeeRates?) -> String {
        guard let estimates = feeEstimates else { return "normal" }
        if feeRate >= UInt64(estimates.fast) { return "fast" }
        if feeRate >= UInt64(estimates.mid) { return "normal" }
        if feeRate >= UInt64(estimates.slow) { return "slow" }
        return "minimum"
    }

    /// Returns the localized string for a fee rate's tier and the given variant (e.g. title, description, shortDescription).
    static func getFeeTierLocalized(feeRate: UInt64, feeEstimates: FeeRates?, variant: FeeTierVariant) -> String {
        let tier = feeTierKeyComponent(for: feeRate, feeEstimates: feeEstimates)
        return t("fee__\(tier)__\(variant.rawValue)")
    }
}
