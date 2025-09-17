import SwiftUI

struct FundManualAmountView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    let lnPeer: LnPeer

    @StateObject private var amountViewModel = AmountInputViewModel()

    var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__connections"))
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("lightning__external_amount__title"), accentColor: .purpleAccent)

                NumberPadTextField(viewModel: amountViewModel, showConversion: false)
                    .onTapGesture {
                        amountViewModel.togglePrimaryDisplay(currency: currency)
                    }
                    .padding(.vertical, 32)

                Spacer()

                HStack(alignment: .bottom) {
                    AvailableAmount(label: t("wallet__send_available"), amount: wallet.totalOnchainSats)
                        .onTapGesture {
                            amountViewModel.updateFromSats(UInt64(wallet.totalOnchainSats), currency: currency)
                        }

                    Spacer()

                    numberPadButtons
                }
                .padding(.bottom, 12)

                Divider()

                NumberPad(
                    type: amountViewModel.getNumberPadType(currency: currency),
                    errorKey: amountViewModel.errorKey
                ) { key in
                    amountViewModel.handleNumberPadInput(key, currency: currency)
                }

                CustomButton(
                    title: t("common__continue"),
                    isDisabled: amountSats == 0,
                    destination: FundManualConfirmView(lnPeer: lnPeer, amountSats: amountSats)
                )
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }

    private var numberPadButtons: some View {
        HStack(spacing: 8) {
            NumberPadActionButton(
                text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                imageName: "arrow-up-down"
            ) {
                withAnimation {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
            }

            NumberPadActionButton(text: t("lightning__spending_amount__quarter")) {
                amountViewModel.updateFromSats(UInt64(wallet.totalOnchainSats) / 4, currency: currency)
            }

            NumberPadActionButton(text: t("common__max")) {
                amountViewModel.updateFromSats(UInt64(wallet.totalOnchainSats), currency: currency)
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
