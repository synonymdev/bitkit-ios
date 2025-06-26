import SwiftUI

struct SendSuccess: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel

    // TODO: add confetti

    var body: some View {
        VStack {
            SheetHeader(title: localizedString("wallet__send_sent"), showBackButton: false)

            if let invoice = app.scannedLightningInvoice {
                MoneyStack(sats: Int(invoice.amountSatoshis))
            }

            Spacer()

            Image("check")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Spacer()

            HStack(spacing: 16) {
                CustomButton(title: localizedString("wallet__send_details"), variant: .secondary) {
                    // TODO: navigate to activity details screen
                }

                CustomButton(title: localizedString("common__close")) {
                    sheets.hideSheet()
                }
            }

        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
