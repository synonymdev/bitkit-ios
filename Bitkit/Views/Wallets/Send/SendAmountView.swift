//
//  SendAmount.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/11.
//

import SwiftUI

struct SendAmountView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var amount: String = ""
    @FocusState private var isAmountFocused: Bool
    @State private var showSendConfirmationView = false

    var body: some View {
        VStack {
            Text("Bitcoin Amount")

            TextField("Amount in sats", text: $amount)
                .keyboardType(.numberPad)
                .font(.title)
                .padding()
                .focused($isAmountFocused)

            Spacer()

            VStack {
                // Show lighting/onchain option
                HStack {
                    VStack(alignment: .leading) {
                        Text("Available")
                            .foregroundColor(.gray)
                        if app.scannedLightningInvoice != nil {
                            Text("\(wallet.totalLightningSats) sats")
                        } else {
                            Text("\(wallet.totalOnchainSats) sats")
                        }
                    }
                    .font(.caption)

                    Spacer()

                    if app.scannedLightningInvoice != nil {
                        Text("Spending")
                    } else {
                        Text("Savings")
                    }
                }
                .padding(.bottom)

                Button("Continue") {
                    Task { @MainActor in
                        if let amount = UInt64(amount) {
                            app.sendAmountSats = amount
                            showSendConfirmationView = true
                        } else {
                            Logger.error("Invalid amount: \(amount)")
                        }
                    }
                }
            }
            .padding()
        }
        .background(
            NavigationLink(
                destination: SendConfirmationView(),
                isActive: $showSendConfirmationView
            ) { EmptyView() }
        )
        .onAppear {
            isAmountFocused = true
        }
    }
}

#Preview {
    SendAmountView()
        .environmentObject(AppViewModel())
        .environmentObject(WalletViewModel())
        .preferredColorScheme(.dark)
}
