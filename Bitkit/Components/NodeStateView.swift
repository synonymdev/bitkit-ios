//
//  NodeStateView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/04.
//

import LDKNode
import SwiftUI

// So we can iterate through the balances
extension LightningBalance {
    var channelIdString: String {
        switch self {
        case .claimableOnChannelClose(let channelId, _, _),
             .claimableAwaitingConfirmations(let channelId, _, _, _),
             .contentiousClaimable(let channelId, _, _, _, _, _),
             .maybeTimeoutClaimableHtlc(let channelId, _, _, _, _),
             .maybePreimageClaimableHtlc(let channelId, _, _, _, _),
             .counterpartyRevokedOutputClaimable(let channelId, _, _):
            return "\(channelId)"
        }
    }
}

// Create a wrapper struct that conforms to Identifiable
struct IdentifiableLightningBalance: Identifiable {
    let id: String
    let balance: LightningBalance

    init(_ balance: LightningBalance) {
        self.id = balance.channelIdString
        self.balance = balance
    }
}

struct NodeStateView: View {
    @EnvironmentObject var wallet: WalletViewModel

    @State private var closingChannels: [String] = []

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Node state:")
                    Spacer()
                    Image(systemName: wallet.nodeLifecycleState.systemImage)
                    Text(wallet.nodeLifecycleState.displayState)
                }

                if let status = wallet.nodeStatus {
                    HStack {
                        Text("Ready:")
                        Spacer()
                        Text(status.isRunning == true ? "✅" : "⏳")
                    }

                    HStack {
                        Text("Last sync time:")
                        Spacer()
                        if let latestWalletSyncTimestamp = status.latestWalletSyncTimestamp {
                            Text(Date(timeIntervalSince1970: TimeInterval(latestWalletSyncTimestamp)).formatted())
                        } else {
                            Text("Never")
                        }
                    }

                    HStack {
                        Text("Block height:")
                        Spacer()
                        Text("\(status.currentBestBlock.height)")
                    }
                }
            }

            if let nodeId = wallet.nodeId {
                Section("Node ID") {
                    Text(nodeId)
                        .font(.caption)
                        .onTapGesture {
                            UIPasteboard.general.string = nodeId
                            Haptics.play(.copiedToClipboard)
                        }
                }
            }

            if let peers = wallet.peers {
                Section("Peers: \(peers.count)") {
                    ForEach(peers, id: \.nodeId) { peer in
                        HStack {
                            Text("\(peer.nodeId)@\(peer.address)")
                                .font(.caption)
                            Spacer()
                            Text(peer.isConnected ? "✅" : "❌")
                        }
                    }
                }
            }

            if let channels = wallet.channels {
                Section("Channels: \(channels.count)") {
                    ForEach(channels, id: \.channelId) { channel in
                        VStack(alignment: .leading) {
                            Text(channel.channelId)
                                .font(.caption)

                            Text("Ready: \(channel.isChannelReady ? "✅" : "❌")")
                            Text("Public: \(channel.isPublic ? "🌐" : "🔒")")
                            Text("Inbound capacity: \(channel.inboundCapacityMsat / 1000) sats")
                            Text("Inbound htlc max: \(channel.inboundHtlcMaximumMsat ?? 0 / 1000) sats")
                            Text("Inbound htlc min: \(channel.inboundHtlcMinimumMsat / 1000) sats")
                            Text("Next outbound htlc limit: \(channel.nextOutboundHtlcLimitMsat / 1000) sats")
                            Text("Next outbound htlc min: \(channel.nextOutboundHtlcMinimumMsat / 1000) sats")
                        }
                        .opacity(closingChannels.contains(channel.channelId) ? 0.1 : 1.0)
                        .overlay {
                            if closingChannels.contains(channel.channelId) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .padding()
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                Task { @MainActor in
                                    closingChannels.append(channel.channelId)
                                    try await wallet.closeChannel(channel)
                                    closingChannels.removeAll { $0 == channel.channelId }
                                }
                            } label: {
                                Label(closingChannels.contains(channel.channelId) ? "Closing..." : "Close Channel", systemImage: "xmark")
                            }
                            .disabled(closingChannels.contains(channel.channelId))
                            .tint(.red)
                        }
                    }
                }
            }

            if let balanceDetails = wallet.balanceDetails {
                Section("Wallet Balances") {
                    HStack {
                        Text("Total onchain:")
                        Spacer()
                        Text("\(balanceDetails.totalOnchainBalanceSats)")
                    }

                    HStack {
                        Text("Spendable onchain:")
                        Spacer()
                        Text("\(balanceDetails.spendableOnchainBalanceSats)")
                    }

                    HStack {
                        Text("Total anchor channels reserve:")
                        Spacer()
                        Text("\(balanceDetails.totalAnchorChannelsReserveSats)")
                    }

                    HStack {
                        Text("Total lightning:")
                        Spacer()
                        Text("\(balanceDetails.totalLightningBalanceSats)")
                    }
                }

                Section("Lightning Balances") {
                    ForEach(balanceDetails.lightningBalances.map { IdentifiableLightningBalance($0) }) { identifiableBalance in
                        LightningBalanceRow(balance: identifiableBalance.balance)
                    }
                }
            }
        }
        .navigationBarTitle("Node State")
    }
}

struct LightningBalanceRow: View {
    let balance: LightningBalance

    var body: some View {
        VStack(alignment: .leading) {
            Text(balanceTypeString)
                .bold()
            Text(balance.channelIdString)
                .font(.caption)
            Text("\(amountString) sats")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var balanceTypeString: String {
        switch balance {
        case .claimableOnChannelClose: return "Claimable on Channel Close"
        case .claimableAwaitingConfirmations(_, _, _, let confirmationHeight): return "Claimable Awaiting Confirmations (Height: \(confirmationHeight))"
        case .contentiousClaimable: return "Contentious Claimable"
        case .maybeTimeoutClaimableHtlc: return "Maybe Timeout Claimable HTLC"
        case .maybePreimageClaimableHtlc: return "Maybe Preimage Claimable HTLC"
        case .counterpartyRevokedOutputClaimable: return "Counterparty Revoked Output Claimable"
        }
    }

    private var amountString: String {
        switch balance {
        case .claimableOnChannelClose(_, _, let amount),
             .claimableAwaitingConfirmations(_, _, let amount, _),
             .contentiousClaimable(_, _, let amount, _, _, _),
             .maybeTimeoutClaimableHtlc(_, _, let amount, _, _),
             .maybePreimageClaimableHtlc(_, _, let amount, _, _),
             .counterpartyRevokedOutputClaimable(_, _, let amount):
            return "\(amount)"
        }
    }
}

#Preview {
    NodeStateView()
}
