import SwiftUI

struct LnurlWithdrawConfirm: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
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
            SheetHeader(title: t("wallet__lnurl_w_title"), showBackButton: true)

            MoneyStack(sats: Int(amount), showSymbol: true)
                .padding(.top, 16)
                .padding(.bottom, 42)

            BodyMText(t("wallet__lnurl_w_text"))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image("transfer-figure")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: UIScreen.main.bounds.width * 0.8)
                .frame(maxHeight: 256)

            Spacer()

            CustomButton(title: t("wallet__lnurl_w_button"), isLoading: isLoading) {
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
                    throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing LNURL withdraw data"])
                }

                // Create a Lightning invoice for the withdraw
                let invoice = try await wallet.createInvoice(
                    amountSats: amount,
                    note: withdrawData.defaultDescription,
                    expirySecs: 3600
                )

                // Perform the LNURL withdraw
                try await LnurlHelper.handleLnurlWithdraw(
                    params: withdrawData,
                    invoice: invoice
                )

                await MainActor.run {
                    app.toast(
                        type: .info,
                        title: t("other__lnurl_withdr_success_title"),
                        description: t("other__lnurl_withdr_success_msg")
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
