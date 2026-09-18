import Foundation

/// How each vendor's devices are shown and named across the hardware wallet screens.
extension HwWalletVendor {
    /// The upright device illustration; the Jade one is a placeholder until design supplies the asset.
    var deviceImageName: String {
        switch self {
        case .trezor: "trezor-device"
        case .blockstream: "jade-placeholder"
        }
    }

    /// The illustration shown while the device signs a transaction.
    var signImageName: String {
        switch self {
        case .trezor: "trezor-card"
        case .blockstream: "jade-placeholder"
        }
    }

    var modelName: String {
        switch self {
        case .trezor: t("hardware__device_model_trezor")
        case .blockstream: t("hardware__device_model_jade")
        }
    }

    var foundHeader: String {
        switch self {
        case .trezor: t("hardware__found_header")
        case .blockstream: t("hardware__found_header_jade")
        }
    }

    var pairedHeader: String {
        switch self {
        case .trezor: t("hardware__paired_header")
        case .blockstream: t("hardware__paired_header_jade")
        }
    }

    var sendSignButtonTitle: String {
        switch self {
        case .trezor: t("hardware__send_open_connect")
        case .blockstream: t("hardware__send_open_connect_jade")
        }
    }

    var transferSignButtonTitle: String {
        switch self {
        case .trezor: t("lightning__transfer_hw__open_connect")
        case .blockstream: t("hardware__send_open_connect_jade")
        }
    }

    /// Passphrase (hidden) wallets are a Trezor feature; a Jade holds one wallet per device.
    var supportsPassphraseWallets: Bool {
        switch self {
        case .trezor: true
        case .blockstream: false
        }
    }
}
