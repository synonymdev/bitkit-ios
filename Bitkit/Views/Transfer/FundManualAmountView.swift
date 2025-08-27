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
                DisplayText(t("lightning__external_amount__title"), accentColor: .purpleAccent)
                    .padding(.top, 16)

                // Visible balance display that acts as a button
                AmountInput(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats) { newSats in
                    satsAmount = newSats
                    overrideSats = nil
                }
                .padding(.vertical, 16)

                Spacer()

                HStack(alignment: .bottom) {
                    AvailableAmount(label: t("wallet__send_available"), amount: wallet.totalOnchainSats)
                        .onTapGesture {
                            overrideSats = UInt64(wallet.totalOnchainSats)
                        }

                    Spacer()

                    amountButtons
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)

            Spacer()

            CustomButton(
                title: t("common__continue"),
                isDisabled: satsAmount == 0,
                destination: FundManualConfirmView(lnPeer: lnPeer, satsAmount: satsAmount)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color.black)
        .navigationTitle(t("lightning__connections"))
        .navigationBarTitleDisplayMode(.inline)
        .backToWalletButton()
    }

    private var amountButtons: some View {
        HStack(spacing: 8) {
            NumberPadActionButton(
                text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                imageName: "arrow-up-down"
            ) {
                withAnimation {
                    currency.togglePrimaryDisplay()
                }
            }

            NumberPadActionButton(text: t("lightning__spending_amount__quarter")) {
                overrideSats = UInt64(wallet.totalOnchainSats) / 4
            }

            NumberPadActionButton(text: t("common__max")) {
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
