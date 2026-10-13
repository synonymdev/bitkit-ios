import SwiftUI

struct HardwareWalletsGrid<AdditionalWallet: View>: View {
    let wallets: [HwWallet]
    let showAdditionalWallet: Bool
    let onTap: (HwWallet) -> Void
    let additionalWallet: AdditionalWallet

    init(wallets: [HwWallet], showAdditionalWallet: Bool = false, onTap: @escaping (HwWallet) -> Void,
         @ViewBuilder additionalWallet: () -> AdditionalWallet = { EmptyView() })
    {
        self.wallets = wallets
        self.showAdditionalWallet = showAdditionalWallet
        self.onTap = onTap
        self.additionalWallet = additionalWallet()
    }

    var body: some View {
        VStack(spacing: 16) {
            ForEach(Array(stride(from: 0, to: wallets.count + (showAdditionalWallet ? 1 : 0), by: 2)), id: \.self) { rowStart in
                HStack(spacing: 16) {
                    cell(at: rowStart)
                    CustomDivider(color: .gray4, type: .vertical)
                    cell(at: rowStart + 1)
                }
                .frame(height: 50)
            }
        }
    }

    @ViewBuilder
    private func cell(at index: Int) -> some View {
        if index < wallets.count {
            HardwareWalletCell(wallet: wallets[index], onTap: onTap)
        } else if showAdditionalWallet, index == wallets.count {
            additionalWallet
        } else {
            Color.clear.frame(maxWidth: .infinity)
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
                HStack(spacing: 4) {
                    CaptionMText(wallet.name)
                        .lineLimit(1)

                    HwWalletConnectionIcon(isConnected: wallet.isConnected)
                        .frame(width: 16, height: 16)
                }
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
