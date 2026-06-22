import CryptoKit
import Foundation

/// Derives a stable, app-level wallet id for a paired hardware wallet, used to scope its
/// activities in bitkit-core's wallet-scoped storage (core 0.3.x).
///
/// ⚠️ INTERIM / PROVISIONAL. bitkit-core does not derive this — it only ships the default
/// `"bitkit"` id (`getDefaultWalletId()`), and the Android app has not yet adopted
/// wallet-scoped hardware storage. The exact format MUST be agreed cross-platform before
/// release so iOS and Android produce identical ids for the same device. This is the single
/// source of the derivation: swap it here when the shared scheme is finalized.
enum HwWalletId {
    private static let prefix = "trezor:"

    /// Deterministic id derived from the device's account xpubs (transport-independent: the
    /// same physical device paired over different transports shares its xpubs, hence its id).
    /// Falls back to the device id when no xpubs were captured.
    static func derive(xpubs: [String: String], fallbackId: String) -> String {
        let sorted = xpubs.values.sorted()
        guard !sorted.isEmpty else { return prefix + fallbackId }
        let digest = SHA256.hash(data: Data(sorted.joined(separator: "\n").utf8))
        return prefix + Data(digest).hex
    }
}
