import BitkitCore
import Foundation

/// User-facing messages for hardware wallet errors of every vendor: the Jade copy first, then the
/// Trezor rules.
enum HwErrorPresenter {
    static func userMessage(from error: Error) -> String {
        jadeMessage(from: error) ?? TrezorErrorPresenter.userMessage(from: error)
    }

    /// Nil only when the error carries no `JadeError`. Every Jade error gets Jade or neutral copy, so
    /// none reaches `TrezorErrorPresenter`, whose rules rewrite text into Trezor-branded messages.
    static func jadeMessage(from error: Error) -> String? {
        guard let jadeError = error.underlyingJadeError else { return nil }
        switch jadeError {
        case .InvalidPin:
            return t("hardware__jade_invalid_pin")
        case .DeviceUninitialized:
            return t("hardware__jade_uninitialized")
        case .UnsupportedFirmware:
            return t("hardware__jade_firmware_outdated")
        case .PsbtTooLarge:
            return t("hardware__jade_psbt_too_large")
        case .NetworkMismatch:
            return t("hardware__jade_network_mismatch")
        case .DeviceBusy, .DeviceLocked:
            return t("hardware__jade_device_busy")
        case .PinServerError:
            return t("hardware__jade_pinserver_error")
        case .AddressMismatch:
            return t("hardware__verify_address_error")
        case let .TransportError(details), let .ConnectionError(details):
            // The Bluetooth transport describes what went wrong in words meant for the user.
            if details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return t("hardware__connect_error")
            }
            return details
        default:
            return t("hardware__connect_error")
        }
    }

    static func deviceBusyMessage(for vendor: HwWalletVendor) -> String {
        switch vendor {
        case .trezor:
            return t("hardware__device_busy")
        case .blockstream:
            return t("hardware__jade_device_busy")
        }
    }
}
