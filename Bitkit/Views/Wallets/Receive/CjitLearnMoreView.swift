import SwiftUI

struct CjitLearnMoreView: View {
    let entry: IcJitEntry
    let receiveAmountSats: UInt64

    @EnvironmentObject var currency: CurrencyViewModel
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BodyMText(NSLocalizedString("lightning__liquidity__text", comment: ""), textColor: Color.textSecondary)
                .padding(.vertical, 16)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                SubtitleText(NSLocalizedString("wallet__receive_liquidity__label_additional", comment: ""))
                LightningChannel(
                    capacity: entry.channelSizeSat,
                    localBalance: receiveAmountSats - entry.feeSat,
                    remoteBalance: entry.channelSizeSat - (receiveAmountSats - entry.feeSat),
                    status: .open,
                    showLabels: true
                )
            }
            .padding(.vertical, 16)

            CustomButton(title: NSLocalizedString("common__understood", comment: "")) {
                presentationMode.wrappedValue.dismiss()
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .sheetBackground()
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("wallet__receive_liquidity__nav_title", comment: ""))
        .background(Color.black)
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationStack {
                    CjitLearnMoreView(entry: IcJitEntry.mock(), receiveAmountSats: 100_000)
                        .environmentObject(CurrencyViewModel())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
