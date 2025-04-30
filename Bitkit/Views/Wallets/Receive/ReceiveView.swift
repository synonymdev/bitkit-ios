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
    @State private var showEditInvoice = false

    var body: some View {
        VStack {
            TabView(selection: $selectedTab) {
                receiveQR
                    .padding(.horizontal)
                    .tag(0)
                copyValues
                    .padding(.horizontal)
                    .tag(1)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))

            Spacer()

            if (nodeLifecycleState == .running || nodeLifecycleState == .starting) && channelsCount == 0 {
                //CJIT option
                receiveLightningFunds
                    .padding()
            }
        }
        .sheetBackground()
        .onAppear {
            // Set cjitActive based on cjitInvoice when the view appears
            cjitActive = cjitInvoice != nil
        }
        .navigationTitle(NSLocalizedString("wallet__receive_bitcoin", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    var receiveQR: some View {
        let uri = cjitInvoice ?? bip21

        // Determine the appropriate image asset based on available content
        let imageAsset: String? = {
            if let cjitInvoice = cjitInvoice, !cjitInvoice.isEmpty {
                return "ln"
            } else if !bolt11.isEmpty && !onchainAddress.isEmpty {
                return "btc-and-ln"
            } else if !onchainAddress.isEmpty {
                return "btc"
            }
            return nil
        }()

        VStack {
            if !uri.isEmpty {
                QR(content: uri, imageAsset: imageAsset)

                HStack {
                    NavigationLink(destination: EditInvoiceView()) {
                        CustomButton(
                            title: NSLocalizedString("common__edit", comment: ""),
                            size: .small,
                            icon: Image("pencil-brand")
                        )
                    }

                    CustomButton(
                        title: NSLocalizedString("common__copy", comment: ""),
                        size: .small,
                        icon: Image("copy-brand")
                    ) {
                        UIPasteboard.general.string = uri
                        Haptics.play(.copiedToClipboard)
                    }

                    ShareLink(item: URL(string: uri)!) {
                        CustomButton(
                            title: NSLocalizedString("common__share", comment: ""),
                            size: .small,
                            icon: Image("share-brand")
                        )
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
            let addressPairs: [CopyAddressPair] = {
                var pairs: [CopyAddressPair] = []

                if !onchainAddress.isEmpty {
                    pairs.append(
                        CopyAddressPair(
                            title: NSLocalizedString("wallet__receive_bitcoin_invoice", comment: ""),
                            address: onchainAddress,
                            type: .onchain
                        ))
                }

                if !bolt11.isEmpty {
                    pairs.append(
                        CopyAddressPair(
                            title: NSLocalizedString("wallet__receive_lightning_invoice", comment: ""),
                            address: bolt11,
                            type: .lightning
                        ))
                } else if let cjitInvoice = cjitInvoice {
                    pairs.append(
                        CopyAddressPair(
                            title: NSLocalizedString("wallet__receive_lightning_invoice", comment: ""),
                            address: cjitInvoice,
                            type: .lightning
                        ))
                }

                return pairs
            }()

            if !addressPairs.isEmpty {
                CopyAddressCard(addresses: addressPairs)
            }

            Spacer()
        }
    }

    @ViewBuilder
    var receiveLightningFunds: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading) {
                if cjitInvoice == nil {
                    HeadlineText(NSLocalizedString("wallet__receive_text_lnfunds", comment: ""), accentColor: .purpleAccent)
                }

                BodyMText(NSLocalizedString("wallet__receive_spending", comment: ""))
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: $cjitActive) {
                EmptyView()
            }
            .tint(Color.purpleAccent)
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
                channelsCount: wallet.channelCount,
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
        .onDisappear {
            if wallet.invoiceAmountSats > 0 && !wallet.invoiceNote.isEmpty {
                wallet.invoiceAmountSats = 0
                wallet.invoiceNote = ""
                Task {
                    try? await wallet.refreshBip21(forceRefreshBolt11: true)
                }
                Logger.info("ReceiveView closed, reset invoice amount and note")
            }
        }
        .task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { await refreshBip21() }
                    group.addTask { try await blocktank.refreshInfo() }
                    try await group.waitForAll()
                }
            } catch {
                app.toast(error)
            }
        }
        .onChange(of: wallet.nodeLifecycleState) { newState in
            //They may open this view before node has started
            if newState == .running {
                Task {
                    await refreshBip21()
                }
            }
        }
    }

    func refreshBip21() async {
        guard wallet.nodeLifecycleState == .running else { return }
        do {
            try await wallet.refreshBip21()
        } catch {
            app.toast(error)
        }
    }
}

