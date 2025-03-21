//
//  SavingsConfirmView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/13.
//

import LDKNode
import SwiftUI

struct SavingsConfirmView: View {
    @State private var showSettingUp = false
    @State private var hideSwipeButton = false

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var transfer: TransferViewModel

    private var hasMultipleChannels: Bool {
        guard let channels = wallet.channels else { return false }
        return channels.filter { $0.isChannelReady && $0.isUsable }.count > 1
    }

    private var hasSelectedChannels: Bool {
        return !transfer.selectedChannelIds.isEmpty
    }

    private var channelsToDisplay: [ChannelDetails] {
        guard let channels = wallet.channels else { return [] }
        let usableChannels = channels.filter { $0.isChannelReady && $0.isUsable }

        if transfer.selectedChannelIds.isEmpty {
            return usableChannels
        } else {
            return usableChannels.filter { transfer.selectedChannelIds.contains($0.channelId) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString("lightning__transfer__confirm", comment: ""), accentColor: .brandAccent)
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 8) {
                    BodySText(NSLocalizedString("lightning__savings_confirm__label", comment: "").uppercased(), textColor: .textSecondary)

                    let totalSats = channelsToDisplay.reduce(0) { $0 + $1.outboundCapacityMsat / 1000 }
                    TransferAmount(
                        defaultValue: UInt64(totalSats),
                        primaryDisplay: .constant(currency.primaryDisplay),
                        overrideSats: .constant(UInt64(totalSats))
                    ) { _ in }
                        .disabled(true)
                }
                .padding(.vertical, 16)

                if hasMultipleChannels {
                    HStack(spacing: 16) {
                        if hasSelectedChannels {
                            Button(action: {
                                transfer.setSelectedChannelIds([])
                            }) {
                                CustomButton(title: NSLocalizedString("lightning__savings_confirm__transfer_all", comment: ""), size: .small)
                            }
                        } else {
                            NavigationLink(destination: SavingsAdvancedView()) {
                                CustomButton(title: NSLocalizedString("common__advanced", comment: ""), size: .small)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                        title: NSLocalizedString("lightning__transfer__swipe", comment: ""),
                        accentColor: .brandAccent
                    ) {
                        do {
                            // Process transfer to savings action
                            transfer.onTransferToSavingsConfirm(channels: channelsToDisplay)

                            try await Task.sleep(nanoseconds: 300_000_000)

                            showSettingUp = true

                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                hideSwipeButton = true
                            }
                        } catch {
                            app.toast(error)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            NavigationLink(destination: SavingsProgressView().environmentObject(transfer), isActive: $showSettingUp) {
                EmptyView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("lightning__transfer__nav_title", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    app.showTransferToSavingsSheet = false
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                }
            }
        }
    }
}

#Preview {
    NavigationView {
        SavingsConfirmView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject({
                let vm = TransferViewModel()
                return vm
            }())
    }
    .preferredColorScheme(.dark)
}
