//
//  SavingsAdvancedView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2025/03/21.
//

import LDKNode
import SwiftUI

struct SavingsAdvancedView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString("lightning__savings_advanced__title", comment: ""), accentColor: .brandAccent)
                    .padding(.top, 16)

                BodyMText(NSLocalizedString("lightning__savings_advanced__text", comment: ""), textColor: .textSecondary, accentColor: .white)
                    .padding(.bottom, 16)

                if let channels = wallet.channels {
                    VStack(spacing: 0) {
                        ForEach(Array(channels.enumerated()), id: \.element.channelId) { index, channel in
                            channelView(channel: channel, index: index, isLast: index == channels.count - 1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(8)
                }

                Spacer()
            }
            .padding(.horizontal, 16)

            Divider()

            Spacer()

            CustomButton(title: NSLocalizedString("common__continue", comment: "")) {
                presentationMode.wrappedValue.dismiss()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
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
        .task {
            if transfer.selectedChannelIds.isEmpty, let channels = wallet.channels {
                transfer.selectedChannelIds = channels.map { $0.channelId }
            }
        }
    }

    @ViewBuilder
    private func channelView(channel: ChannelDetails, index: Int, isLast: Bool) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(NSLocalizedString("lightning__connection", comment: "").uppercased() + " \(index + 1)")
                    .foregroundColor(.gray)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }

            HStack {
                if let converted = currency.convert(sats: UInt64(channel.outboundCapacityMsat / 1000)) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if currency.primaryDisplay == .bitcoin {
                            let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                            Text(btcComponents.value)
                        } else {
                            Text("\(converted.symbol) \(converted.formatted)")
                        }
                    }
                }
                Spacer()

                Toggle("", isOn: Binding(
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
                ))
                .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
            }
        }
        .padding(.vertical, 16)

        if !isLast {
            Divider()
                .background(Color.gray.opacity(0.3))
        }
    }
}

#Preview {
    NavigationView {
        SavingsAdvancedView()
            .environmentObject(AppViewModel())
            .environmentObject(TransferViewModel())
            .environmentObject(WalletViewModel())
            .environmentObject(CurrencyViewModel())
    }
    .preferredColorScheme(.dark)
}
