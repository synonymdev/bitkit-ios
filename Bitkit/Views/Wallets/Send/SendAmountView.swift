import SwiftUI

struct SendAmountView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @Binding var navigationPath: [SendRoute]

    @StateObject private var amountViewModel = AmountInputViewModel()
    @State private var maxSendableAmount: UInt64?
    @State private var routingFee: UInt64 = 0

    var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    var canSwitchWallet: Bool {
        app.scannedOnchainInvoice != nil && app.scannedLightningInvoice != nil
    }

    private var assetButtonTestIdentifier: String {
        if canSwitchWallet {
            return "switch"
        }
        return app.selectedWalletToPayFrom == .lightning ? "spending" : "savings"
    }

    /// The amount to display in the available balance section
    /// For onchain transactions, this shows the max sendable amount (balance minus fees)
    /// For lightning transactions, this shows the max sendable lightning amount minus routing fees
    var availableAmount: UInt64 {
        if app.selectedWalletToPayFrom == .lightning {
            let maxSendLightning = UInt64(wallet.maxSendLightningSats)
            return maxSendLightning >= routingFee ? maxSendLightning - routingFee : 0
        } else {
            // For onchain, show max sendable amount if calculated, otherwise fall back to total balance
            return maxSendableAmount ?? UInt64(wallet.spendableOnchainBalanceSats)
        }
    }

    private var isValidAmount: Bool {
        let minAmount = app.selectedWalletToPayFrom == .lightning ? 1 : Env.dustLimit

        return amountSats >= minAmount && amountSats <= availableAmount
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
                NumberPadTextField(viewModel: amountViewModel, testIdentifier: "SendNumberField")
                    .onTapGesture {
                        amountViewModel.togglePrimaryDisplay(currency: currency)
                    }

                Spacer()

                // Available balance section
                HStack(alignment: .bottom) {
                    AvailableAmount(
                        label: t("wallet__send_available"),
                        amount: Int(availableAmount),
                        testIdentifier: "AvailableAmount"
                    )
                    .onTapGesture {
                        amountViewModel.updateFromSats(availableAmount, currency: currency)

                        if app.selectedWalletToPayFrom == .lightning {
                            app.toast(
                                type: .warning,
                                title: t("wallet__send_max_spending__title"),
                                description: t("wallet__send_max_spending__description")
                            )
                        }
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
                    .accessibilityIdentifier("AssetButton-\(assetButtonTestIdentifier)")

                    NumberPadActionButton(
                        text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                        imageName: "arrow-up-down",
                        color: .brandAccent
                    ) {
                        withAnimation {
                            amountViewModel.togglePrimaryDisplay(currency: currency)
                        }
                    }
                    .accessibilityIdentifier("SendNumberPadUnit")
                }
                .padding(.bottom, 12)

                Divider()

                NumberPad(
                    type: amountViewModel.getNumberPadType(currency: currency),
                    errorKey: amountViewModel.errorKey
                ) { key in
                    amountViewModel.handleNumberPadInput(key, currency: currency)
                }

                CustomButton(title: t("common__continue"), isDisabled: !isValidAmount) {
                    Task {
                        await onContinue()
                    }
                }
                .accessibilityIdentifier("ContinueAmount")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .onAppear {
            if let invoice = app.scannedOnchainInvoice, invoice.amountSatoshis > 0 {
                // Set the amount to the scanned onchain invoice amount if it exists
                amountViewModel.updateFromSats(invoice.amountSatoshis, currency: currency)
                wallet.sendAmountSats = invoice.amountSatoshis
            } else if let lightningInvoice = app.scannedLightningInvoice,
                      lightningInvoice.amountSatoshis > 0,
                      wallet.sendAmountSats == nil || wallet.sendAmountSats == 0
            {
                amountViewModel.updateFromSats(lightningInvoice.amountSatoshis, currency: currency)
                wallet.sendAmountSats = lightningInvoice.amountSatoshis
            } else if let existingAmount = wallet.sendAmountSats, existingAmount > 0 {
                amountViewModel.updateFromSats(existingAmount, currency: currency)
            }

            // Calculate max sendable amount for onchain transactions
            if app.selectedWalletToPayFrom == .onchain {
                Task {
                    await calculateMaxSendableAmount()
                }
            } else if app.selectedWalletToPayFrom == .lightning {
                Task {
                    await calculateRoutingFee()
                }
            }
        }
        .onChange(of: app.selectedWalletToPayFrom) { newValue in
            // Recalculate max sendable amount when switching wallet types
            if newValue == .onchain {
                Task {
                    await calculateMaxSendableAmount()
                }
                routingFee = 0
            } else if newValue == .lightning {
                Task {
                    await calculateRoutingFee()
                }
                maxSendableAmount = nil
            }
        }
    }

    private func onContinue() async {
        do {
            wallet.sendAmountSats = amountSats
            wallet.isMaxAmountSend = isMaxAmountSend

            // Lightning payment
            if app.selectedWalletToPayFrom == .lightning {
                if UInt64(wallet.maxSendLightningSats) < amountSats {
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

            // Onchain transaction
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

                if wallet.availableUtxos.reduce(0, { $0 + $1.valueSats }) < amountSats {
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

    private func calculateRoutingFee() async {
        guard app.selectedWalletToPayFrom == .lightning else { return }
        guard let bolt11 = app.scannedLightningInvoice?.bolt11 else { return }

        do {
            let buffer: UInt64 = 2 // TODO: find out why this is needed
            let fee = try await wallet.estimateRoutingFees(bolt11: bolt11, amountSats: UInt64(wallet.maxSendLightningSats) - buffer)
            await MainActor.run {
                routingFee = fee + buffer
            }
        } catch {
            Logger.error("Failed to calculate lightning routing fee: \(error)")
            await MainActor.run {
                routingFee = 0
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
                        .environmentObject(SettingsViewModel.shared)
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
