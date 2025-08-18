import BitkitCore
import SwiftUI

struct TransferLearnMoreView: View {
    let order: IBtOrder

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisplayText(localizedString("lightning__liquidity__title"), accentColor: .purpleAccent)
                .padding(.bottom, 16)

            BodyMText(localizedString("lightning__liquidity__text"))

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                SubtitleText(localizedString("lightning__liquidity__label"))
                LightningChannel(
                    capacity: order.lspBalanceSat + order.clientBalanceSat,
                    localBalance: order.clientBalanceSat,
                    remoteBalance: order.lspBalanceSat,
                    status: .open,
                    showLabels: true
                )
            }

            CustomButton(title: localizedString("common__understood")) {
                dismiss()
            }
            .padding(.top, 32)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__transfer__nav_title"))
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        TransferLearnMoreView(order: IBtOrder.mock())
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
    }
    .preferredColorScheme(.dark)
}
