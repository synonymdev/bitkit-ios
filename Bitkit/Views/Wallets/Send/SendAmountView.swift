import SwiftUI

struct SendAmountView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]

    @State private var amountViewModel = AmountInputViewModel()
    @State private var maxSendableAmount: UInt64?
    @State private var routingFee: UInt64 = 0

    var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    var canSwitchWallet: Bool {
        app.scannedOnchainInvoice != nil && app.scannedLightningInvoice != nil
    }

    /// Paying an on-chain address out of spending through a swap: the recipient is still an
    /// address, only the funding source and its limits differ.
    private var isSwapSend: Bool {
        app.isSwapSend && app.selectedWalletToPayFrom == .onchain
    }

    private var payingFromSpending: Bool {
        app.selectedWalletToPayFrom == .lightning || isSwapSend
    }

    private var assetButtonTestIdentifier: String {
        if canSwitchWallet {
            return "switch"
        }
        return payingFromSpending ? "spending" : "savings"
    }

    /// The amount to display in the available balance section
    /// For onchain transactions, this shows the max sendable amount (balance minus fees)
    /// For lightning transactions, this shows the max sendable lightning amount minus routing fees
    /// For swap sends, this shows what a swap can actually deliver on-chain after its fees
    var availableAmount: UInt64 {
        if isSwapSend {
            return app.sendSwapBounds?.maxDeliverSat ?? 0
        } else if app.selectedWalletToPayFrom == .lightning {
            let maxSendLightning = UInt64(wallet.maxSendLightningSats)
            return maxSendLightning >= routingFee ? maxSendLightning - routingFee : 0
        } else {
            // For onchain, show max sendable amount if calculated, otherwise fall back to total balance
            return maxSendableAmount ?? UInt64(wallet.spendableOnchainBalanceSats)
        }
    }

    private var minimumAmount: UInt64 {
        let dustLimit = UInt64(Env.dustLimit)
        if isSwapSend {
            // Boltz's reverse minimum applies to the invoice, so the delivered floor is higher
            // than the dust limit and an amount below it can never be quoted.
            return max(dustLimit, app.sendSwapBounds?.minDeliverSat ?? dustLimit)
        }
        return app.selectedWalletToPayFrom == .lightning ? 1 : dustLimit
    }

    private var isValidAmount: Bool {
        amountSats >= minimumAmount && amountSats <= availableAmount
    }

    /// Highest amount the number pad accepts. On a plain on-chain send this is normally the savings
    /// max, but when a swap is on offer it is raised to what the swap can deliver so the user can
    /// type past their savings ceiling; crossing it flips the send onto the swap rail.
    private var inputCap: UInt64 {
        max(availableAmount, app.sendSwapBounds?.maxDeliverSat ?? 0)
    }

    /// Determines if the current amount is a max amount send
    var isMaxAmountSend: Bool {
        guard app.selectedWalletToPayFrom == .onchain, !isSwapSend else { return false }
        return amountSats == availableAmount && amountSats > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: t("wallet__send_amount"),
                showBackButton: true,
                action: AnyView(SendContactHeaderAvatar())
            )

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
                                type: .info,
                                title: t("wallet__send_max_spending__title"),
                                description: t("wallet__send_max_spending__description")
                            )
                        }
                    }

                    Spacer()

                    // No specific invoice, show toggle button based on selected wallet type
                    NumberPadActionButton(
                        text: payingFromSpending
                            ? t("wallet__spending__title")
                            : t("wallet__savings__title"),
                        imageName: canSwitchWallet ? "arrow-up-down" : nil,
                        color: payingFromSpending ? .purpleAccent : .brandAccent,
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
        .task {
            // Establish the swap ceiling up front so the pad lets the user type past their savings
            // balance toward what a swap could deliver. No-op unless swaps are enabled and this is
            // a plain on-chain send.
            await app.primeSwapSendBounds()
        }
        .task(id: amountSats) {
            // Keyed on the amount so a slow re-price is cancelled when the amount changes again.
            await resolveSwapSendMethod()
        }
        .onChange(of: app.isSwapSend) { _, _ in
            // Falling back to savings needs the fee-aware on-chain max, which is skipped while in
            // swap mode; recompute it so Continue is not enabled at an amount that leaves no fee.
            if !isSwapSend {
                Task { await calculateMaxSendableAmount() }
            }
        }
        .onChange(of: app.selectedWalletToPayFrom) { _, newValue in
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
        .onChange(of: wallet.selectedFeeRateSatsPerVByte) {
            // Recalculate max sendable amount when fee rate becomes available or changes
            if app.selectedWalletToPayFrom == .onchain {
                Task {
                    await calculateMaxSendableAmount()
                }
            }
        }
        .onChange(of: inputCap, initial: true) { updateInputCap() }
        .onChange(of: amountViewModel.maxExceededCount) { showMaxExceededToast() }
    }

    private func onContinue() async {
        do {
            wallet.sendAmountSats = amountSats
            wallet.isMaxAmountSend = isMaxAmountSend

            // Swap send: the recipient is an on-chain address but the funds leave spending, so
            // there are no UTXOs to select and nothing to coin-select over.
            if isSwapSend {
                await app.refreshSwapQuote(amountSats: amountSats)
                // Bounds are cached; a nil quote here means the swap became unavailable (Boltz
                // unreachable, or spending capacity dropped below the amount). Surface it rather
                // than pushing the user onto a review screen that can never be swiped.
                guard app.sendSwapQuote != nil else {
                    app.toast(type: .error, title: t("other__try_again"))
                    return
                }
                navigationPath.append(.confirm)
                return
            }

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

    private func updateInputCap() {
        // Don't cap when nothing is sendable, so the pad stays usable (Continue stays disabled instead).
        amountViewModel.maxAmountOverride = inputCap > 0 ? inputCap : nil
    }

    private func showMaxExceededToast() {
        app.toast(
            type: .warning,
            title: t("wallet__send_amount_exceeded__title"),
            description: t("wallet__send_amount_exceeded__description"),
            visibilityTime: Toast.visibilityTimeShort,
            accessibilityIdentifier: "SendAmountExceededToast"
        )
    }

    /// Keep the send on the rail that can pay it as the amount is edited: savings while it fits
    /// there, spending through a swap once it does not.
    private func resolveSwapSendMethod() async {
        await app.resolveSwapSendMethod(
            amountSats: amountSats,
            onchainBalance: maxSendableAmount ?? UInt64(max(0, wallet.spendableOnchainBalanceSats))
        )
    }

    private func calculateMaxSendableAmount() async {
        // Make sure we have everything we need to calculate the max sendable amount
        guard app.selectedWalletToPayFrom == .onchain, !isSwapSend else { return }
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
                // Keep as nil on error - availableAmount will fall back to total balance
                maxSendableAmount = nil
            }
        }
    }

    private func calculateRoutingFee() async {
        guard app.selectedWalletToPayFrom == .lightning else { return }
        guard let bolt11 = app.scannedLightningInvoice?.bolt11 else { return }

        let buffer: UInt64 = 2 // TODO: find out why this is needed

        // Without usable outbound capacity (e.g. peer offline) there is nothing to estimate,
        // and subtracting the buffer below would underflow `UInt64`.
        let maxSendable = UInt64(clamping: wallet.maxSendLightningSats)
        guard maxSendable > buffer else {
            await MainActor.run {
                routingFee = 0
            }
            return
        }

        do {
            let fee = try await wallet.estimateRoutingFees(bolt11: bolt11, amountSats: maxSendable - buffer)
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
