//
//  SendAmount.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/11.
//

import SwiftUI

struct SendAmountView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Binding var navigationPath: [SendView]
    @State private var amount: String = ""
    @State private var satsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin
    @FocusState private var isAmountFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: localizedString("wallet__send_amount"), showBackButton: true)

            VStack(alignment: .leading, spacing: 16) {
                // Use AmountInput component instead of TextField
                AmountInput(primaryDisplay: $primaryDisplay, overrideSats: $overrideSats, showConversion: true) { newSats in
                    satsAmount = newSats
                    overrideSats = nil
                    amount = String(newSats)
                }
                .padding(.vertical, 16)

                Spacer()

                // Available balance section
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading) {
                        BodySText(NSLocalizedString("wallet__send_available", comment: "").uppercased(), textColor: .textSecondary)

                        if let converted = currency.convert(
                            sats: UInt64(app.selectedWalletToPayFrom == .lightning ? wallet.totalLightningSats : wallet.totalOnchainSats))
                        {
                            if primaryDisplay == .bitcoin {
                                let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                                BodySText("\(btcComponents.symbol) \(btcComponents.value)")
                            } else {
                                BodySText("\(converted.symbol) \(converted.formatted)")
                            }
                        }
                    }

                    Spacer()

                    // No specific invoice, show toggle button based on selected wallet type
                    NumberPadActionButton(
                        text: app.selectedWalletToPayFrom == .lightning
                            ? NSLocalizedString("wallet__spending__title", comment: "").uppercased()
                            : NSLocalizedString("wallet__savings__title", comment: "").uppercased(),
                        color: app.selectedWalletToPayFrom == .lightning ? .purpleAccent : .brandAccent,
                        variant: .secondary
                    ) {
                        //Allow switching to savings if we have an onchain invoice
                        if app.selectedWalletToPayFrom == .lightning && app.scannedOnchainInvoice != nil {
                            app.selectedWalletToPayFrom = .onchain
                        } else if app.selectedWalletToPayFrom == .onchain && app.scannedLightningInvoice != nil {
                            app.selectedWalletToPayFrom = .lightning
                        }
                    }

                    NumberPadActionButton(
                        text: primaryDisplay == .bitcoin ? currency.selectedCurrency : "BTC",
                        imageName: "transfer-brand",
                        color: Color.brandAccent
                    ) {
                        withAnimation {
                            primaryDisplay = primaryDisplay == .bitcoin ? .fiat : .bitcoin
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            Spacer()

            CustomButton(title: NSLocalizedString("common__continue", comment: "")) {
                Task { @MainActor in
                    if satsAmount > 0 {
                        app.sendAmountSats = satsAmount
                        // Validate that we have enough funds in the selected wallet
                        let availableSats = app.selectedWalletToPayFrom == .lightning ? wallet.totalLightningSats : wallet.totalOnchainSats

                        if UInt64(availableSats) < satsAmount {
                            app.toast(type: .error, title: "Insufficient Funds", description: "You do not have enough funds in the selected wallet.")
                            return
                        }

                        navigationPath.append(.confirm)
                    } else {
                        Logger.error("Invalid amount: \(amount)")
                    }
                }
            }
            .disabled(satsAmount == 0)
            .padding(.vertical, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Set default primaryDisplay value
            primaryDisplay = currency.primaryDisplay
        }
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationStack {
                    SendAmountView(navigationPath: .constant([]))
                        .environmentObject(AppViewModel())
                        .environmentObject(WalletViewModel())
                        .environmentObject(CurrencyViewModel())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
