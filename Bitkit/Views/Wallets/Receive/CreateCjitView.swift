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
                    // Min amount view
                    VStack {
                        Text("Minimum")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("\(info.options.minChannelSizeSat / 2)")
                    }
                    .padding(.trailing)
                    .contentShape(Rectangle())  // Makes entire area tappable
                    .onTapGesture {
                        amount = String(info.options.minChannelSizeSat / 2)
                    }

                    // Max amount view
                    VStack {
                        Text("Maximum")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("\(info.options.maxChannelSizeSat / 2)")
                    }
                    .contentShape(Rectangle())  // Makes entire area tappable
                    .onTapGesture {
                        amount = String(info.options.maxChannelSizeSat / 2)
                    }

                    // TODO: get from API
                    // FROM BT model

                    Spacer()

                    // TODO: switch to USD
                }
            } else {
                ProgressView()
            }

            Divider()
            CustomButton(title: "Continue") {
                guard let amount = UInt64(amount) else { return }
                
                // Wait until node is running if it's in starting state
                if wallet.nodeLifecycleState == .starting {
                    // Wait for the node to be fully running
                    while wallet.nodeLifecycleState == .starting {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
                        // Break if task cancelled or app state changes
                        if Task.isCancelled {
                            break
                        }
                    }
                }
                
                // Only proceed if node is running
                if wallet.nodeLifecycleState == .running {
                    do {
                        let entry = try await blocktank.createCjit(amountSats: amount, description: "Bitkit")
                        onCjitCreated(entry.invoice.request)
                    } catch {
                        app.toast(error)
                        Logger.error(error)
                    }
                } else {
                    // Show error if node is not running
                    app.toast(type: .warning, title: "Lightning not ready", description: "Lightning node must be running to create an invoice")
                }
            }
            .disabled(isCreatingInvoice)
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
        .preferredColorScheme(.dark)
}
