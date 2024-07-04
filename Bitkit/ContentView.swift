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
        ScrollView {
            Group {
                Text(lnViewModel.status?.debugState ?? "No LDK State")
                
                if let nodeId = lnViewModel.nodeId {
                    Text("LN Node ID: \(nodeId)")
                        .onTapGesture {
                            UIPasteboard.general.string = nodeId
                        }
                }
                
                if let peers = lnViewModel.peers {
                    ForEach(peers, id: \.nodeId) { peer in
                        Text("Peer: \(peer.nodeId) \(peer.address) \(peer.isConnected ? "✅" : "❌")")
                    }
                }
                
                if let lnBalance = lnViewModel.balance {
                    Text("Lightning \(lnBalance.totalLightningBalanceSats)")
                    Text("Lightning onchain \(lnBalance.totalOnchainBalanceSats)")
                }
                              
                if let onchainBalance = onChainViewModel.balance {
                    Text("On Chain \(onchainBalance.total)")
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
            }
            .multilineTextAlignment(.center)
            .padding()
        }
        .padding(4)
        .onAppear {
            Task {
                do {
                    try await lnViewModel.start()
                } catch {
                    print("LN Error: \(error)")
                }
            }
            
            Task {
                do {
                    try await onChainViewModel.start()
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
