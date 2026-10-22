import SwiftUI

struct ChannelsUnavailableSheetItem: SheetItem {
    let id: SheetID = .channelsUnavailable
    let size: SheetSize = .medium
}

/// Shown where the app used to start a transfer to spending: Blocktank no longer opens new channels.
struct ChannelsUnavailableSheet: View {
    let config: ChannelsUnavailableSheetItem

    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    var body: some View {
        Sheet(id: .channelsUnavailable, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: t("lightning__channels_unavailable__title"))

                BodyMText(t("lightning__channels_unavailable__text"), textColor: .textSecondary)

                if wallet.hasTrustedChannels {
                    BodyMText(
                        t("lightning__channels_closing_notice", variables: ["date": ChannelsClosing.formattedCloseDate()]),
                        textColor: .textSecondary
                    )
                    .padding(.top, 16)
                    .accessibilityIdentifier("ChannelsUnavailableCloseDate")
                }

                Spacer()

                Image("exclamation-mark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
                    .frame(maxWidth: .infinity)

                Spacer()

                CustomButton(title: t("common__ok")) {
                    sheets.hideSheet()
                }
                .accessibilityIdentifier("ChannelsUnavailableButton")
            }
            .padding(.horizontal, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ChannelsUnavailableSheet")
    }
}
