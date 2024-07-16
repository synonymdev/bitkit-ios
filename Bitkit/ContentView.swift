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
                                    print("Channel closed")
                                    try await lnViewModel.sync()
                                } catch {
                                    print("Close channel error: \(error)")
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
                try! onChainViewModel.newReceiveAddress()
            }
            
            VStack {
                Button("Sync") {
                    Task {
                        try await lnViewModel.sync()
                        try await onChainViewModel.sync()
                    }
                }
                
                if lnViewModel.isSyncing {
                    ProgressView("Syncing Lightning")
                }
                
                if onChainViewModel.isSyncing {
                    ProgressView("Syncing On Chain")
                }
            }
            
            Button("Create bolt11") {
                Task {
                    let invoice = try await LightningService.shared.receive(amountSats: 123, description: "paymeplz")
                    print(invoice)
                    UIPasteboard.general.string = invoice
                }
            }
            
            Button("Pay bolt11") {
                Task {
                    //                        let invoice = UIPasteboard.general.string
                    do {
                        let paymentHash = try await LightningService.shared.send(bolt11: "lnbcrt2u1pnf2qckpp5gzqu4fnv0l8c5x3x0yemq2wcme0ggh497mu88rqfttps7ts68e2sdqqcqzzsxqyz5vqsp5tke63vmcdm7s4f0ue9u2rf58t4j720nu7j2m7x4g4h4ty9ml3r6q9qxpqysgqdy0xjeqt5wrezqf608lxv52z8wqxthffhr28h4eena90ytl6yg9472awe43ldzwkukuh87ftekx82y2r67dqvuaz7q57ujuu4xawy6gpp4hyta")
                    } catch {
                        print("Send error: \(error)")
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
        .sheet(isPresented: $showLogs) {
            LogView()
        }
        .onAppear {
            print("APPEARED!")
            Task {
                do {
                    print("Starting LN...")
                    try await lnViewModel.start()
                    try await lnViewModel.sync()
                } catch {
                    print("LN Error: \(error)")
                }
            }
            
            Task {
                do {
                    print("Starting OnChain...")
                    try await onChainViewModel.start()
                    try await onChainViewModel.sync()
                } catch {
                    print("OnChain Error: \(error)")
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                print("Backgrounding")
                if lnViewModel.status?.isRunning == true {
                    Task {
                        do {
                            try await lnViewModel.stop()
                        } catch {
                            print("LN Error: \(error)")
                        }
                    }
                }
                return
            }
            
            if newPhase == .active {
                print("Active")
                if lnViewModel.status?.isRunning == false {
                    Task {
                        do {
                            try await lnViewModel.start()
                            try await lnViewModel.sync()
                        } catch {
                            print("LN Error: \(error)")
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
