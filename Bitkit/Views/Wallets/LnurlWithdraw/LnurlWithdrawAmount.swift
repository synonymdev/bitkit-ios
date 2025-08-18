import SwiftUI

struct LnurlWithdrawAmount: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Binding var navigationPath: [LnurlWithdrawRoute]
    @State private var amount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @FocusState private var isAmountFocused: Bool

    var minAmount: Int {
        Int((app.lnurlWithdrawData!.minWithdrawable ?? 1000) / 1000)
    }

    var maxAmount: Int {
        Int((app.lnurlWithdrawData!.maxWithdrawable) / 1000)
    }

    var isValid: Bool {
        amount <= maxAmount
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__lnurl_w_title"), showBackButton: true)

            VStack(alignment: .leading, spacing: 16) {
                AmountInput(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats, showConversion: true) { newAmount in
                    amount = newAmount
                }
                .padding(.vertical, 16)

                Spacer()

                HStack(alignment: .bottom) {
                    AvailableAmount(label: t("wallet__lnurl_w_max"), amount: maxAmount)
                        .onTapGesture {
                            overrideSats = UInt64(maxAmount)
                        }

                    Spacer()

                    NumberPadActionButton(
                        text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                        imageName: "transfer",
                        color: .brandAccent
                    ) {
                        withAnimation {
                            currency.togglePrimaryDisplay()
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            Spacer()

            CustomButton(title: t("common__continue"), isDisabled: !isValid) {
                onContinue()
            }
            .padding(.top, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }

    private func onContinue() {
        // If minimum is above the amount the user entered, automatically set amount to that minimum
        if amount < minAmount {
            amount = UInt64(minAmount)
        }

        wallet.lnurlWithdrawAmount = amount

        // TODO: hide number pad
        navigationPath.append(.confirm)
    }
}
