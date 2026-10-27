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
    var usdtTransferId: String? = nil
    /// A Spark dollar activity, shown with `usdtAmount` as its dollar amount.
    var sparkUsdTransferId: String? = nil
}

struct ReceivedTxSheetItem: SheetItem {
    let id: SheetID = .receivedTx
    let size: SheetSize = .large
    let details: ReceivedTxSheetDetails
}

struct ReceivedTx: View {
    let config: ReceivedTxSheetItem

    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var navigation: NavigationViewModel

    /// Keep in state so we don't get a new random text on each render
    @State private var buttonText: String = localizedRandom("common__ok_random")

    var body: some View {
        let isOnchain = config.details.type == .onchain
        let title = config.details.sparkUsdTransferId != nil ? t("usdt__received_title_spark")
            : config.details.usdtAmount != nil ? t("usdt__payment_received")
            : isOnchain ? t("wallet__payment_received") : t("wallet__instant_payment_received")

        Sheet(id: .receivedTx, data: config, backgroundColor: config.details.usdtAmount != nil ? .gray7 : .black,
              applyGradient: config.details.usdtAmount == nil)
        {
            ZStack {
                PaymentCelebration(
                    isOnchain: isOnchain, isReceived: true,
                    confettiColor: config.details.usdtAmount != nil ? .usdtAccent : nil,
                    isUsdt: config.details.usdtAmount != nil
                )

                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(title: title, topPadding: config.details.usdtAmount != nil ? 28 : 32,
                                bottomPadding: config.details.usdtAmount != nil ? 22 : 24,
                                dragIndicatorTopPadding: config.details.usdtAmount != nil ? 8 : nil,
                                titleKerning: config.details.usdtAmount != nil ? 0 : 0.4)
                    if let amount = config.details.usdtAmount {
                        UsdtAmountHeader(amount: usdtFormatAmount(amount: amount), displayAmount: usdtOverviewAmount(amount))
                            .accessibilityIdentifier("ReceivedTransaction")
                            .contentShape(Rectangle())
                            .onTapGesture { showUsdtDetails() }
                    } else {
                        MoneyStack(sats: Int(config.details.sats), showSymbol: true, testIdPrefix: "ReceivedTransaction")
                    }
                    Spacer()
                    HStack(spacing: 16) {
                        if config.details.usdtTransferId != nil || config.details.sparkUsdTransferId != nil {
                            CustomButton(
                                title: t("wallet__send_details"),
                                variant: .secondary,
                                titleKerning: 0,
                                titleLineHeight: 20,
                                action: showUsdtDetails
                            )
                            .accessibilityIdentifier("ReceivedTransactionDetails")
                        }
                        CustomButton(title: buttonText, titleKerning: config.details.usdtAmount != nil ? 0 : 0.4,
                                     titleLineHeight: config.details.usdtAmount != nil ? 20 : nil) { sheets.hideSheet() }
                            .accessibilityIdentifier("ReceivedTransactionButton")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func showUsdtDetails() {
        if let sparkUsdTransferId = config.details.sparkUsdTransferId {
            sheets.hideSheet()
            navigation.navigate(.sparkUsdActivity(transferId: sparkUsdTransferId))
            return
        }
        guard let transferId = config.details.usdtTransferId else { return }
        sheets.hideSheet()
        navigation.navigate(.usdtActivity(transferId: transferId))
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
