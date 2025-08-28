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

    var canSwitchWallet: Bool {
        app.scannedOnchainInvoice != nil && app.scannedLightningInvoice != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__send_amount"), showBackButton: true)

            VStack(alignment: .leading, spacing: 16) {
                AmountInput(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats, showConversion: true) { newSats in
                    satsAmount = newSats
                    overrideSats = nil
                }
                .padding(.vertical, 16)

                Spacer()

                // Available balance section
                HStack(alignment: .bottom) {
                    AvailableAmount(
                        label: t("wallet__send_available"),
                        amount: Int(availableAmount)
                    )
                    .onTapGesture {
                        overrideSats = availableAmount
                    }

                    Spacer()

                    // No specific invoice, show toggle button based on selected wallet type
                    NumberPadActionButton(
                        text: app.selectedWalletToPayFrom == .lightning
                            ? t("wallet__spending__title")
                            : t("wallet__savings__title"),
                        imageName: canSwitchWallet ? "arrow-up-down" : nil,
                        color: app.selectedWalletToPayFrom == .lightning ? .purpleAccent : .brandAccent,
                        variant: canSwitchWallet ? .primary : .secondary,
                        disabled: !canSwitchWallet
                    ) {
                        if canSwitchWallet {
                            app.selectedWalletToPayFrom.toggle()
                        }
                    }

                    NumberPadActionButton(
                        text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                        imageName: "arrow-up-down",
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

            CustomButton(title: t("common__continue"), isDisabled: satsAmount == 0) {
                do {
                    wallet.sendAmountSats = satsAmount

                    // Lightning tx
                    if app.selectedWalletToPayFrom == .lightning {
                        if UInt64(wallet.totalLightningSats) < satsAmount {
                            app.toast(
                                type: .error,
                                title: "Insufficient Funds",
                                description: "You do not have enough funds in the selected wallet."
                            )
                            return
                        }

                        navigationPath.append(.confirm)
                        return
                    }

                    // Onchain tx
                    if settings.coinSelectionMethod == .manual {
                        try await wallet.loadAvailableUtxos()

                        if wallet.availableUtxos.isEmpty {
                            app.toast(
                                type: .error,
                                title: "No UTXOs",
                                description: "You do not have any UTXOs to spend."
                            )
                            return
                        }

                        if wallet.availableUtxos.reduce(0) { $0 + $1.valueSats } < satsAmount {
                            app.toast(
                                type: .error,
                                title: "Insufficient Funds",
                                description: "You do not have enough funds in the selected wallet."
                            )
                            return
                        }

                        navigationPath.append(.utxoSelection) // User needs to select utxos
                    } else {
                        try await wallet.setUtxoSelection(coinSelectionAlgorythm: settings.coinSelectionAlgorithm)

                        let totalSelectedSats = wallet.selectedUtxos?.reduce(0) { $0 + $1.valueSats } ?? 0
                        if totalSelectedSats < satsAmount {
                            app.toast(
                                type: .error,
                                title: "Insufficient Funds",
                                description: "You do not have enough funds in the selected wallet."
                            )
                            return
                        }

                        navigationPath.append(.confirm)
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
        .onAppear {
            if let invoice = app.scannedOnchainInvoice {
                // Set the amount to the scanned onchain invoice amount if it exists
                satsAmount = invoice.amountSatoshis
                overrideSats = invoice.amountSatoshis
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
