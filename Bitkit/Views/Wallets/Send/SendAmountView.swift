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
    @EnvironmentObject var settings: SettingsViewModel
    @Binding var navigationPath: [SendRoute]
    @State private var satsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @FocusState private var isAmountFocused: Bool

    var availableAmount: UInt64 {
        app.selectedWalletToPayFrom == .lightning ? UInt64(wallet.totalLightningSats) : UInt64(wallet.totalOnchainSats)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: localizedString("wallet__send_amount"), showBackButton: true)

            VStack(alignment: .leading, spacing: 16) {
                // Use AmountInput component instead of TextField
                AmountInput(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats, showConversion: true) { newSats in
                    satsAmount = newSats
                    overrideSats = nil
                }
                .padding(.vertical, 16)

                Spacer()

                // Available balance section
                HStack(alignment: .bottom) {
                    AvailableAmount(
                        label: localizedString("wallet__send_available"),
                        amount: Int(availableAmount)
                    )
                    .onTapGesture {
                        overrideSats = availableAmount
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
                        text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                        imageName: "transfer",
                        color: .brandAccent
                    ) {
                        withAnimation {
                            currency.togglePrimaryDisplay()
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            Spacer()

            CustomButton(title: localizedString("common__continue"), isDisabled: satsAmount == 0) {
                do {
                    if satsAmount > 0 {
                        wallet.sendAmountSats = satsAmount

                        //Lightning tx
                        if app.selectedWalletToPayFrom == .lightning {
                            if UInt64(wallet.totalLightningSats) < satsAmount {
                                app.toast(
                                    type: .error, title: "Insufficient Funds", description: "You do not have enough funds in the selected wallet.")
                                return
                            }

                            navigationPath.append(.confirm)
                            return
                        }

                        //Onchain tx
                        try await wallet.setFeeRate(speed: settings.defaultTransactionSpeed)
                        if settings.coinSelectionMethod == .manual {
                            try await wallet.loadAvailableUtxos()

                            if wallet.availableUtxos.isEmpty {
                                app.toast(type: .error, title: "No UTXOs", description: "You do not have any UTXOs to spend.")
                                return
                            }

                            if wallet.availableUtxos.reduce(0) { $0 + $1.valueSats } < satsAmount {
                                app.toast(
                                    type: .error, title: "Insufficient Funds", description: "You do not have enough funds in the selected wallet.")
                                return
                            }

                            navigationPath.append(.utxoSelection) //User needs to select utxos
                        } else {
                            try await wallet.setUtxoSelection(coinSelectionAlgorythm: settings.coinSelectionAlgorithm)

                            let totalSelectedSats = wallet.selectedUtxo?.reduce(0) { $0 + $1.valueSats } ?? 0
                            if totalSelectedSats < satsAmount {
                                app.toast(
                                    type: .error, title: "Insufficient Funds", description: "You do not have enough funds in the selected wallet.")
                                return
                            }

                            navigationPath.append(.confirm)
                        }
                    } else {
                        Logger.error("Invalid amount: \(satsAmount)")
                    }
                } catch {
                    Logger.error(error, context: "Failed to set fee rate or send amount")
                    app.toast(type: .error, title: "Send Error", description: error.localizedDescription)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
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
                        .environmentObject(SettingsViewModel())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
