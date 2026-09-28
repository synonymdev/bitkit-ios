import BitkitCore
import SwiftUI

struct TransferLearnMoreView: View {
    @EnvironmentObject var transfer: TransferViewModel

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__liquidity__title"), accentColor: .purpleAccent)
                .padding(.bottom, 16)

            BodyMText(t("lightning__liquidity__text"))

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                SubtitleText(t("lightning__liquidity__label"))
                LightningChannel(
                    capacity: transfer.uiState.lspBalanceSat + transfer.uiState.clientBalanceSat,
                    localBalance: transfer.uiState.clientBalanceSat,
                    remoteBalance: transfer.uiState.lspBalanceSat,
                    status: .open,
                    showLabels: true
                )
            }

            CustomButton(title: t("common__understood")) {
                dismiss()
            }
            .padding(.top, 32)
            .accessibilityIdentifier("LiquidityContinue")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        TransferLearnMoreView()
            .environmentObject(TransferViewModel())
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
    }
    .preferredColorScheme(.dark)
}
