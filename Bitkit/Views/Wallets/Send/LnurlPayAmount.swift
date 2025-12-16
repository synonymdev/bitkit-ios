import SwiftUI

struct LnurlPayAmount: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]

    @StateObject private var amountViewModel = AmountInputViewModel()

    var maxAmount: UInt64 {
        // TODO: subtract fee
        min(app.lnurlPayData!.maxSendable, UInt64(wallet.totalLightningSats))
    }

    var amount: UInt64 {
        amountViewModel.amountSats
    }

    var isValid: Bool {
        amount >= 0 && amount <= maxAmount
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__lnurl_p_title"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                NumberPadTextField(viewModel: amountViewModel, testIdentifier: "SendNumberField")
                    .onTapGesture {
                        amountViewModel.togglePrimaryDisplay(currency: currency)
                    }
                    .padding(.vertical, 16)

                Spacer()

                HStack(alignment: .bottom) {
                    AvailableAmount(label: t("wallet__send_available_spending"), amount: wallet.totalLightningSats)
                        .onTapGesture {
                            amountViewModel.updateFromSats(UInt64(wallet.totalLightningSats), currency: currency)
                        }

                    Spacer()

                    NumberPadActionButton(text: t("common__max"), color: .brandAccent) {
                        amountViewModel.updateFromSats(maxAmount, currency: currency)
                    }

                    NumberPadActionButton(
                        text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                        imageName: "arrow-up-down",
                        color: .brandAccent
                    ) {
                        withAnimation {
                            amountViewModel.togglePrimaryDisplay(currency: currency)
                        }
                    }
                }
                .padding(.bottom, 12)

                Divider()

                NumberPad(
                    type: amountViewModel.getNumberPadType(currency: currency),
                    errorKey: amountViewModel.errorKey
                ) { key in
                    amountViewModel.handleNumberPadInput(key, currency: currency)
                }

                CustomButton(title: t("common__continue"), isDisabled: !isValid) {
                    onContinue()
                }
                .accessibilityIdentifier("ContinueAmount")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }

    private func onContinue() {
        let minSendable = app.lnurlPayData!.minSendable

        if amount < minSendable {
            app.toast(
                type: .error, title: t("wallet__lnurl_pay__error_min__title"),
                description: t("wallet__lnurl_pay__error_min__description", variables: ["amount": "\(minSendable)"]),
                accessibilityIdentifier: "LnurlPayAmountTooLowToast"
            )
            return
        }

        wallet.sendAmountSats = amount
        navigationPath.append(.lnurlPayConfirm)
    }
}
