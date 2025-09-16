import SwiftUI

struct SendAmountView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @Binding var navigationPath: [SendRoute]

    @StateObject private var amountViewModel = AmountInputViewModel()
    @State private var maxSendableAmount: UInt64?

    var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    var canSwitchWallet: Bool {
        app.scannedOnchainInvoice != nil && app.scannedLightningInvoice != nil
    }

    /// The amount to display in the available balance section
    /// For onchain transactions, this shows the max sendable amount (balance minus fees)
    /// For lightning transactions, this shows the total balance
    var availableAmount: UInt64 {
        if app.selectedWalletToPayFrom == .lightning {
            return UInt64(wallet.totalLightningSats)
        } else {
            // For onchain, show max sendable amount if calculated, otherwise fall back to total balance
            return maxSendableAmount ?? UInt64(wallet.spendableOnchainBalanceSats)
        }
    }

    /// Determines if the current amount is a max amount send
    var isMaxAmountSend: Bool {
        guard app.selectedWalletToPayFrom == .onchain else { return false }
        return amountSats == availableAmount && amountSats > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__send_amount"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                NumberPadTextField(viewModel: amountViewModel)
                    .onTapGesture {
                        amountViewModel.togglePrimaryDisplay(currency: currency)
                    }

                Spacer()

                // Available balance section
                HStack(alignment: .bottom) {
                    AvailableAmount(
                        label: t("wallet__send_available"),
                        amount: Int(availableAmount)
                    )
                    .onTapGesture {
                        amountViewModel.updateFromSats(availableAmount, currency: currency)
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
                            amountViewModel.togglePrimaryDisplay(currency: currency)
                        }
                    }
                }
                .padding(.bottom, 12)

                Divider()

                NumberPad(
                    type: amountViewModel.getNumberPadType(currency: currency),
                    errorKey: amountViewModel.errorKey
                ) { key in
                    amountViewModel.handleNumberPadInput(key, currency: currency)
                }

                CustomButton(title: t("common__continue"), isDisabled: amountSats == 0) {
                    Task {
                        await onContinue()
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .onAppear {
            if let invoice = app.scannedOnchainInvoice {
                // Set the amount to the scanned onchain invoice amount if it exists
                amountViewModel.updateFromSats(invoice.amountSatoshis, currency: currency)
            }

            // Calculate max sendable amount for onchain transactions
            if app.selectedWalletToPayFrom == .onchain {
                Task {
                    await calculateMaxSendableAmount()
                }
            }
        }
        .onChange(of: app.selectedWalletToPayFrom) { newValue in
            // Recalculate max sendable amount when switching wallet types
            if newValue == .onchain {
                Task {
                    await calculateMaxSendableAmount()
                }
            } else {
                maxSendableAmount = nil
            }
        }
    }

    private func onContinue() async {
        do {
            wallet.sendAmountSats = amountSats
            wallet.isMaxAmountSend = isMaxAmountSend

            // Lightning tx
            if app.selectedWalletToPayFrom == .lightning {
                if UInt64(wallet.totalLightningSats) < amountSats {
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

                if wallet.availableUtxos.reduce(0) { $0 + $1.valueSats } < amountSats {
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
                if totalSelectedSats < amountSats {
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

    private func calculateMaxSendableAmount() async {
        // Make sure we have everything we need to calculate the max sendable amount
        guard app.selectedWalletToPayFrom == .onchain else { return }
        guard let address = app.scannedOnchainInvoice?.address else { return }
        guard let feeRate = wallet.selectedFeeRateSatsPerVByte else { return }

        do {
            let maxAmount = try await wallet.calculateMaxSendableAmount(
                address: address,
                satsPerVByte: feeRate
            )

            await MainActor.run {
                maxSendableAmount = maxAmount
            }
        } catch {
            Logger.error("Failed to calculate max sendable amount: \(error)")
            await MainActor.run {
                // Fall back to total balance if calculation fails
                maxSendableAmount = UInt64(wallet.spendableOnchainBalanceSats)
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
