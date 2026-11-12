import LDKNode
import SwiftUI

struct SavingsAdvancedView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(\.dismiss) var dismiss

    private var channels: [ChannelDetails] {
        wallet.channels?.filter(\.isChannelReady) ?? []
    }

    private var sparkSats: UInt64 {
        SparkManager.shared.isExiting ? 0 : SparkManager.shared.balanceSats
    }

    private var selection: SavingsSelection {
        transfer.savingsSelection(readyChannelIds: channels.map(\.channelId), sparkSats: sparkSats)
    }

    private var totalSelectedBalance: UInt64 {
        let channelSats = channels
            .filter { selection.channelIds.contains($0.channelId) }
            .reduce(0) { total, channel in
                return total + channel.balanceOnCloseSats
            }
        return channelSats + (selection.withdrawsSpark ? sparkSats : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__savings_advanced__title"), accentColor: .brandAccent)
                .padding(.bottom, 16)

            BodyMText(t("lightning__savings_advanced__text"))
                .padding(.bottom, 16)

            ForEach(Array(channels.enumerated()), id: \.element.channelId) { index, channel in
                channelView(channel: channel, index: index, isLast: index == channels.count - 1)
            }

            if sparkSats > 0 {
                sparkView
            }

            Spacer()

            CaptionMText(t("lightning__savings_advanced__total"))
                .padding(.bottom, 16)

            MoneyText(sats: Int(totalSelectedBalance), size: .display, symbol: true)
                .padding(.bottom, 32)

            CustomButton(
                title: t("common__continue"),
                isDisabled: selection.isEmpty
            ) {
                dismiss()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            if transfer.selectedChannelIds == nil {
                transfer.selectedChannelIds = Set(channels.map(\.channelId))
            }
        }
    }

    @ViewBuilder
    private func channelView(channel: ChannelDetails, index: Int, isLast: Bool) -> some View {
        let balance = channel.balanceOnCloseSats

        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("lightning__connection") + " \(index + 1)")
                    MoneyText(sats: Int(balance), size: .bodySSB, symbol: true)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: {
                            selection.channelIds.contains(channel.channelId)
                        },
                        set: { isSelected in
                            var ids = transfer.selectedChannelIds ?? Set(channels.map(\.channelId))
                            if isSelected {
                                ids.insert(channel.channelId)
                            } else {
                                ids.remove(channel.channelId)
                            }
                            transfer.selectedChannelIds = ids
                        }
                    )
                )
                .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
            }
        }
        .padding(.vertical, 16)

        Divider()
    }

    private var sparkView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("lightning__spark"))
                    MoneyText(sats: Int(sparkSats), size: .bodySSB, symbol: true)
                }

                Spacer()

                Toggle("", isOn: $transfer.isSparkSelected)
                    .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                    .accessibilityIdentifier("SavingsSparkToggle")
            }
            .padding(.vertical, 16)

            Divider()
        }
    }
}

#Preview {
    NavigationStack {
        SavingsAdvancedView()
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
            .environmentObject(WalletViewModel())
            .environmentObject(CurrencyViewModel())
    }
    .preferredColorScheme(.dark)
}
