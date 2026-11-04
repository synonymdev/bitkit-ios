import BitkitCore
import SwiftUI

struct LnurlWithdrawConfirm: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    let onFailure: (UInt64) -> Void
    @State private var isLoading = false
    @State private var withdrawTask: Task<Void, Never>?

    private func displayAmountSats(for withdrawData: LnurlWithdrawData) -> UInt64? {
        if withdrawData.isFixedAmount {
            return withdrawData.minWithdrawableSat
        }
        return wallet.lnurlWithdrawAmount
    }

    var body: some View {
        ZStack {
            if let withdrawData = app.lnurlWithdrawData, let amountSats = displayAmountSats(for: withdrawData) {
                confirmationContent(withdrawData: withdrawData, amountSats: amountSats)
            }
        }
        .onDisappear {
            withdrawTask?.cancel()
        }
    }

    private func confirmationContent(withdrawData: LnurlWithdrawData, amountSats: UInt64) -> some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__lnurl_w_title"), showBackButton: true)

            MoneyStack(sats: Int(clamping: amountSats), showSymbol: true, testIdPrefix: "WithdrawAmount")
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
                performWithdraw(withdrawData: withdrawData, amountSats: amountSats)
            }
            .accessibilityIdentifier("WithdrawConfirmButton")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }

    private func performWithdraw(withdrawData: LnurlWithdrawData, amountSats: UInt64) {
        isLoading = true

        withdrawTask = Task {
            await Self.withdraw(withdrawData: withdrawData, amountSats: amountSats, wallet: wallet) {
                app.toast(
                    type: .info,
                    title: t("other__lnurl_withdr_success_title"),
                    description: t("other__lnurl_withdr_success_msg")
                )
                isLoading = false
                sheets.hideSheetIfActive(.send, reason: "LNURL withdraw completed")
                sheets.hideSheetIfActive(.lnurlWithdraw, reason: "LNURL withdraw completed")
            } onFailure: {
                onFailure(amountSats)
                isLoading = false
            }
        }
    }

    static func withdraw(
        withdrawData: LnurlWithdrawData,
        amountSats: UInt64,
        wallet: WalletViewModel,
        onSuccess: () -> Void,
        onFailure: () -> Void
    ) async {
        do {
            let invoice: String = if withdrawData.isFixedAmount {
                try await wallet.createInvoiceMsats(
                    amountMsats: withdrawData.maxWithdrawable,
                    note: withdrawData.defaultDescription,
                    expirySecs: 3600
                )
            } else {
                try await wallet.createInvoice(
                    amountSats: amountSats,
                    note: withdrawData.defaultDescription,
                    expirySecs: 3600
                )
            }

            // Perform the LNURL withdraw
            try await LnurlHelper.handleLnurlWithdraw(
                params: withdrawData,
                invoice: invoice
            )
            // Cancelled when the screen disappears; its success handling would hide whatever sheet is open now.
            guard !Task.isCancelled else { return }
            onSuccess()
        } catch {
            guard !Task.isCancelled else { return }
            onFailure()
        }
    }
}