// Previews
#Preview("Onchain Only") {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
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
                    .navigationTitle(NSLocalizedString("wallet__receive_bitcoin", comment: ""))
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}

#Preview("With Lightning") {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationView {
                    ReceiveViewContent(
                        bip21:
                            "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?lightning=lnbc1500n1p3hk3sppp5k54t9c4p4u4tdgj0y8tqjp3kzjak8jtr0fwvnl2dpl5pvrm9gxsdqqcqzpgxqyz5vqsp5usxefww9jeqxv4ujmfwqhynz3rgf4x4k8kmjkjy8mkzctxt5vvq9qyyssqy4lgd8nj3vxjmnqyfgxnz3gqhykj8rd9v4xnz970m2cfqsz3vh7qwg0o4jj2mcwhzguktgc8hm8zmnwnp6f5ke4h8dkwrm8fqz2cpgqqqqqqqqlgqqqq",
                        onchainAddress: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
                        bolt11:
                            "lnbc1500n1p3hk3sppp5k54t9c4p4u4tdgj0y8tqjp3kzjak8jtr0fwvnl2dpl5pvrm9gxsdqqcqzpgxqyz5vqsp5usxefww9jeqxv4ujmfwqhynz3rgf4x4k8kmjkjy8mkzctxt5vvq9qyyssqy4lgd8nj3vxjmnqyfgxnz3gqhykj8rd9v4xnz970m2cfqsz3vh7qwg0o4jj2mcwhzguktgc8hm8zmnwnp6f5ke4h8dkwrm8fqz2cpgqqqqqqqqlgqqqq",
                        nodeLifecycleState: .running,
                        channelsCount: 1,
                        cjitInvoice: nil,
                        onCjitToggle: { _ in },
                        onCreateCjit: { _ in }
                    )
                    .navigationTitle(NSLocalizedString("wallet__receive_bitcoin", comment: ""))
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}

#Preview("With CJIT") {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationView {
                    ReceiveViewContent(
                        bip21: "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
                        onchainAddress: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
                        bolt11: "",
                        nodeLifecycleState: .running,
                        channelsCount: 0,
                        cjitInvoice:
                            "lnbc1500n1p3hk3sppp5k54t9c4p4u4tdgj0y8tqjp3kzjak8jtr0fwvnl2dpl5pvrm9gxsdqqcqzpgxqyz5vqsp5usxefww9jeqxv4ujmfwqhynz3rgf4x4k8kmjkjy8mkzctxt5vvq9qyyssqy4lgd8nj3vxjmnqyfgxnz3gqhykj8rd9v4xnz970m2cfqsz3vh7qwg0o4jj2mcwhzguktgc8hm8zmnwnp6f5ke4h8dkwrm8fqz2cpgqqqqqqqqlgqqqq",
                        onCjitToggle: { _ in },
                        onCreateCjit: { _ in }
                    )
                    .navigationTitle(NSLocalizedString("wallet__receive_bitcoin", comment: ""))
                    .navigationBarTitleDisplayMode(.inline)
                }
                .environmentObject(WalletViewModel())
                .environmentObject(AppViewModel())
                .environmentObject(BlocktankViewModel())
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
