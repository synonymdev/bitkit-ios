//
//  ReceiveView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

// Presentation component
struct ReceiveViewContent: View {
    let bip21: String
    let onchainAddress: String
    let bolt11: String
    let nodeLifecycleState: NodeLifecycleState
    let channelsCount: Int
    let cjitInvoice: String?
    let onCjitToggle: (Bool) -> Void
    let onCreateCjit: (String) -> Void
    
    @State private var selectedTab = 0
    @State private var cjitActive = false
    
    var body: some View {
        VStack {
            Text("Receive Bitcoin")
                .padding()
            
            TabView(selection: $selectedTab) {
                receiveQR
                    .tag(0)
                copyValues
                    .tag(1)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
            
            Spacer()
            
            if (nodeLifecycleState == .running || nodeLifecycleState == .starting) && channelsCount == 0 {
                receiveLightningFunds
            }
        }
        .padding()
        .onAppear {
            // Set cjitActive based on cjitInvoice when the view appears
            cjitActive = cjitInvoice != nil
        }
    }
    
    @ViewBuilder
    var receiveQR: some View {
        let uri = cjitInvoice ?? bip21
        
        VStack {
            if !uri.isEmpty {
                QR(content: uri)
                
                HStack {
                    Button("Edit") {}
                        .padding(.horizontal)
                    
                    Button("Copy") {
                        UIPasteboard.general.string = uri
                        Haptics.play(.copiedToClipboard)
                    }
                    .padding(.horizontal)
                    
                    if #available(iOS 16.0, *) {
                        ShareLink(item: URL(string: uri)!) {
                            Text("Share")
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            } else {
                ProgressView()
            }
        }
    }
    
    @ViewBuilder
    var copyValues: some View {
        VStack {
            if !onchainAddress.isEmpty {
                CopyAddressCard(title: "On-chain Address", address: onchainAddress)
            }
            
            if !bolt11.isEmpty {
                CopyAddressCard(title: "Lightning Invoice", address: bolt11)
            } else if let cjitInvoice {
                CopyAddressCard(title: "Lightning Invoice", address: cjitInvoice)
            }
            
            Spacer()
        }
    }
    
    @ViewBuilder
    var receiveLightningFunds: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading) {
                if cjitInvoice == nil {
                    Text("Want to receive lightning funds?")
                        .font(.title2)
                        .multilineTextAlignment(.leading)
                }
                
                Text("Receive on Spending Balance")
                    .multilineTextAlignment(.leading)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: $cjitActive) {
                EmptyView()
            }
            .frame(maxWidth: 50)
        }
        .onChange(of: cjitActive) { newValue in
            onCjitToggle(newValue)
        }
        .onChange(of: cjitInvoice) { newInvoice in
            // When cjitInvoice changes, update toggle state but don't navigate
            if newInvoice != nil {
                cjitActive = true
            }
        }
    }
}

// Container view that manages state
struct ReceiveView: View {
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    
    @State private var cjitInvoice: String? = nil
    @State private var showCreateCjit = false
    
    var body: some View {
        NavigationView {
            ReceiveViewContent(
                bip21: wallet.bip21,
                onchainAddress: wallet.onchainAddress,
                bolt11: wallet.bolt11,
                nodeLifecycleState: wallet.nodeLifecycleState,
                channelsCount: wallet.channels?.count ?? 0,
                cjitInvoice: cjitInvoice,
                onCjitToggle: { active in
                    if !active {
                        cjitInvoice = nil
                    } else if cjitInvoice == nil {
                        showCreateCjit = true
                    }
                },
                onCreateCjit: { invoice in
                    cjitInvoice = invoice
                }
            )
            .background(
                NavigationLink(
                    destination: CreateCjitView { invoice in
                        cjitInvoice = invoice
                        showCreateCjit = false
                    },
                    isActive: $showCreateCjit
                ) {
                    EmptyView()
                }
            )
        }
        .task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await wallet.refreshBip21() }
                    group.addTask { try await blocktank.refreshInfo() }
                    try await group.waitForAll()
                }
            } catch {
                app.toast(error)
            }
        }
    }
}

// Previews
#Preview("Onchain Only") {
    NavigationView {
        ReceiveViewContent(
            bip21: "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
            onchainAddress: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
            bolt11: "",
            nodeLifecycleState: .running,
            channelsCount: 0,
            cjitInvoice: nil,
            onCjitToggle: { _ in },
            onCreateCjit: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("With Lightning") {
    NavigationView {
        ReceiveViewContent(
            bip21: "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?lightning=lnbc1500n1p3hk3sppp5k54t9c4p4u4tdgj0y8tqjp3kzjak8jtr0fwvnl2dpl5pvrm9gxsdqqcqzpgxqyz5vqsp5usxefww9jeqxv4ujmfwqhynz3rgf4x4k8kmjkjy8mkzctxt5vvq9qyyssqy4lgd8nj3vxjmnqyfgxnz3gqhykj8rd9v4xnz970m2cfqsz3vh7qwg0o4jj2mcwhzguktgc8hm8zmnwnp6f5ke4h8dkwrm8fqz2cpgqqqqqqqqlgqqqq",
            onchainAddress: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
            bolt11: "lnbc1500n1p3hk3sppp5k54t9c4p4u4tdgj0y8tqjp3kzjak8jtr0fwvnl2dpl5pvrm9gxsdqqcqzpgxqyz5vqsp5usxefww9jeqxv4ujmfwqhynz3rgf4x4k8kmjkjy8mkzctxt5vvq9qyyssqy4lgd8nj3vxjmnqyfgxnz3gqhykj8rd9v4xnz970m2cfqsz3vh7qwg0o4jj2mcwhzguktgc8hm8zmnwnp6f5ke4h8dkwrm8fqz2cpgqqqqqqqqlgqqqq",
            nodeLifecycleState: .running,
            channelsCount: 1,
            cjitInvoice: nil,
            onCjitToggle: { _ in },
            onCreateCjit: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("With CJIT") {
    NavigationView {
        ReceiveViewContent(
            bip21: "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
            onchainAddress: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
            bolt11: "",
            nodeLifecycleState: .running,
            channelsCount: 0,
            cjitInvoice: "lnbc1500n1p3hk3sppp5k54t9c4p4u4tdgj0y8tqjp3kzjak8jtr0fwvnl2dpl5pvrm9gxsdqqcqzpgxqyz5vqsp5usxefww9jeqxv4ujmfwqhynz3rgf4x4k8kmjkjy8mkzctxt5vvq9qyyssqy4lgd8nj3vxjmnqyfgxnz3gqhykj8rd9v4xnz970m2cfqsz3vh7qwg0o4jj2mcwhzguktgc8hm8zmnwnp6f5ke4h8dkwrm8fqz2cpgqqqqqqqqlgqqqq",
            onCjitToggle: { _ in },
            onCreateCjit: { _ in }
        )
    }
    .preferredColorScheme(.dark)
    .environmentObject(WalletViewModel())
    .environmentObject(AppViewModel())
    .environmentObject(BlocktankViewModel())
}
