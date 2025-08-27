import SwiftUI

struct LnurlPayAmount: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Binding var navigationPath: [SendRoute]
    @State private var amount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @FocusState private var isAmountFocused: Bool

    var maxAmount: UInt64 {
        // TODO: subtract fee
        min(app.lnurlPayData!.maxSendable, UInt64(wallet.totalLightningSats))
    }

    var isValid: Bool {
        amount >= 0 && amount <= maxAmount
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__lnurl_p_title"), showBackButton: true)

            VStack(alignment: .leading, spacing: 16) {
                AmountInput(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats, showConversion: true) { newAmount in
                    amount = newAmount
                }
                .padding(.vertical, 16)

                Spacer()

                HStack(alignment: .bottom) {
                    AvailableAmount(label: t("wallet__send_available_spending"), amount: wallet.totalLightningSats)
                        .onTapGesture {
                            overrideSats = UInt64(wallet.totalLightningSats)
                        }

                    Spacer()

                    NumberPadActionButton(text: t("common__max"), color: .brandAccent) {
                        overrideSats = maxAmount
                    }

                    NumberPadActionButton(
                        text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                        imageName: "arrow-up-down",
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
        let minSendable = app.lnurlPayData!.minSendable

        if amount < minSendable {
            app.toast(
                type: .error, title: t("wallet__lnurl_pay__error_min__title"),
                description: t("wallet__lnurl_pay__error_min__description", variables: ["amount": "\(minSendable)"])
            )
            return
        }

        // TODO: hide number pad
        wallet.sendAmountSats = amount
        navigationPath.append(.lnurlPayConfirm)
    }
}
