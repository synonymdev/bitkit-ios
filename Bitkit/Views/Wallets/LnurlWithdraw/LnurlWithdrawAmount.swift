import BitkitCore
import SwiftUI

struct LnurlWithdrawAmount: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    let onContinue: () -> Void

    @State private var amountViewModel = AmountInputViewModel()

    private func minAmount(for withdrawData: LnurlWithdrawData) -> Int {
        Int(clamping: max(1, withdrawData.minWithdrawableSat))
    }

    private func maxAmount(for withdrawData: LnurlWithdrawData) -> Int {
        Int(clamping: withdrawData.maxWithdrawableSat)
    }

    var amount: UInt64 {
        amountViewModel.amountSats
    }

    var body: some View {
        ZStack {
            if let withdrawData = app.lnurlWithdrawData {
                amountContent(minAmount: minAmount(for: withdrawData), maxAmount: maxAmount(for: withdrawData))
            }
        }
    }

    private func amountContent(minAmount: Int, maxAmount: Int) -> some View {
        let isValid = amount >= minAmount && amount <= max(minAmount, maxAmount)

        return VStack(spacing: 0) {
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
                    handleContinue(minAmount: minAmount)
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
        .onChange(of: maxAmount, initial: true) { _, newMaxAmount in updateInputCap(minAmount: minAmount, maxAmount: newMaxAmount) }
        .onChange(of: amountViewModel.maxExceededCount) { showMaxExceededToast() }
    }

    private func updateInputCap(minAmount: Int, maxAmount: Int) {
        let cap = max(minAmount, maxAmount)
        amountViewModel.maxAmountOverride = cap > 0 ? UInt64(cap) : nil
    }

    private func showMaxExceededToast() {
        app.toast(
            type: .warning,
            title: t("wallet__lnurl_w_error_max__title"),
            description: t("wallet__lnurl_w_error_max__description"),
            visibilityTime: Toast.visibilityTimeShort,
            accessibilityIdentifier: "SendAmountExceededToast"
        )
    }

    private func handleContinue(minAmount: Int) {
        // If minimum is above the amount the user entered, automatically set amount to that minimum
        if amount < minAmount {
            amountViewModel.updateFromSats(UInt64(minAmount), currency: currency)
        }

        wallet.lnurlWithdrawAmount = amount

        onContinue()
    }
}
