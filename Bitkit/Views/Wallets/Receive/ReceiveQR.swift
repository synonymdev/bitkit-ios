//
//  ReceiveQR.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct CopyAddressCard: View {
    let title: String
    let address: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.title2)
                .padding(.bottom)

            Text(address)
                .font(.caption)
                .padding(.bottom)

            HStack {
                Button("Copy") {
                    UIPasteboard.general.string = address
                    Haptics.play(.copiedToClipboard)
                }
                .padding(.horizontal)

                if #available(iOS 16.0, *) {
                    ShareLink(item: URL(string: address)!) {
                        Text("Share")
                    }
                    .padding(.horizontal)
                } else {
                    // TODO: Add share sheet for iOS 15
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.gray.opacity(0.25))
        .cornerRadius(10)
    }
}

struct ReceiveQR: View {
    @State var isCreatingInvoice = false

    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel

    @State private var cjitActive = false
    @State private var showCreateCjit = false
    @State private var cjitInvoice: String? = nil

    var body: some View {
        NavigationView {
            VStack {
                Text("Receive Bitcoin")
                    .padding()

                TabView {
                    receiveQR
                    copyValues
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))

                Spacer()

                receiveLightningFunds
            }
            .padding()
        }
        .task {
            do {
                // Refresh the bip21 string if required
                try await wallet.refreshBip21()
            } catch {
                app.toast(error)
            }
        }
    }

    @ViewBuilder
    var receiveQR: some View {
        let uri = cjitInvoice ?? wallet.bip21

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
                    } else {
                        // TODO: Add share sheet for iOS 15
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
            if !wallet.onchainAddress.isEmpty {
                CopyAddressCard(title: "On-chain Address", address: wallet.onchainAddress)
            }

            if !wallet.bolt11.isEmpty {
                CopyAddressCard(title: "Lightning Invoice", address: wallet.bolt11)
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

            NavigationLink(
                destination: CreateCjitView { invoice in
                    cjitInvoice = invoice
                    showCreateCjit = false
                },
                isActive: $showCreateCjit
            ) {
                EmptyView()
            }
        }
        .onChange(of: cjitActive) { cjitActive in
            if cjitActive {
                showCreateCjit = true
            }

            // TODO: disable toggle of no invoice created
        }
    }
}

#Preview {
    ReceiveQR()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
}
