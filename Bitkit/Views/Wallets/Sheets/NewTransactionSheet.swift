import SwiftUI

struct NewTransactionSheetItem: SheetItem {
    let id: SheetID = .receivedTx
    let size: SheetSize = .large
    let details: NewTransactionSheetDetails
}

struct NewTransactionSheet: View {
    let config: NewTransactionSheetItem

    @EnvironmentObject private var sheets: SheetViewModel

    // Keep in state so we don't get a new random text on each render
    @State private var buttonText: String = localizedRandom("common__ok_random")

    var body: some View {
        let isOnchain = config.details.type == .onchain
        let title = isOnchain ? localizedString("wallet__payment_received") : localizedString("wallet__instant_payment_received")

        Sheet(id: .receivedTx, data: config) {
            SheetHeader(title: title)

            MoneyStack(sats: Int(config.details.sats))

            Spacer()

            Image("check")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 300, height: 300)

            Spacer()

            CustomButton(title: buttonText) {
                sheets.hideSheet()
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NewTransactionSheet(
                    config: NewTransactionSheetItem(details: NewTransactionSheetDetails(type: .lightning, direction: .sent, sats: 1000))
                )
                .environmentObject(SheetViewModel())
            }
        )
        .presentationDetents([.height(UIScreen.screenHeight - 120)])
        .preferredColorScheme(.dark)
}
