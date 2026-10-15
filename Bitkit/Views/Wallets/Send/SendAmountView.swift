import SwiftUI

enum SendFundingSource: Equatable {
    case spending
    case savings
    case usdt
    case hardware(walletId: String)
}

struct SendAmountView: View {
    @Environment(\.dismiss) private var dismiss
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
    @State private var amountConversion = PaykitAmountEntryConversion()
    @State private var conversionError: String?
    @State private var showingFundingSources = false

    var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    private var canEditAmount: Bool {
        app.contactPaymentContext?.incomingPaymentRequest == nil && app.fixedLightningAmountSats == nil
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
        if settings.isUsdtEnabled,
           app.contactPaymentContext?.endpoints.contains(where: { $0.methodId == .usdtArbitrum }) == true { sources.append(.usdt) }
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
        fundingSourceLabel(selectedFundingSource)
    }

    private var selectedSourceColor: Color {
        fundingSourceColor(selectedFundingSource)
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
            return (try? parsePaykitAmountInput(asset: .usdt, value: usdtAmount)).map { $0.atomic > 0 && $0.atomic <= (usdt.balance ?? 0) } ?? false
        }
        let minAmount = app.selectedWalletToPayFrom == .lightning ? 1 : Env.dustLimit

        if app.selectedWalletToPayFrom == .lightning, let data = app.lnurlPayData,
           !data.accepts(amountSats: amountSats) { return false }
        return amountSats >= minAmount && amountSats <= availableAmount
    }

    /// Determines if the current amount is a max amount send
    var isMaxAmountSend: Bool {
        guard app.selectedWalletToPayFrom == .onchain, app.contactPaymentContext?.incomingPaymentRequest == nil else { return false }
        return amountSats == availableAmount && amountSats > 0
    }

    var body: some View {
        if app.paykitUsesUsdt, !settings.isUsdtEnabled {
            UsdtIntroContent(isEnablePrompt: true, onDecline: { dismiss() },
                             onEnable: { settings.usdtPreference = .enabled })
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: t("wallet__send_amount"),
                showBackButton: true,
                action: AnyView(SendContactHeaderAvatar()),
                topPadding: app.paykitUsesUsdt ? 28 : 32,
                bottomPadding: app.paykitUsesUsdt ? 22 : 24,
                dragIndicatorTopPadding: app.paykitUsesUsdt ? 8 : nil
            )

            VStack(alignment: .leading, spacing: 0) {
                if app.paykitUsesUsdt {
                    UsdtAmountHeader(amount: usdtAmount.isEmpty ? "0" : usdtAmount)
                        .accessibilityIdentifier("SendNumberField")
                } else {
                    NumberPadTextField(viewModel: amountViewModel, testIdentifier: "SendNumberField")
                        .onTapGesture { amountViewModel.togglePrimaryDisplay(currency: currency) }
                }
                if let conversionError { BodySText(conversionError, textColor: .brandAccent).padding(.top, 12) }

                if app.paykitUsesUsdt { Spacer().frame(height: 32) } else { Spacer() }

                // Available balance section
                HStack(alignment: .bottom) {
                    if app.paykitUsesUsdt {
                        VStack(alignment: .leading, spacing: 4) {
                            CaptionMText(t("wallet__send_available"))
                            BodySSBText(settings.hideBalance ? "•••••" : "<accent>$</accent> " + (usdt.balance.map { usdtOverviewAmount($0) } ?? "—"),
                                        accentColor: .textSecondary)
                        }
                    } else {
                        AvailableAmount(
                            label: t("wallet__send_available"),
                            amount: Int(availableAmount),
                            testIdentifier: "AvailableAmount"
                        )
                        .onTapGesture {
                            guard canEditAmount else { return }
                            amountConversion.reset()
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
                        disabled: isContinuing,
                        isLoading: hwSend.isFundingSourceLoading
                    ) {
                        showingFundingSources = true
                    }
                    .accessibilityIdentifier("AssetButton-\(assetButtonTestIdentifier)")
                    .popover(isPresented: $showingFundingSources, arrowEdge: .bottom) {
                        fundingSourceMenu
                            .presentationCompactAdaptation(.popover)
                            .presentationBackground(Color.gray6)
                    }

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
                .padding(.bottom, app.paykitUsesUsdt ? 16 : 12)

                Divider()

                NumberPad(
                    type: app.paykitUsesUsdt ? .decimal : amountViewModel.getNumberPadType(currency: currency),
                    decimalSeparator: app.paykitUsesUsdt ? Locale.current.decimalSeparator ?? "." : ".",
                    errorKey: amountViewModel.errorKey,
                    isDisabled: !canEditAmount
                ) { key in
                    amountConversion.reset()
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
        .modifier(SheetBackgroundModifier(base: app.paykitUsesUsdt ? .gray7 : .black, applyGradient: !app.paykitUsesUsdt))
        .preference(key: SheetBackgroundPreferenceKey.self, value: app.paykitUsesUsdt ? .gray7 : nil)
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
            updateFixedLightningAmount()

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
        .task { if usdt.shouldRefresh(enabled: settings.isUsdtEnabled) { await usdt.refresh() } }
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
                let entered = app.paykitUsesUsdt ? try parsePaykitAmountInput(asset: .usdt, value: usdtAmount) : PaykitAmount(
                    asset: .btc,
                    atomic: amountSats
                )
                guard expected == entered else { updateRequestAmount(); return }
                app.paykitPaymentTerms = terms
            }
            if app.contactPaymentContext != nil {
                app.paykitReviewedAmount = app.paykitUsesUsdt ? try parsePaykitAmountInput(asset: .usdt, value: usdtAmount) : PaykitAmount(
                    asset: .btc,
                    atomic: amountSats
                )
            }
            if app.paykitUsesUsdt {
                guard let recipient = app.contactPaymentContext?.endpoints.first(where: { $0.methodId == .usdtArbitrum })?.value else { return }
                let amount = try parsePaykitAmountInput(asset: .usdt, value: usdtAmount)
                navigationPath.append(.usdt(recipient: recipient, amount: amount.value))
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

    private var fundingSourceMenu: some View {
        let sources: [SendFundingSource] = [.savings, .spending] + hwWalletManager.wallets.map {
            .hardware(walletId: $0.walletId)
        } + (settings.isUsdtEnabled || app.paykitUsesUsdt ? [.usdt] : [])
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(sources.indices, id: \.self) { index in
                let source = sources[index]
                let enabled = fundingSources.contains(source)
                Button {
                    showingFundingSources = false
                    selectFundingSource(source)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            CaptionMText(fundingSourceLabel(source)).lineLimit(1)
                            if case let .hardware(walletId) = source,
                               let hardwareWallet = hwWalletManager.wallets.first(where: { $0.walletId == walletId })
                            {
                                HwWalletConnectionIcon(isConnected: hardwareWallet.isConnected)
                                    .frame(width: 16, height: 16)
                            }
                        }
                        HStack(spacing: 8) {
                            Image(fundingSourceIcon(source)).resizable().scaledToFit().frame(width: 24, height: 24)
                            if source == .usdt {
                                BodyMSBText(settings.hideBalance ? "•••••" : usdt.balance.map { usdtOverviewAmount($0) } ?? "—")
                            } else {
                                MoneyText(sats: Int(fundingSourceBalance(source)), forceUnit: .bitcoin, size: .bodyMSB,
                                          symbol: false, enableHide: true, fillsWidth: false)
                            }
                            if source == .spending {
                                Image("arrow-up-down").resizable().scaledToFit().frame(width: 16, height: 16)
                                    .foregroundStyle(Color.white64)
                            }
                            Spacer(minLength: 0)
                            if source == selectedFundingSource {
                                Image("check-mark").resizable().scaledToFit().frame(width: 16, height: 16)
                                    .foregroundStyle(fundingSourceColor(source))
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled || hwSend.isFundingSourceLoading)
                .opacity(enabled ? 1 : 0.30)
                .accessibilityIdentifier("SendFundingSource-\(index)")
                if index < sources.count - 1 { CustomDivider() }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(width: 250)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SendFundingSources")
    }

    private func fundingSourceLabel(_ source: SendFundingSource) -> String {
        switch source {
        case .savings: t("wallet__savings__title")
        case .spending: t("wallet__spending__title")
        case .usdt: "USDT"
        case let .hardware(walletId):
            hwWalletManager.wallets.first { $0.walletId == walletId }?.name ?? hwWalletManager.vendor(walletId: walletId).modelName
        }
    }

    private func fundingSourceColor(_ source: SendFundingSource) -> Color {
        switch source {
        case .savings: .brandAccent
        case .spending: .purpleAccent
        case .usdt: .usdtAccent
        case .hardware: .blueAccent
        }
    }

    private func fundingSourceIcon(_ source: SendFundingSource) -> String {
        switch source {
        case .savings: "btc"
        case .spending: "ln"
        case .usdt: "tether-circle"
        case .hardware: "btc-circle-blue"
        }
    }

    private func fundingSourceBalance(_ source: SendFundingSource) -> UInt64 {
        switch source {
        case .savings: UInt64(wallet.spendableOnchainBalanceSats)
        case .spending: UInt64(wallet.maxSendLightningSats)
        case let .hardware(walletId): hwWalletManager.fundingBalance(walletId: walletId)
        case .usdt: 0
        }
    }

    private func selectFundingSource(_ source: SendFundingSource) {
        guard source != selectedFundingSource, fundingSources.contains(source) else { return }
        let target: PaykitAsset = source == .usdt ? .usdt : .btc
        let selectsFixedLightning = source == .spending &&
            ((app.scannedLightningInvoice?.amountSatoshis ?? 0) > 0 || app.lnurlPayData?.isFixedAmount == true)
        if app.contactPaymentContext?.incomingPaymentRequest != nil || (!selectsFixedLightning && app.paykitUsesUsdt != (source == .usdt)) {
            do {
                let value = app.contactPaymentContext?.incomingPaymentRequest?.amount ??
                    (app.paykitUsesUsdt ? (try? parsePaykitAmountInput(asset: .usdt, value: usdtAmount)) : PaykitAmount(
                        asset: .btc,
                        atomic: amountSats
                    ))
                let converted = try app.contactPaymentContext?.incomingPaymentRequest?
                    .payment(using: source == .usdt ? .usdtArbitrum : app.paykitBitcoinMethod(for: source == .spending ? .lightning : .onchain))
                    .amount ?? amountConversion.converted(value, to: target, rate: currency.paykitRate, at: Date())
                if target == .usdt { usdtAmount = converted.atomic == 0 ? "" : converted.value }
                else { amountViewModel.updateFromSats(converted.atomic, currency: currency) }
            } catch { conversionError = t("wallet__payment_request_rate_unavailable"); return }
        }
        conversionError = nil
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
        updateFixedLightningAmount()
    }

    private func updateFixedLightningAmount() {
        guard app.contactPaymentContext?.incomingPaymentRequest == nil, let amount = app.fixedLightningAmountSats else { return }
        amountViewModel.updateFromSats(amount, currency: currency)
        wallet.sendAmountSats = amount
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
