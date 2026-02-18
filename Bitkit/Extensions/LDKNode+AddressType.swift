import LDKNode

extension LDKNode.AddressType {
    // MARK: - All cases (ordered)

    static var allAddressTypes: [LDKNode.AddressType] { [.legacy, .nestedSegwit, .nativeSegwit, .taproot] }

    /// All address types with `selected` first, remaining in standard order.
    static func prioritized(selected: LDKNode.AddressType) -> [LDKNode.AddressType] {
        var types = [selected]
        for type in allAddressTypes where type != selected {
            types.append(type)
        }
        return types
    }

    // MARK: - Storage string (UserDefaults / BitkitCore APIs)

    /// String value used in UserDefaults and BitkitCore APIs.
    var stringValue: String {
        switch self {
        case .legacy: return "legacy"
        case .nestedSegwit: return "nestedSegwit"
        case .nativeSegwit: return "nativeSegwit"
        case .taproot: return "taproot"
        }
    }

    /// Parses storage string; returns nil for invalid or unknown values.
    static func from(string: String) -> LDKNode.AddressType? {
        switch string {
        case "legacy": return .legacy
        case "nestedSegwit": return .nestedSegwit
        case "nativeSegwit": return .nativeSegwit
        case "taproot": return .taproot
        default: return nil
        }
    }

    /// Parses storage string; returns `.nativeSegwit` for nil or invalid (backward compatibility).
    static func fromStorage(_ string: String?) -> LDKNode.AddressType {
        guard let s = string, let type = from(string: s) else { return .nativeSegwit }
        return type
    }

    // MARK: - Derivation path

    /// BIP derivation path using current network (Env.network) for coin type.
    var derivationPath: String {
        let coinType = Env.network == .bitcoin ? "0" : "1"
        return derivationPath(coinType: coinType)
    }

    /// BIP derivation path for the given coin type ("0" mainnet, "1" testnet).
    func derivationPath(coinType: String) -> String {
        switch self {
        case .legacy: return "m/44'/\(coinType)'/0'/0" // BIP 44
        case .nestedSegwit: return "m/49'/\(coinType)'/0'/0" // BIP 49
        case .nativeSegwit: return "m/84'/\(coinType)'/0'/0" // BIP 84
        case .taproot: return "m/86'/\(coinType)'/0'/0" // BIP 86
        }
    }

    // MARK: - Localized display

    var localizedTitle: String {
        switch self {
        case .legacy: return "Legacy"
        case .nestedSegwit: return "Nested Segwit"
        case .nativeSegwit: return "Native Segwit"
        case .taproot: return "Taproot"
        }
    }

    /// Short label for compact UI (e.g. "Native").
    var shortLabel: String {
        switch self {
        case .legacy: return "Legacy"
        case .nestedSegwit: return "Nested"
        case .nativeSegwit: return "Native"
        case .taproot: return "Taproot"
        }
    }

    var localizedDescription: String {
        switch self {
        case .legacy: return "Pay-to-public-key-hash (1x...)"
        case .nestedSegwit: return "Pay-to-Script-Hash (3x...)"
        case .nativeSegwit: return "Pay-to-witness-public-key-hash (bc1x...)"
        case .taproot: return "Pay-to-Taproot (bc1px...)"
        }
    }

    var example: String {
        switch self {
        case .legacy: return "(1x...)"
        case .nestedSegwit: return "(3x...)"
        case .nativeSegwit: return "(bc1x...)"
        case .taproot: return "(bc1px...)"
        }
    }

    var shortExample: String {
        switch self {
        case .legacy: return "1x..."
        case .nestedSegwit: return "3x..."
        case .nativeSegwit: return "bc1q..."
        case .taproot: return "bc1p..."
        }
    }

    /// Accessibility / UI test identifier.
    var testId: String {
        switch self {
        case .legacy: return "p2pkh"
        case .nestedSegwit: return "p2sh-p2wpkh"
        case .nativeSegwit: return "p2wpkh"
        case .taproot: return "p2tr"
        }
    }

    // MARK: - Address format validation

    /// Returns true if the address has the expected prefix for this address type on the given network.
    /// Defensive check only; not a full script/checksum validation.
    func matchesAddressFormat(_ address: String, network: LDKNode.Network) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let isMainnet = network == .bitcoin
        switch self {
        case .legacy:
            return isMainnet ? trimmed.hasPrefix("1") : trimmed.hasPrefix("m") || trimmed.hasPrefix("n")
        case .nestedSegwit:
            return isMainnet ? trimmed.hasPrefix("3") : trimmed.hasPrefix("2")
        case .nativeSegwit:
            return isMainnet ? trimmed.hasPrefix("bc1q") : trimmed.hasPrefix("tb1q") || trimmed.hasPrefix("bcrt1q")
        case .taproot:
            return isMainnet ? trimmed.hasPrefix("bc1p") : trimmed.hasPrefix("tb1p") || trimmed.hasPrefix("bcrt1p")
        }
    }
}
