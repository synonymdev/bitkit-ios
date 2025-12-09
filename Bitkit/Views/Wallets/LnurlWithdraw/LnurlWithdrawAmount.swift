import SwiftUI

struct LnurlWithdrawAmount: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Binding var navigationPath: [LnurlWithdrawRoute]

    @StateObject private var amountViewModel = AmountInputViewModel()

    var minAmount: Int {
        Int((app.lnurlWithdrawData!.minWithdrawable ?? 1000) / 1000)
    }

    var maxAmount: Int {
        Int((app.lnurlWithdrawData!.maxWithdrawable) / 1000)
    }

    var amount: UInt64 {
        amountViewModel.amountSats
    }

    var isValid: Bool {
        amount <= maxAmount
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__lnurl_w_title"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                NumberPadTextField(viewModel: amountViewModel, testIdentifier: "SendNumberField")
                    .onTapGesture {
                        amountViewModel.togglePrimaryDisplay(currency: currency)
                    }
                    .padding(.vertical, 16)

                Spacer()

                HStack(alignment: .bottom) {
                    AvailableAmount(label: t("wallet__lnurl_w_max"), amount: maxAmount)
                        .onTapGesture {
                            amountViewModel.updateFromSats(UInt64(maxAmount), currency: currency)
                        }

                    Spacer()

                    NumberPadActionButton(
                        text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                        imageName: "transfer",
                        color: .brandAccent
                    ) {
                        withAnimation {
                            amountViewModel.togglePrimaryDisplay(currency: currency)
                        }
                    }
                }
                .padding(.bottom, 12)

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
        .onAppear {
            if amountViewModel.amountSats == 0 {
                amountViewModel.updateFromSats(UInt64(minAmount), currency: currency)
            }
        }
    }

    private func onContinue() {
        // If minimum is above the amount the user entered, automatically set amount to that minimum
        if amount < minAmount {
            amountViewModel.updateFromSats(UInt64(minAmount), currency: currency)
        }

        wallet.lnurlWithdrawAmount = amount

        navigationPath.append(.confirm)
    }
}
