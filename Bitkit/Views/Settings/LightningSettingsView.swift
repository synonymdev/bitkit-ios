//
//  LightningSettingsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct LightningSettingsView: View {
    @ObservedObject var wallet = WalletViewModel.shared

    var body: some View {
        List {
            Section("Node") {
                Text(wallet.lightningState.displayState)
                    .font(.caption)

                if let nodeId = wallet.lightningNodeId {
                    Text("LN Node ID: \(nodeId)")
                        .font(.caption)
                        .onTapGesture {
                            UIPasteboard.general.string = nodeId
                        }
                }
            }

            if let peers = wallet.lightningPeers {
                Section("Peers") {
                    ForEach(peers, id: \.nodeId) { peer in
                        HStack {
                            Text("\(peer.nodeId)@\(peer.address)")
                                .font(.caption2)
                            Spacer()
                            Text(peer.isConnected ? "✅" : "❌")
                        }
                    }
                }
            }

            Button("Create bolt11") {
                Task {
                    let invoice = try await LightningService.shared.receive(amountSats: 123, description: "paymeplz")
                    Logger.info(invoice, context: "Created invoice")
                    UIPasteboard.general.string = invoice
                }
            }

            if let channels = wallet.lightningChannels {
                Section("Channels") {
                    ForEach(channels, id: \.channelId) { channel in
                        VStack {
                            Text(channel.counterpartyNodeId).font(.caption2)
                                .multilineTextAlignment(.leading)
                            HStack {
                                Text("Out: \(channel.outboundCapacityMsat)")
                                Spacer()
                                Text("In: \(channel.inboundCapacityMsat)")
                                Text(channel.isChannelReady ? "🟢" : "🔴")
                                Text(channel.isUsable ? "🟢" : "🔴")
                            }
                        }
                        .onLongPressGesture {
                            Task {
                                do {
                                    try await LightningService.shared.closeChannel(userChannelId: channel.userChannelId, counterpartyNodeId: channel.counterpartyNodeId)
                                    Logger.info("Channel closed")
                                    try await wallet.sync()
                                } catch {}
                            }
                        }
                    }

                    Button("Copy open channel command") {
                        let cmd = "lncli openchannel --node_key=\(wallet.lightningNodeId ?? "") --local_amt=200000 --push_amt=10000 --private=true --zero_conf --channel_type=anchors"
                        UIPasteboard.general.string = cmd
                    }
                }
            }

            Section("Blocktank") {
                Button("Register for notifications") {
                    StartupHandler.requestPushNotificationPermision { _, error in
                        // If granted AppDelegate will receive the token and handle registration
                        if let error {
                            Logger.error(error, context: "Failed to request push notification permission")
                        }
                    }
                }

                Button("Self test") {
                    Task {
                        sleep(2) // Chance to background the app
                        do {
                            try await BlocktankService.shared.selfTest()
                        } catch {
                            Logger.error(error, context: "Failed to self test")
                        }
                    }
                }

                if let peer = Env.trustedLnPeers.first {
                    Button("Open channel to trusted peer") {
                        Task { @MainActor in
                            do {
                                let _ = try await LightningService.shared.openChannel(
                                    peer: peer,
                                    channelAmountSats: 20000,
                                    pushToCounterpartySats: 10000
                                )
                            } catch {
                                Logger.error(error, context: "Failed to open test channel")
                            }
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    LightningSettingsView()
}
