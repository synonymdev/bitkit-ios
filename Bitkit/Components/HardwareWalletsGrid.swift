import SwiftUI

/// Two-column grid of paired hardware wallets shown on Home, under the Savings/Spending tiles.
/// Mirrors bitkit-android's `HwDevices` (rows chunked in pairs, divided like the on-chain tiles).
struct HardwareWalletsGrid: View {
    let wallets: [HwWallet]
    let onTap: (HwWallet) -> Void

    private var rows: [[HwWallet]] {
        stride(from: 0, to: wallets.count, by: 2).map { Array(wallets[$0 ..< min($0 + 2, wallets.count)]) }
    }

    var body: some View {
        VStack(spacing: 16) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 16) {
                    HardwareWalletCell(wallet: row[0], onTap: onTap)

                    CustomDivider(color: .gray4, type: .vertical)

                    if row.count > 1 {
                        HardwareWalletCell(wallet: row[1], onTap: onTap)
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 50)
            }
        }
    }
}

private struct HardwareWalletCell: View {
    let wallet: HwWallet
    let onTap: (HwWallet) -> Void

    var body: some View {
        Button {
            onTap(wallet)
        } label: {
            VStack(alignment: .leading) {
                CaptionMText(wallet.name)
                    .lineLimit(1)
                    .padding(.bottom, 4)

                HStack(spacing: 4) {
                    Image("btc-circle-blue")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .padding(.trailing, 4)

                    MoneyText(
                        sats: Int(clamping: wallet.balanceSats),
                        size: .subtitle,
                        enableHide: true,
                        symbolColor: .textPrimary
                    )

                    HwWalletConnectionIcon(isConnected: wallet.isConnected)
                        .frame(width: 16, height: 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ActivityHardware")
    }
}

#Preview {
    func wallet(_ id: String, _ name: String, connected: Bool, sats: UInt64) -> HwWallet {
        HwWallet(id: id, walletId: "trezor:\(id)", name: name, model: name, isConnected: connected, balanceSats: sats)
    }

    return VStack(spacing: 32) {
        // Single device
        HardwareWalletsGrid(
            wallets: [wallet("1", "Trezor Safe 5", connected: true, sats: 1_234_567)],
            onTap: { _ in }
        )

        CustomDivider()

        // Two devices (full 2-column row), one connected, one not
        HardwareWalletsGrid(
            wallets: [
                wallet("1", "Trezor Safe 5", connected: true, sats: 1_234_567),
                wallet("2", "Trezor Model T", connected: false, sats: 89000),
            ],
            onTap: { _ in }
        )
    }
    .padding()
    .environmentObject(CurrencyViewModel())
    .environmentObject(SettingsViewModel.shared)
    .preferredColorScheme(.dark)
}
