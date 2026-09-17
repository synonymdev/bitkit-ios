import BitkitCore
import SwiftUI

struct ReceiveCjitLearnMore: View {
    let entry: IcJitEntry
    let receiveAmountSats: UInt64
    let isAdditional: Bool

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    private var isAdditionalFlow: Bool {
        isAdditional || wallet.hasExistingChannels
    }

    var navTitle: String {
        isAdditionalFlow
            ? t("wallet__receive_liquidity__nav_title_additional")
            : t("wallet__receive_liquidity__nav_title")
    }

    var text: String {
        isAdditionalFlow
            ? t("wallet__receive_liquidity__text_additional")
            : t("wallet__receive_liquidity__text")
    }

    var label: String {
        isAdditionalFlow
            ? t("wallet__receive_liquidity__label_additional")
            : t("wallet__receive_liquidity__label")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: navTitle, showBackButton: true)

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

            BodyMText(t("wallet__receive_background_setup_text"))
                .padding(.bottom, 16)

            HStack(alignment: .center, spacing: 0) {
                BodyMText(t("wallet__receive_background_setup_toggle"), textColor: .textPrimary)

                Spacer()

                Toggle("", isOn: $settings.enableNotifications)
                    .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                    .labelsHidden()
                    .accessibilityIdentifier("ReceiveLiquidityNotificationSwitch")
            }
            .frame(height: 50)
            .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 22)

            CustomButton(title: t("common__understood")) {
                dismiss()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ReceiveCjitLiquidity")
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }
}
