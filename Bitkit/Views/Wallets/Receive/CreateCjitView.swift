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
    @EnvironmentObject private var currency: CurrencyViewModel

    @State private var satsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin
    @State private var isCreatingInvoice = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                AmountInput(primaryDisplay: $primaryDisplay, overrideSats: $overrideSats) { newSats in
                    Haptics.play(.buttonTap)
                    satsAmount = newSats
                    overrideSats = nil
                }
                .padding(.vertical, 16)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading) {
                        BodySText("Minimum", textColor: .textSecondary)
                        if let minSats = blocktank.minCjitSats {
                            BodySText("\(minSats)") //TODO: handle conversion to fiat if needed
                        }  else {
                            ProgressView()
                        }
                    }

                    Spacer()

                    amountButtons
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)

            Divider()

            Spacer()

            CustomButton(title: "Continue") {
                guard satsAmount > 0 else { return }
                
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
                        let entry = try await blocktank.createCjit(amountSats: satsAmount, description: "Bitkit")
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
            .disabled(isCreatingInvoice || satsAmount == 0)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .navigationTitle("Receive Bitcoin")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            primaryDisplay = currency.primaryDisplay
            try? await blocktank.refreshMinCjitSats()
        }
    }
    
    private var amountButtons: some View {
        HStack(spacing: 16) {
            NumberPadActionButton(
                text: primaryDisplay == .bitcoin ? currency.selectedCurrency : "BTC",
                imageName: "transfer-purple"
            ) {
                withAnimation {
                    primaryDisplay = primaryDisplay == .bitcoin ? .fiat : .bitcoin
                }
            }
            
            if let minSats = blocktank.minCjitSats {
                NumberPadActionButton(text: "Min") {
                    overrideSats = UInt64(minSats)
                }
            }
        }
    }
}

@available(iOS 16.0, *)
#Preview {
    VStack { }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationView {
                    CreateCjitView { _ in }
                        .environmentObject(WalletViewModel())
                        .environmentObject(AppViewModel())
                        .environmentObject(BlocktankViewModel())
                        .environmentObject(CurrencyViewModel())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
    .preferredColorScheme(.dark)
}
