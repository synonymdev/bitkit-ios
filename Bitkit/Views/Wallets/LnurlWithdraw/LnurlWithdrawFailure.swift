import SwiftUI

struct LnurlWithdrawFailure: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @Binding var navigationPath: [LnurlWithdrawRoute]
    let amount: UInt64

    // TODO: add localized strings

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Withdrawal Failed", showBackButton: true)

            MoneyStack(sats: Int(amount), showSymbol: true)
                .padding(.top, 16)
                .padding(.bottom, 42)

            BodyMText("Your withdrawal was unsuccessful. Please scan the QR code again or contact support.")
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image("exclamation-mark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: UIScreen.main.bounds.width * 0.8)
                .frame(maxHeight: 256)

            Spacer()

            HStack(alignment: .center, spacing: 16) {
                CustomButton(title: "Support", variant: .secondary) {
                    onSupport()
                }

                CustomButton(title: "Scan QR") {
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
