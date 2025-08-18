import LDKNode
import SwiftUI

struct SavingsAdvancedView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(\.dismiss) var dismiss

    private var totalSelectedBalance: UInt64 {
        guard let channels = wallet.channels else { return 0 }

        return
            channels
                .filter { transfer.selectedChannelIds.contains($0.channelId) }
                .reduce(0) { total, channel in
                    let balance = channel.outboundCapacityMsat / 1000 + (channel.unspendablePunishmentReserve ?? 0)
                    return total + balance
                }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisplayText(localizedString("lightning__savings_advanced__title"), accentColor: .brandAccent)
                .padding(.bottom, 16)

            BodyMText(localizedString("lightning__savings_advanced__text"))
                .padding(.bottom, 16)

            if let channels = wallet.channels {
                ForEach(Array(channels.enumerated()), id: \.element.channelId) { index, channel in
                    channelView(channel: channel, index: index, isLast: index == channels.count - 1)
                }
            }

            Spacer()

            CaptionMText(localizedString("lightning__savings_advanced__total"))
                .padding(.bottom, 16)

            MoneyText(sats: Int(totalSelectedBalance), size: .display, symbol: true)
                .padding(.bottom, 32)

            CustomButton(
                title: localizedString("common__continue"),
                isDisabled: transfer.selectedChannelIds.isEmpty
            ) {
                dismiss()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__transfer__nav_title"))
        .backToWalletButton()
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .bottomSafeAreaPadding()
        .task {
            if transfer.selectedChannelIds.isEmpty, let channels = wallet.channels {
                transfer.selectedChannelIds = channels.map(\.channelId)
            }
        }
    }

    @ViewBuilder
    private func channelView(channel: ChannelDetails, index: Int, isLast: Bool) -> some View {
        let balance = channel.outboundCapacityMsat / 1000 + (channel.unspendablePunishmentReserve ?? 0)

        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(localizedString("lightning__connection") + " \(index + 1)")
                    MoneyText(sats: Int(balance), size: .bodySSB, symbol: true)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: {
                            transfer.selectedChannelIds.contains(channel.channelId)
                        },
                        set: { isSelected in
                            if isSelected {
                                if !transfer.selectedChannelIds.contains(channel.channelId) {
                                    transfer.selectedChannelIds.append(channel.channelId)
                                }
                            } else {
                                transfer.selectedChannelIds.removeAll { $0 == channel.channelId }
                            }
                        }
                    )
                )
                .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
            }
        }
        .padding(.vertical, 16)

        Divider()
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
