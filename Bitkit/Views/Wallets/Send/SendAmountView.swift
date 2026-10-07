import SwiftUI

enum SendFundingSource: Equatable {
    case spending
    case savings
    case usdt
    case hardware(walletId: String)
}

struct SendAmountView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests
    @Environment(UsdtWalletManager.self) private var usdt
    @Environment(HwWalletManager.self) private var hwWalletManager

    @Binding var navigationPath: [SendRoute]
    let hwSend: HwSendCoordinator

    @State private var amountViewModel = AmountInputViewModel()
    @State private var maxSendableAmount: UInt64?
    @State private var routingFee: UInt64 = 0
    @State private var isContinuing = false
    @State private var usdtAmount = ""
    @State private var conversionError: String?

    var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    private var fundingSources: [SendFundingSource] {
        if let request = app.contactPaymentContext?.incomingPaymentRequest,
           PaykitUsdtPaymentService.shared.hasBinding(for: request.id) { return [.usdt] }
        var sources: [SendFundingSource] = []
        if app.scannedLightningInvoice != nil || app.lnurlPayData != nil {
            sources.append(.spending)
        }
        if app.scannedOnchainInvoice != nil {
            sources.append(.savings)
            sources.append(contentsOf: hwWalletManager.wallets.compactMap { hardwareWallet in
                guard hardwareWallet.fundingBalanceSats > 0 || hardwareWallet.walletId == hwSend.walletId else {
                    return nil
                }
                return .hardware(walletId: hardwareWallet.walletId)
            })
        }
        if app.contactPaymentContext?.endpoints.contains(where: { $0.methodId == .usdtArbitrum }) == true { sources.append(.usdt) }
        return sources
    }

    private var selectedFundingSource: SendFundingSource {
        if app.paykitUsesUsdt { return .usdt }
        if let walletId = hwSend.walletId {
            return .hardware(walletId: walletId)
        }
        return app.selectedWalletToPayFrom == .lightning ? .spending : .savings
    }

    private var canSwitchFundingSource: Bool {
        fundingSources.count > 1
    }

    private var selectedSourceLabel: String {
        return switch selectedFundingSource {
        case .spending:
            t("wallet__spending__title")
        case .savings:
            t("wallet__savings__title")
        case .usdt: "USDT"
        case let .hardware(walletId):
            hwWalletManager.wallets.first(where: { $0.id == walletId })?.name
                ?? hwWalletManager.vendor(walletId: walletId).modelName
        }
    }

    private var selectedSourceColor: Color {
        switch selectedFundingSource {
        case .spending: .purpleAccent
        case .savings: .brandAccent
        case .usdt: .usdtAccent
        case .hardware: .blueAccent
        }
    }

    private var assetButtonTestIdentifier: String {
        if canSwitchFundingSource {
            return "switch"
        }
        return switch selectedFundingSource {
        case .spending: "spending"
        case .savings: "savings"
        case .usdt: "usdt"
        case .hardware: "trezor"
        }
    }

    /// The amount to display in the available balance section
    /// For onchain transactions, this shows the max sendable amount (balance minus fees)
    /// For lightning transactions, this shows the max sendable lightning amount minus routing fees
    var availableAmount: UInt64 {
        if hwSend.isActive {
            return hwSend.availableSats
        } else if app.selectedWalletToPayFrom == .lightning {
            let maxSendLightning = UInt64(wallet.maxSendLightningSats)
            return maxSendLightning >= routingFee ? maxSendLightning - routingFee : 0
        } else {
            // For onchain, show max sendable amount if calculated, otherwise fall back to total balance
            return maxSendableAmount ?? UInt64(wallet.spendableOnchainBalanceSats)
        }
    }

    private var isValidAmount: Bool {
        if app.paykitUsesUsdt {
            return (try? PaykitAmount(asset: .usdt, value: usdtAmount)).map { $0.atomic > 0 && $0.atomic <= (usdt.balance ?? 0) } ?? false
        }
        let minAmount = app.selectedWalletToPayFrom == .lightning ? 1 : Env.dustLimit

        return amountSats >= minAmount && amountSats <= availableAmount
    }

    /// Determines if the current amount is a max amount send
    var isMaxAmountSend: Bool {
        guard app.selectedWalletToPayFrom == .onchain, app.contactPaymentContext?.incomingPaymentRequest == nil else { return false }
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
                if app.paykitUsesUsdt {
                    NumberPadAmountText(value: usdtAmount.isEmpty ? "0" : usdtAmount, symbol: "$")
                        .accessibilityIdentifier("SendNumberField")
                } else {
                    NumberPadTextField(viewModel: amountViewModel, testIdentifier: "SendNumberField")
                        .onTapGesture { amountViewModel.togglePrimaryDisplay(currency: currency) }
                }
                if let conversionError { BodySText(conversionError, textColor: .brandAccent).padding(.top, 12) }

                Spacer()

                // Available balance section
                HStack(alignment: .bottom) {
                    if app.paykitUsesUsdt {
                        VStack(alignment: .leading, spacing: 4) {
                            CaptionMText(t("wallet__send_available"))
                            BodySSBText((settings.hideBalance ? "•••••" : usdt.balance.map { PaykitAmount(asset: .usdt, atomic: $0).value } ?? "—") +
                                " USDT")
                        }
                    } else {
                        AvailableAmount(
                            label: t("wallet__send_available"),
                            amount: Int(availableAmount),
                            testIdentifier: "AvailableAmount"
                        )
                        .onTapGesture {
                            guard app.contactPaymentContext?.incomingPaymentRequest == nil else { return }
                            amountViewModel.updateFromSats(availableAmount, currency: currency)

                            if app.selectedWalletToPayFrom == .lightning {
                                app.toast(
                                    type: .info,
                                    title: t("wallet__send_max_spending__title"),
                                    description: t("wallet__send_max_spending__description")
                                )
                            }
                        }
                    }
                    Spacer()

                    NumberPadActionButton(
                        text: selectedSourceLabel,
                        imageName: canSwitchFundingSource ? "arrow-up-down" : nil,
                        color: selectedSourceColor,
                        variant: canSwitchFundingSource ? .primary : .secondary,
                        disabled: !canSwitchFundingSource || isContinuing,
                        isLoading: hwSend.isFundingSourceLoading
                    ) {
                        selectNextFundingSource()
                    }
                    .accessibilityIdentifier("AssetButton-\(assetButtonTestIdentifier)")

                    if !app.paykitUsesUsdt {
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
                }
                .padding(.bottom, 12)

                Divider()

                NumberPad(
                    type: app.paykitUsesUsdt ? .decimal : amountViewModel.getNumberPadType(currency: currency),
                    errorKey: amountViewModel.errorKey,
                    isDisabled: app.contactPaymentContext?.incomingPaymentRequest != nil
                ) { key in
                    if app.paykitUsesUsdt { usdtAmount = NumberPadInputHandler.handleInput(
                        key: key,
                        current: usdtAmount,
                        maxLength: 21,
                        maxDecimals: 6
                    ) } else { amountViewModel.handleNumberPadInput(key, currency: currency) }
                }

                CustomButton(
                    title: t("common__continue"),
                    isDisabled: !isValidAmount || conversionError != nil || hwSend.isFundingSourceLoading,
                    isLoading: isContinuing
                ) {
                    await onContinue()
                }
                .accessibilityIdentifier("ContinueAmount")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SendAmount")
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .onAppear {
            if !fundingSources.contains(selectedFundingSource), let firstSource = fundingSources.first {
                selectFundingSource(firstSource)
            }

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

            updateRequestAmount()

            // Calculate max sendable amount for onchain transactions
            if hwSend.isActive || app.selectedWalletToPayFrom == .onchain {
                Task {
                    await calculateMaxSendableAmount()
                }
            } else if app.selectedWalletToPayFrom == .lightning {
                Task {
                    await calculateRoutingFee()
                }
            }
        }
        .task { await usdt.refresh() }
        .onChange(of: paymentRequests.pendingRequests) { updateRequestAmount() }
        .onChange(of: app.selectedWalletToPayFrom) { _, newValue in
            // Recalculate max sendable amount when switching wallet types
            if hwSend.isActive || newValue == .onchain {
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
        .onChange(of: hwSend.walletId) {
            Task {
                await calculateMaxSendableAmount()
            }
        }
        .onChange(of: wallet.selectedFeeRateSatsPerVByte) {
            // Recalculate max sendable amount when fee rate becomes available or changes
            if hwSend.isActive || app.selectedWalletToPayFrom == .onchain {
                Task {
                    await calculateMaxSendableAmount()
                }
            }
        }
        .onChange(of: availableAmount, initial: true) { updateInputCap() }
        .onChange(of: amountViewModel.maxExceededCount) { showMaxExceededToast() }
    }

    private func onContinue() async {
        guard !isContinuing else { return }
        isContinuing = true
        defer { isContinuing = false }

        do {
            if let request = app.contactPaymentContext?.incomingPaymentRequest {
                let terms = try request.payment(using: app.paykitPaymentMethod)
                guard terms.isValid(at: Date()) else { throw PaykitPaymentRequestError.requestExpired }
                let expected = terms.amount
                let entered = app.paykitUsesUsdt ? try PaykitAmount(asset: .usdt, value: usdtAmount) : PaykitAmount(asset: .btc, atomic: amountSats)
                guard expected == entered else { updateRequestAmount(); return }
                app.paykitPaymentTerms = terms
            }
            if app.contactPaymentContext != nil {
                app.paykitReviewedAmount = app.paykitUsesUsdt ? try PaykitAmount(asset: .usdt, value: usdtAmount) : PaykitAmount(
                    asset: .btc,
                    atomic: amountSats
                )
            }
            if app.paykitUsesUsdt {
                guard let recipient = app.contactPaymentContext?.endpoints.first(where: { $0.methodId == .usdtArbitrum })?.value else { return }
                navigationPath.append(.usdt(recipient: recipient, amount: usdtAmount))
                return
            }
            wallet.sendAmountSats = amountSats
            wallet.isMaxAmountSend = isMaxAmountSend

            if hwSend.isActive {
                guard let address = app.scannedOnchainInvoice?.address,
                      let feeRate = wallet.selectedFeeRateSatsPerVByte
                else {
                    throw AppError(message: t("other__try_again"), debugMessage: "Missing hardware send address or fee rate")
                }
                guard try await hwSend.preparePreview(
                    manager: hwWalletManager,
                    address: address,
                    sats: amountSats,
                    satsPerVByte: UInt64(feeRate)
                ) != nil else { return }
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

                navigationPath.append(app.lnurlPayData != nil && app.scannedLightningInvoice == nil ? .lnurlPayConfirm : .confirm)
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
        amountViewModel.maxAmountOverride = availableAmount > 0 ? availableAmount : nil
    }

    private func selectNextFundingSource() {
        guard canSwitchFundingSource else { return }
        let currentIndex = fundingSources.firstIndex(of: selectedFundingSource) ?? -1
        selectFundingSource(fundingSources[(currentIndex + 1) % fundingSources.count])
    }

    private func selectFundingSource(_ source: SendFundingSource) {
        let target: PaykitAsset = source == .usdt ? .usdt : .btc
        if app.contactPaymentContext?.incomingPaymentRequest != nil || app.paykitUsesUsdt != (source == .usdt) {
            do {
                let value = app.contactPaymentContext?.incomingPaymentRequest?.amount ??
                    (app.paykitUsesUsdt ? (try? PaykitAmount(asset: .usdt, value: usdtAmount)) : PaykitAmount(asset: .btc, atomic: amountSats))
                if let value, value.atomic > 0 {
                    let converted = try app.contactPaymentContext?.incomingPaymentRequest?
                        .payment(using: source == .usdt ? .usdtArbitrum : app.paykitBitcoinMethod(for: source == .spending ? .lightning : .onchain))
                        .amount ?? value.converted(
                            to: target,
                            rate: currency.paykitRate,
                            at: Date()
                        )
                    if target == .usdt { usdtAmount = converted.value }
                    else { amountViewModel.updateFromSats(converted.atomic, currency: currency) }
                }
                conversionError = nil
            } catch { conversionError = t("wallet__payment_request_rate_unavailable"); return }
        }
        app.paykitUsesUsdt = source == .usdt
        switch source {
        case .usdt:
            hwSend.selectWallet(nil)
        case .spending:
            hwSend.selectWallet(nil)
            app.selectedWalletToPayFrom = .lightning
        case .savings:
            hwSend.selectWallet(nil)
            app.selectedWalletToPayFrom = .onchain
        case let .hardware(walletId):
            let balance = hwWalletManager.fundingBalance(walletId: walletId)
            let reserve = HwFundingSigner.feeReserve(
                balanceSats: balance,
                satsPerVByte: wallet.selectedFeeRateSatsPerVByte.map(UInt64.init)
            )
            hwSend.selectWallet(
                walletId,
                initialAvailableSats: balance > reserve ? balance - reserve : 0,
                showsLoading: true
            )
            app.selectedWalletToPayFrom = .onchain
        }
    }

    private func updateRequestAmount() {
        guard let original = app.contactPaymentContext?.incomingPaymentRequest else { return }
        let request = paymentRequests.pendingRequests.first { $0.id == original.id } ?? original
        if request != original { app.contactPaymentContext?.incomingPaymentRequest = request }
        do {
            let terms = try request.payment(using: app.paykitPaymentMethod)
            guard terms.isValid(at: Date()) else { throw PaykitPaymentRequestError.requestExpired }
            let converted = terms.amount
            if app.paykitUsesUsdt { usdtAmount = converted.value }
            else { amountViewModel.updateFromSats(converted.atomic, currency: currency) }
            conversionError = nil
        } catch { conversionError = t("wallet__payment_request_rate_unavailable") }
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

    private func calculateMaxSendableAmount() async {
        // Make sure we have everything we need to calculate the max sendable amount
        guard hwSend.isActive || app.selectedWalletToPayFrom == .onchain else { return }

        if hwSend.isActive {
            await hwSend.refreshAvailable(
                manager: hwWalletManager,
                destinationAddress: app.scannedOnchainInvoice?.address ?? "",
                satsPerVByte: wallet.selectedFeeRateSatsPerVByte.map(UInt64.init)
            )
            return
        }

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
                    SendAmountView(
                        navigationPath: .constant([]),
                        hwSend: HwSendCoordinator(walletId: nil)
                    )
                    .environmentObject(AppViewModel())
                    .environmentObject(WalletViewModel())
                    .environmentObject(CurrencyViewModel())
                    .environmentObject(SettingsViewModel.shared)
                    .environment(HwWalletManager())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
