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
                        let paymentHash = try await LightningService.shared.send(bolt11: "lnbcrt1230n1pnfzdu8pp589sw6vgkercxszde7v4q70yu2ecd0dauhwss4sss52vgu4aemlgqdqqcqzzsxqyz5vqsp59d5228t6805syarr59qkl96kahtjehnahwphglha38qv3sagh25q9qxpqysgq5ssgsd5d8f6lx0f5rjjfnwzy9kmmcup34ppdf7ak5tpe75j3egw9g48esx4czadu84amz8wm2ghwzpu5tcz2szkklcseq86jjnw64pcqlrez5d")
                    } catch {
                        print("Send error: \(error)")
                    }
                }
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
    }
}

#Preview {
    ContentView()
}
