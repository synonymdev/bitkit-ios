//
//  CreateCjitView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/17.
//

import SwiftUI
import BitkitCore

struct CreateCjitView: View {
    let onCjitCreated: (String) -> Void

    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var currency: CurrencyViewModel

    @State private var amountSats: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin
    @State private var createdEntry: IcJitEntry?
    @State private var navigateToConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                AmountInput(primaryDisplay: $primaryDisplay, overrideSats: $overrideSats, showConversion: true) { newSats in
                    Haptics.play(.buttonTap)
                    amountSats = newSats
                    overrideSats = nil
                }
                .padding(.vertical, 16)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading) {
                        BodySText(NSLocalizedString("fee__minimum__title", comment: ""), textColor: .textSecondary)
                        if let minSats = blocktank.minCjitSats {
                            if let converted = currency.convert(sats: minSats) {
                                if primaryDisplay == .bitcoin {
                                    let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                                    BodySText("\(btcComponents.symbol) \(btcComponents.value)")
                                } else {
                                    BodySText("\(converted.symbol) \(converted.formatted)")
                                }
                            }
                        } else {
                            ProgressView()
                        }
                    }
                    .onTapGesture {
                        if let minSats = blocktank.minCjitSats {
                            overrideSats = minSats
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

            CustomButton(title: NSLocalizedString("common__continue", comment: "")) {
                guard amountSats > 0 else { return }

                // Wait until node is running if it's in starting state
                if await wallet.waitForNodeToRun() {
                    // Only proceed if node is running
                    do {
                        let entry = try await blocktank.createCjit(amountSats: amountSats, description: "Bitkit")
                        createdEntry = entry
                        navigateToConfirmation = true
                    } catch {
                        app.toast(error)
                        Logger.error(error)
                    }
                } else {
                    // Show error if node is not running or timed out
                    app.toast(type: .warning, title: "Lightning not ready", description: "Lightning node must be running to create an invoice")
                }
            }
            .disabled(amountSats == 0)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .sheetBackground()
        .navigationTitle(NSLocalizedString("wallet__receive_bitcoin", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            primaryDisplay = currency.primaryDisplay
            try? await blocktank.refreshMinCjitSats()
        }
        .background(
            NavigationLink(
                destination: Group {
                    if let entry = createdEntry {
                        CjitConfirmationView(entry: entry, onCjitCreated: onCjitCreated, receiveAmountSats: amountSats)
                    }
                },
                isActive: $navigateToConfirmation
            ) {
                EmptyView()
            }
        )
    }

    private var amountButtons: some View {
        HStack(spacing: 16) {
            NumberPadActionButton(
                text: primaryDisplay == .bitcoin ? currency.selectedCurrency : "BTC",
                imageName: "transfer-brand",
                color: Color.brandAccent
            ) {
                withAnimation {
                    primaryDisplay = primaryDisplay == .bitcoin ? .fiat : .bitcoin
                }
            }

            if let minSats = blocktank.minCjitSats {
                NumberPadActionButton(text: "Min", color: Color.brandAccent) {
                    overrideSats = UInt64(minSats)
                }
            }
        }
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationStack {
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
