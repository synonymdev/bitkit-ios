import Foundation

/// The maker of a paired hardware wallet. Stored on every paired entry, so each device call is routed
/// to the manager that speaks that vendor's protocol.
enum HwWalletVendor: String, Codable, CaseIterable, Sendable {
    case trezor
    case blockstream

    /// Namespace passed to bitkit-core's `deriveWalletId`. Every wallet id carries it, so it must never
    /// change: equal seeds on two vendors then derive two wallets.
    var deviceType: String {
        switch self {
        case .trezor: "trezor"
        case .blockstream: "jade"
        }
    }
}
