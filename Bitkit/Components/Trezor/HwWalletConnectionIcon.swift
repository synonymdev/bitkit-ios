import SwiftUI

/// Bluetooth connection indicator for a paired hardware wallet. iOS supports Bluetooth only,
/// so there is a single transport glyph — tinted green when connected, gray when disconnected.
/// Mirrors bitkit-android's `HwWalletConnectionIcon` (BLE branch).
struct HwWalletConnectionIcon: View {
    let isConnected: Bool

    var body: some View {
        Image("bluetooth-connected")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundColor(isConnected ? .greenAccent : .gray1)
            .accessibilityLabel(
                isConnected
                    ? t("hardware__connection_badge_connected_bluetooth")
                    : t("hardware__connection_badge_disconnected_bluetooth")
            )
    }
}

#Preview {
    HStack(spacing: 24) {
        HwWalletConnectionIcon(isConnected: true).frame(width: 16, height: 16)
        HwWalletConnectionIcon(isConnected: false).frame(width: 16, height: 16)
    }
    .padding()
    .preferredColorScheme(.dark)
}
