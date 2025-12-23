import BitkitCore
import SwiftUI

struct ReceiveCjitLearnMore: View {
    let entry: IcJitEntry
    let receiveAmountSats: UInt64
    let isAdditional: Bool

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var settings: SettingsViewModel

    var text: String {
        isAdditional
            ? t("wallet__receive_liquidity__text_additional")
            : t("wallet__receive_liquidity__text")
    }

    var label: String {
        isAdditional
            ? t("wallet__receive_liquidity__label_additional")
            : t("wallet__receive_liquidity__label")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__receive_liquidity__nav_title"), showBackButton: true)

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

            BodyMText(tTodo("Enable background setup to safely exit Bitkit while your balance is being configured."))
                .padding(.bottom, 16)

            HStack(alignment: .center, spacing: 0) {
                BodyMText(tTodo("Enable background setup"), textColor: .textPrimary)

                Spacer()

                Toggle("", isOn: $settings.enableNotifications)
                    .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                    .labelsHidden()
            }
            .frame(height: 50)
            .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 22)

            CustomButton(title: t("common__understood")) {
                dismiss()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }
}
