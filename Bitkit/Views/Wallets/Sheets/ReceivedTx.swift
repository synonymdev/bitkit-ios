import SwiftUI

struct ReceivedTxSheetItem: SheetItem {
    let id: SheetID = .receivedTx
    let size: SheetSize = .large
    let details: ReceivedTxSheetDetails
}

struct ReceivedTx: View {
    let config: ReceivedTxSheetItem

    @EnvironmentObject private var sheets: SheetViewModel

    // Keep in state so we don't get a new random text on each render
    @State private var buttonText: String = localizedRandom("common__ok_random")

    var body: some View {
        let isOnchain = config.details.type == .onchain
        let title = isOnchain ? localizedString("wallet__payment_received") : localizedString("wallet__instant_payment_received")

        Sheet(id: .receivedTx, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: title)

                MoneyStack(sats: Int(config.details.sats))

                Spacer()

                Image("check")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 300, height: 300)
                    .frame(maxWidth: .infinity, alignment: .center)

                Spacer()

                CustomButton(title: buttonText) {
                    sheets.hideSheet()
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                ReceivedTx(config: ReceivedTxSheetItem(details: ReceivedTxSheetDetails(type: .lightning, sats: 1000)))
                    .environmentObject(SheetViewModel())
            }
        )
        .presentationDetents([.height(UIScreen.screenHeight - 120)])
        .preferredColorScheme(.dark)
}
