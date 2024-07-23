//
//  ContentView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/27.
//

import SwiftUI

struct ContentView: View {
    @StateObject var lnViewModel = LightningViewModel()
    @StateObject var onChainViewModel = OnChainViewModel()
    
    @Environment(\.scenePhase) var scenePhase
    
    @State var showLogs = false
    
    var body: some View {
        List {
            Section {
                Text(lnViewModel.status?.debugState ?? "No LDK State")
                
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
                    Text("On Chain \(onchainBalance.total)")
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
                        //                        let cmd = "lncli openchannel --node_key=\(lnViewModel.nodeId ?? "") --local_amt=200000 --push_amt=10000 --min_confs=3"
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
            
            Section("Transactions") {
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
                    group.addTask { try await lnViewModel.sync() }
                    group.addTask { try await onChainViewModel.sync() }
                    try await group.waitForAll()
                }
            } catch {
                //TODO show an error
            }
        }
        .sheet(isPresented: $showLogs) {
            LogView()
        }
        .onAppear {            
            Logger.debug("App appeared, spinning up services...")
            Task {
                do {
                    try? await MigrationsService.shared.migrateAll()
                    
                    Logger.debug("SKIPPING OTHER SERVICES")
                    try await lnViewModel.start()
                    try await lnViewModel.sync()
                    
                    try await onChainViewModel.start()
                    try await onChainViewModel.sync()
                } catch {
                    Logger.error(error, context: "Failed to start wallet services")
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                if lnViewModel.status?.isRunning == true {
                    Logger.debug("App backgrounded, stopping LN service...")
                    Task {
                        do {
                            try await lnViewModel.stop()
                        } catch {
                            Logger.error(error, context: "Failed to stop LN")
                        }
                    }
                }
                return
            }
            
            if newPhase == .active {
                if lnViewModel.status?.isRunning == false {
                    Logger.debug("App active, starting LN service...")
                    Task {
                        do {
                            try await lnViewModel.start()
                            try await lnViewModel.sync()
                        } catch {
                            Logger.error(error, context: "Failed to start LN")
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
