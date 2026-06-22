import BitkitCore

/// Bitcoin account address types tracked for hardware (watch-only) wallets.
/// Mirrors the four BIP account levels Bitkit derives account xpubs for.
/// `allCases` order matches bitkit-android's `ALL_ADDRESS_TYPES`.
enum HwAddressType: CaseIterable {
    case legacy
    case nestedSegwit
    case nativeSegwit
    case taproot

    /// Storage key used in `TrezorKnownDevice.xpubs` and address-type settings.
    var settingsString: String {
        switch self {
        case .legacy: "legacy"
        case .nestedSegwit: "nestedSegwit"
        case .nativeSegwit: "nativeSegwit"
        case .taproot: "taproot"
        }
    }

    /// bitkit-core account type used when starting a watcher for this address type.
    var accountType: AccountType {
        switch self {
        case .legacy: .legacy
        case .nestedSegwit: .wrappedSegwit
        case .nativeSegwit: .nativeSegwit
        case .taproot: .taproot
        }
    }

    private var purpose: Int {
        switch self {
        case .legacy: 44
        case .nestedSegwit: 49
        case .nativeSegwit: 84
        case .taproot: 86
        }
    }

    /// Account-level derivation path, e.g. `m/84'/0'/0'` (coin type `1'` for non-mainnet).
    func accountDerivationPath(network: TrezorCoinType) -> String {
        let coinType = network == .bitcoin ? 0 : 1
        return "m/\(purpose)'/\(coinType)'/0'"
    }

    init?(settingsString: String) {
        switch settingsString {
        case "legacy": self = .legacy
        case "nestedSegwit": self = .nestedSegwit
        case "nativeSegwit": self = .nativeSegwit
        case "taproot": self = .taproot
        default: return nil
        }
    }
}
