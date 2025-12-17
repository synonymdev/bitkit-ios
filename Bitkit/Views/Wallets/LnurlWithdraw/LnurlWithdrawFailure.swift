import SwiftUI

struct LnurlWithdrawFailure: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    let amount: UInt64

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("other__lnurl_withdr_failure_title"), showBackButton: true)

            MoneyStack(sats: Int(amount), showSymbol: true)
                .padding(.top, 16)
                .padding(.bottom, 42)

            BodyMText(t("other__lnurl_withdr_failure_text"))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image("exclamation-mark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: UIScreen.main.bounds.width * 0.8)
                .frame(maxHeight: 256)

            Spacer()

            HStack(alignment: .center, spacing: 16) {
                CustomButton(title: t("lightning__support"), variant: .secondary) {
                    onSupport()
                }

                CustomButton(title: t("wallet__recipient_scan")) {
                    onScan()
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }

    private func onSupport() {
        sheets.hideSheet()
        navigation.navigate(.support)
    }

    private func onScan() {
        sheets.showSheet(.scanner)
    }
}
