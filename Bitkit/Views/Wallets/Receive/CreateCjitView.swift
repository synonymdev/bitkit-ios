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

            HStack {
                Text("Minimum")
                    .font(.caption)
                    .foregroundColor(.gray)

                // TODO: get from API

                Spacer()

                // TODO: switch to USD
            }

            Divider()
            Button("Continue") {
                Task { @MainActor in
                    if let amountInt = UInt64(amount), let nodeId = wallet.nodeId {
                        isCreatingInvoice = true
                        do {
                            // TODO: move to Blocktank view model when ready

                            let entry = try await BlocktankService.shared.createCJitEntry(
                                channelSizeSat: amountInt * 2, // TODO: check this amount default from RN app
                                invoiceSat: amountInt,
                                invoiceDescription: "Pay me please",
                                nodeId: nodeId,
                                channelExpiryWeeks: 2, // TODO: check this amount default from RN app
                                options: .init()
                            )

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
}
