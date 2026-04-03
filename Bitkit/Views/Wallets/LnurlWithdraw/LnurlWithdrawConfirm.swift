import SwiftUI

struct LnurlWithdrawConfirm: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    let onFailure: (UInt64) -> Void
    @State private var isLoading = false

    var isFixedAmount: Bool {
        app.lnurlWithdrawData!.maxWithdrawable == app.lnurlWithdrawData!.minWithdrawable
    }

    var displayAmountSats: UInt64 {
        if isFixedAmount {
            return LightningAmountConversion.satsCeil(fromMsats: app.lnurlWithdrawData!.maxWithdrawable)
        }
        return wallet.lnurlWithdrawAmount!
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__lnurl_w_title"), showBackButton: true)

            MoneyStack(sats: Int(displayAmountSats), showSymbol: true, testIdPrefix: "WithdrawAmount")
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
            .accessibilityIdentifier("WithdrawConfirmButton")
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

                let invoice: String = if isFixedAmount {
                    try await wallet.createInvoiceMsats(
                        amountMsats: withdrawData.maxWithdrawable,
                        note: withdrawData.defaultDescription,
                        expirySecs: 3600
                    )
                } else {
                    try await wallet.createInvoice(
                        amountSats: displayAmountSats,
                        note: withdrawData.defaultDescription,
                        expirySecs: 3600
                    )
                }

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
                    sheets.hideSheetIfActive(.send, reason: "LNURL withdraw completed")
                    sheets.hideSheetIfActive(.lnurlWithdraw, reason: "LNURL withdraw completed")
                }

            } catch {
                await MainActor.run {
                    onFailure(displayAmountSats)
                    isLoading = false
                }
            }
        }
    }
}
