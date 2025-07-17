import SwiftUI

struct LnurlWithdrawConfirm: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @Binding var navigationPath: [LnurlWithdrawRoute]
    @State private var isLoading = false

    var amount: UInt64 {
        // Fixed amount
        if app.lnurlWithdrawData!.maxWithdrawable == app.lnurlWithdrawData!.minWithdrawable {
            return app.lnurlWithdrawData!.maxWithdrawable / 1000
        }

        // For variable amount, use the amount from the previous screen
        return wallet.lnurlWithdrawAmount!
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: localizedString("wallet__lnurl_w_title"), showBackButton: true)

            AmountInput(
                defaultValue: amount,
                primaryDisplay: $currency.primaryDisplay,
                showConversion: true
            ) { _ in
                // This is a read-only view, so we don't need to handle changes
            }
            .padding(.top, 16)
            .padding(.bottom, 42)
            .disabled(true) // Disable interaction since this is just for display

            BodyMText(localizedString("wallet__lnurl_w_text"))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image("transfer")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: UIScreen.main.bounds.width * 0.8)
                .frame(maxHeight: 256)

            Spacer()

            CustomButton(title: localizedString("wallet__lnurl_w_button"), isLoading: isLoading) {
                performWithdraw()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }

    private func performWithdraw() {
        isLoading = true

        Task {
            do {
                guard let withdrawData = app.lnurlWithdrawData else {
                    throw NSError(domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing LNURL withdraw data"])
                }

                // Perform the LNURL withdraw
                try await LnurlHelper.handleLnurlWithdraw(
                    amount: amount,
                    params: withdrawData,
                    wallet: wallet
                )

                await MainActor.run {
                    app.toast(
                        type: .info,
                        title: localizedString("other__lnurl_withdr_success_title"),
                        description: localizedString("other__lnurl_withdr_success_msg")
                    )
                    isLoading = false
                    sheets.hideSheet()
                }

            } catch {
                await MainActor.run {
                    navigationPath.append(.failure(amount: amount))
                    isLoading = false
                }
            }
        }
    }
}
