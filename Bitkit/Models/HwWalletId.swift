import BitkitCore
import Foundation

/// Derives a stable, cross-platform wallet id for a paired hardware wallet, used to scope
/// its activities in bitkit-core's wallet-scoped storage. Delegates to bitkit-core's
/// `deriveWalletId` (the canonical cross-platform derivation, finalized in core 0.3.4) so
/// iOS and Android produce identical ids for the same device.
enum HwWalletId {
    /// Deterministic id derived from the device's account xpubs (transport-independent: the
    /// same physical device shares its xpubs, hence its id). Throws if `xpubs` is empty.
    static func derive(xpubs: [String: String], deviceType: String = "trezor") throws -> String {
        try deriveWalletId(deviceType: deviceType, xpubs: Array(xpubs.values))
    }
}
