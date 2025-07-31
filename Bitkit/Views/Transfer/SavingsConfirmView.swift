//
//  SavingsConfirmView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/13.
//

import LDKNode
import SwiftUI

struct SavingsConfirmView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var hideSwipeButton = false

    private var hasMultipleChannels: Bool {
        guard let channels = wallet.channels else { return false }
        return channels.filter { $0.isChannelReady }.count > 1
    }

    private var hasSelectedChannels: Bool {
        return !transfer.selectedChannelIds.isEmpty
    }

    private var channels: [ChannelDetails] {
        guard let channels = wallet.channels else { return [] }
        let usableChannels = channels.filter { $0.isChannelReady }

        if transfer.selectedChannelIds.isEmpty {
            return usableChannels
        } else {
            return usableChannels.filter { transfer.selectedChannelIds.contains($0.channelId) }
        }
    }

    private var totalSats: UInt64 {
        channels.reduce(0) { $0 + $1.outboundCapacityMsat / 1000 + ($1.unspendablePunishmentReserve ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayText(localizedString("lightning__transfer__confirm"), accentColor: .brandAccent)

            CaptionMText(localizedString("lightning__savings_confirm__label"))
                .padding(.top, 32)

            MoneyText(sats: Int(totalSats), size: .display, symbol: true)

            if hasMultipleChannels {
                HStack(spacing: 16) {
                    if hasSelectedChannels {
                        CustomButton(title: localizedString("lightning__savings_confirm__transfer_all"), size: .small) {
                            transfer.setSelectedChannelIds([])
                        }
                    } else {
                        CustomButton(title: localizedString("common__advanced"), size: .small) {
                            navigation.navigate(.savingsAdvanced)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
            }

            Spacer()

            // Piggybank image
            Image("piggybank-right")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            if !hideSwipeButton {
                SwipeButton(
                    title: localizedString("lightning__transfer__swipe"),
                    accentColor: .brandAccent
                ) {
                    do {
                        // Process transfer to savings action
                        transfer.onTransferToSavingsConfirm(channels: channels)

                        try await Task.sleep(nanoseconds: 300_000_000)

                        navigation.navigate(.savingsProgress)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            hideSwipeButton = true
                        }
                    } catch {
                        app.toast(error)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__transfer__nav_title"))
        .backToWalletButton()
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        SavingsConfirmView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(
                {
                    let vm = TransferViewModel()
                    return vm
                }())
    }
    .preferredColorScheme(.dark)
}
