//
//  CreateCjitView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/17.
//

import SwiftUI

struct CreateCjitView: View {
    let onCjitCreated: (String) -> Void

    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel

    @State private var amount: String = ""
    @FocusState private var isAmountFocused: Bool
    @State private var isCreatingInvoice = false

    var body: some View {
        VStack {
            TextField("Amount in sats", text: $amount)
                .keyboardType(.numberPad)
                .font(.title)
                .padding()
                .focused($isAmountFocused)

            Spacer()

            if let info = blocktank.info {
                HStack {
                    // TODO: CJIT LIMITS

                    // minChannelSizeSat
                    // maxChannelSizeSat
                    /// const maxAmount = maxChannelSizeSat / 2;

                    VStack {
                        Text("Minimum")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("\(info.options.minChannelSizeSat / 2)")
                    }
                    .padding(.trailing)

                    VStack {
                        Text("Maximum")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("\(info.options.maxChannelSizeSat / 2)")
                    }

                    // TODO: get from API
                    // FROM BT model

                    Spacer()

                    // TODO: switch to USD
                }
            }

            Divider()
            Button("Continue") {
                Task { @MainActor in
                    if let amount = UInt64(amount), let nodeId = wallet.nodeId {
                        isCreatingInvoice = true
                        do {
                            let entry = try await blocktank.createCjit(amountSats: amount, description: "Bitkit")
                            onCjitCreated(entry.invoice.request)
                        } catch {
                            app.toast(error)
                            Logger.error(error)
                        }
                        isCreatingInvoice = false
                    }
                }
            }
            .disabled(isCreatingInvoice)
            .padding()
        }
        .padding()
        .navigationTitle("Receive Bitcoin")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isAmountFocused = true
        }
    }
}

#Preview {
    CreateCjitView { _ in }
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(BlocktankViewModel())
}
