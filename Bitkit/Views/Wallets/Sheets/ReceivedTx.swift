import BitkitCore
import SwiftUI

struct ReceivedTxSheetDetails: Codable {
    enum ReceivedTxType: Codable {
        case onchain
        case lightning
    }

    let type: ReceivedTxType
    var sats: UInt64 = 0
    var usdtAmount: UInt64? = nil
}

struct ReceivedTxSheetItem: SheetItem {
    let id: SheetID = .receivedTx
    let size: SheetSize = .large
    let details: ReceivedTxSheetDetails
}

struct ReceivedTx: View {
    let config: ReceivedTxSheetItem

    @EnvironmentObject private var sheets: SheetViewModel

    /// Keep in state so we don't get a new random text on each render
    @State private var buttonText: String = localizedRandom("common__ok_random")

    var body: some View {
        let isOnchain = config.details.type == .onchain
        let title = config.details.usdtAmount != nil ? t("usdt__payment_received")
            : isOnchain ? t("wallet__payment_received") : t("wallet__instant_payment_received")

        Sheet(id: .receivedTx, data: config) {
            ZStack {
                PaymentCelebration(
                    isOnchain: isOnchain, isReceived: true,
                    confettiColor: config.details.usdtAmount != nil ? .greenAccent : nil
                )

                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(title: title)
                    if let amount = config.details.usdtAmount {
                        UsdtAmountHeader(amount: usdtFormatAmount(amount: amount), network: "Arbitrum One")
                            .accessibilityIdentifier("ReceivedTransaction")
                    } else {
                        MoneyStack(sats: Int(config.details.sats), showSymbol: true, testIdPrefix: "ReceivedTransaction")
                    }
                    Spacer()
                    CustomButton(title: buttonText) { sheets.hideSheet() }
                        .accessibilityIdentifier("ReceivedTransactionButton")
                }
                .padding(.horizontal, 16)
            }
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
