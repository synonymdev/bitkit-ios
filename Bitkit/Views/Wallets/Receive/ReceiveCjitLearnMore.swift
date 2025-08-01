import BitkitCore
import SwiftUI

struct ReceiveCjitLearnMore: View {
    let entry: IcJitEntry
    let receiveAmountSats: UInt64

    @Environment(\.dismiss) var dismiss

    // TODO: check if additional CJIT
    let isAdditional = false

    var text: String {
        isAdditional
            ? localizedString("wallet__receive_liquidity__text_additional")
            : localizedString("wallet__receive_liquidity__text")
    }

    var label: String {
        isAdditional
            ? localizedString("wallet__receive_liquidity__label_additional")
            : localizedString("wallet__receive_liquidity__label")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: localizedString("wallet__receive_liquidity__nav_title"), showBackButton: true)

            BodyMText(text)

            VStack(alignment: .leading, spacing: 16) {
                SubtitleText(label)
                LightningChannel(
                    capacity: entry.channelSizeSat,
                    localBalance: receiveAmountSats - entry.feeSat,
                    remoteBalance: entry.channelSizeSat - (receiveAmountSats - entry.feeSat),
                    status: .open,
                    showLabels: true
                )
            }
            .padding(.top, 32)

            Spacer()

            CustomButton(title: localizedString("common__understood")) {
                dismiss()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }
}
