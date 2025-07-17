import SwiftUI

struct FundManualAmountView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    let lnPeer: LnPeer

    @State private var satsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString("lightning__external_amount__title", comment: ""), accentColor: .purpleAccent)
                    .padding(.top, 16)

                // Visible balance display that acts as a button
                AmountInput(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats) { newSats in
                    satsAmount = newSats
                    overrideSats = nil
                }
                .padding(.vertical, 16)

                Spacer()

                HStack(alignment: .bottom) {
                    AvailableAmount(label: localizedString("wallet__send_available"), amount: wallet.totalOnchainSats)

                    Spacer()

                    amountButtons
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)

            Spacer()

            CustomButton(
                title: NSLocalizedString("common__continue", comment: ""),
                isDisabled: satsAmount == 0,
                destination: FundManualConfirmView(lnPeer: lnPeer, satsAmount: satsAmount)
            )
            .disabled(satsAmount == 0)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color.black)
        .navigationTitle(NSLocalizedString("lightning__connections", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .backToWalletButton()
    }

    private var amountButtons: some View {
        HStack(spacing: 8) {
            NumberPadActionButton(
                text: currency.primaryDisplay == .bitcoin ? currency.selectedCurrency : "Bitcoin",
                imageName: "transfer-purple"
            ) {
                withAnimation {
                    currency.togglePrimaryDisplay()
                }
            }

            NumberPadActionButton(text: localizedString("lightning__spending_amount__quarter")) {
                overrideSats = UInt64(wallet.totalOnchainSats) / 4
            }

            NumberPadActionButton(text: NSLocalizedString("common__max", comment: "")) {
                overrideSats = UInt64(wallet.totalOnchainSats)
            }
        }
    }
}

#Preview {
    NavigationStack {
        FundManualAmountView(lnPeer: LnPeer(nodeId: "test", host: "test.com", port: 9735))
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
    }
    .preferredColorScheme(.dark)
}
