//
//  HomeView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var lnViewModel = LightningViewModel.shared
    @ObservedObject var onChainViewModel = OnChainViewModel.shared
    @StateObject var viewModel = ViewModel.shared
        
    @State var showLogs = false
    
    var body: some View {
        List {
            Section {
                Text(lnViewModel.state.debugState)
                    .font(.caption)
                
                if let nodeId = lnViewModel.nodeId {
                    Text("LN Node ID: \(nodeId)")
                        .font(.caption)
                        .onTapGesture {
                            UIPasteboard.general.string = nodeId
                        }
                }
            }
            
            Section("Balances") {
                if let lnBalance = lnViewModel.balance {
                    Text("Lightning \(lnBalance.totalLightningBalanceSats)")
                    Text("Lightning onchain \(lnBalance.totalOnchainBalanceSats)")
                }
                
                if let onchainBalance = onChainViewModel.balance {
                    Text("On Chain Pending \(onchainBalance.immature.toSat())")
                    Text("On Chain Total \(onchainBalance.total.toSat())")
                }
            }
            
            Section("Blocktank") {
                Button("Register for notifications") {
                    StartupHandler.requestPushNotificationPermision { granted, error in
                        //If granted AppDelegate will receive the token and handle registration
                        if let error {
                            Logger.error(error, context: "Failed to request push notification permission")
                        }
                    }
                }
                
                Button("Self test") {
                    Task {
                        sleep(2) //Chance to background the app
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
            
            if let peers = lnViewModel.peers {
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
            
            if let channels = lnViewModel.channels {
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
                                    try await lnViewModel.sync()
                                } catch {
                                    
                                }
                            }
                        }
                    }
                    
                    Button("Copy open channel command") {
                        let cmd = "lncli openchannel --node_key=\(lnViewModel.nodeId ?? "") --local_amt=200000 --push_amt=10000 --private=true --zero_conf --channel_type=anchors"
                        UIPasteboard.general.string = cmd
                    }
                }
            }
            
            if let receiveAddress = onChainViewModel.address {
                Text("Receive Address: \(receiveAddress)")
                    .onTapGesture {
                        UIPasteboard.general.string = receiveAddress
                    }
            }
            
            Button("New Receive Address") {
                Task {
                    try await onChainViewModel.newReceiveAddress()
                }
            }
            
            Button("Create bolt11") {
                Task {
                    let invoice = try await LightningService.shared.receive(amountSats: 123, description: "paymeplz")
                    Logger.info(invoice, context: "Created invoice")
                    UIPasteboard.general.string = invoice
                }
            }
            
            Button("Pay bolt11") {
                Task {
                    if let invoice = UIPasteboard.general.string {
                        let _ = try? await LightningService.shared.send(bolt11: invoice)
                    }
                }
            }
            
            Button("Show Logs") {
                showLogs = true
            }
            
            Button("NUKE") {
                Task {
                    guard Env.network == .regtest else {
                        Logger.error("Can only nuke on regtest")
                        return
                    }
                    do {
                        //Delete storage (for current wallet only)
                        try await onChainViewModel.wipeWallet()
                        try await lnViewModel.wipeWallet()
                        //Delete entire keychain
                        try Keychain.wipeEntireKeychain()
                        viewModel.setWalletExistsState()
                    } catch {
                        Logger.error(error, context: "Nuke")
                    }
                }
            }
            
            Section("LN Transactions") {
                if let payments = lnViewModel.payments {
                    ForEach(payments, id: \.id) { payment in
                        HStack {
                            Text("\(payment.direction == .inbound ? "⬇️" : "⬆️")")
                            Text("\(payment.status)")
                            Spacer()
                            Text("\(payment.amountMsat ?? 0)")
                        }
                    }
                }
            }
        }
        .refreshable {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await onChainViewModel.sync(full: true) }
                    group.addTask { try await lnViewModel.sync() }
                    try await group.waitForAll()
                }
            } catch {
                //TODO show an error
            }
        }
        .sheet(isPresented: $showLogs) {
            LogView()
        }
    }
}

#Preview {
    HomeView()
}
