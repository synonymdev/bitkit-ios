import BitkitCore
import SwiftUI

struct SendConfirmationView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var tagManager: TagManager

    @Binding var navigationPath: [SendRoute]
    @State private var showDetails = false
    @State private var showPinCheck = false
    @State private var pinCheckContinuation: CheckedContinuation<Bool, Error>?
    @State private var showingBiometricError = false
    @State private var biometricErrorMessage = ""
    @State private var transactionFee: Int = 0
    @State private var routingFee: Int = 0
    @State private var shouldUseSendAll: Bool = false

    var accentColor: Color {
        app.selectedWalletToPayFrom == .lightning ? .purpleAccent : .brandAccent
    }

    var canSwitchWallet: Bool {
        if app.scannedOnchainInvoice != nil && app.scannedLightningInvoice != nil {
            let amount = app.scannedOnchainInvoice?.amountSatoshis ?? 0
            return amount <= wallet.spendableOnchainBalanceSats && amount <= wallet.totalLightningSats
        }

        return false
    }

    /// Warning system
    private enum WarningType: String, CaseIterable {
        case amount
        case balance
        case fee
        case feePercentage
        case minimumFee

        var title: String {
            switch self {
            case .minimumFee:
                return t("wallet__send_dialog5_title")
            default:
                return t("common__are_you_sure")
            }
        }

        var message: String {
            switch self {
            case .amount:
                return t("wallet__send_dialog1")
            case .balance:
                return t("wallet__send_dialog2")
            case .fee:
                return t("wallet__send_dialog4")
            case .feePercentage:
                return t("wallet__send_dialog3")
            case .minimumFee:
                return t("wallet__send_dialog5_description")
            }
        }
    }

    @State private var currentWarning: WarningType?
    @State private var pendingWarnings: [WarningType] = []
    @State private var warningContinuation: CheckedContinuation<Bool, Error>?
    @State private var swipeProgress: CGFloat = 0

    private var canEditAmount: Bool {
        guard app.selectedWalletToPayFrom == .lightning else {
            return true
        }

        guard let invoice = app.scannedLightningInvoice else {
            return true
        }

        return invoice.amountSatoshis == 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__send_review"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                    MoneyStack(
                        sats: Int(wallet.sendAmountSats ?? invoice.amountSatoshis),
                        showSymbol: true,
                        testIdPrefix: "ReviewAmount",
                        onTap: navigateToAmount
                    )
                } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                    MoneyStack(
                        sats: Int(wallet.sendAmountSats ?? invoice.amountSatoshis),
                        showSymbol: true,
                        testIdPrefix: "ReviewAmount",
                        onTap: navigateToAmount
                    )
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 44)

            if showDetails {
                if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                    onchainView(invoice)
                } else if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                    lightningView(invoice)
                }
            } else {
                Image("coin-stack-4")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 16)
                    .rotationEffect(.degrees(swipeProgress * 14))
            }

            CustomButton(
                title: showDetails ? t("common__hide_details") : t("common__show_details"),
                size: .small,
                icon: Image(showDetails ? "eye-slash" : app.selectedWalletToPayFrom == .lightning ? "bolt-hollow" : "speed-normal")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundColor(accentColor)
            ) {
                showDetails.toggle()
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 16)
            .accessibilityIdentifier("SendConfirmToggleDetails")

            Spacer(minLength: 16)

            SwipeButton(title: t("wallet__send_swipe"), accentColor: accentColor, swipeProgress: $swipeProgress) {
                // Validate payment and show warnings if needed
                let warnings = await validatePayment()
                if !warnings.isEmpty {
                    let shouldProceed = try await showWarnings(warnings)
                    if !shouldProceed {
                        throw CancellationError()
                    }
                }

                // Check if authentication is required for payments
                if settings.requirePinForPayments && settings.pinEnabled {
                    if settings.useBiometrics && BiometricAuth.isAvailable {
                        let result = await BiometricAuth.authenticate()
                        switch result {
                        case .success:
                            break
                        case .cancelled:
                            throw CancellationError()
                        case let .failed(message):
                            biometricErrorMessage = message
                            showingBiometricError = true
                            throw CancellationError()
                        }
                    } else {
                        showPinCheck = true
                        let shouldProceed = try await waitForPinCheck()
                        if !shouldProceed {
                            throw CancellationError()
                        }
                    }
                }

                try await performPayment()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await calculateTransactionFee()
            await calculateRoutingFee()
        }
        .onChange(of: wallet.selectedFeeRateSatsPerVByte) {
            Task {
                await calculateTransactionFee()
            }
        }
        .onChange(of: app.selectedWalletToPayFrom) {
            Task {
                if app.selectedWalletToPayFrom == .lightning {
                    await MainActor.run { transactionFee = 0 }
                    await calculateRoutingFee()
                } else {
                    await MainActor.run { routingFee = 0 }
                    await ensureOnChainStateAndRecalculateFee()
                }
            }
        }
        .alert(
            t("security__bio_error_title"),
            isPresented: $showingBiometricError
        ) {
            Button(t("common__ok")) {
                // Error handled, user acknowledged
            }
        } message: {
            Text(biometricErrorMessage)
        }
        .alert(
            currentWarning?.title ?? "",
            isPresented: .constant(currentWarning != nil)
        ) {
            Button(t("common__dialog_cancel"), role: .cancel) {
                warningContinuation?.resume(returning: false)
                warningContinuation = nil
                currentWarning = nil
            }
            Button(t("wallet__send_yes")) {
                warningContinuation?.resume(returning: true)
                warningContinuation = nil
                currentWarning = nil
            }
        } message: {
            if let warning = currentWarning {
                Text(warning.message)
            }
        }
        .navigationDestination(isPresented: $showPinCheck) {
            PinCheckView(
                title: t("security__pin_send_title"),
                explanation: t("security__pin_send"),
                onCancel: {
                    pinCheckContinuation?.resume(returning: false)
                    pinCheckContinuation = nil
                },
                onPinVerified: { _ in
                    pinCheckContinuation?.resume(returning: true)
                    pinCheckContinuation = nil
                }
            )
        }
    }

    func onchainView(_ invoice: OnChainInvoice) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                SendSectionView(t("wallet__send_from")) {
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
                    .accessibilityIdentifier("SendConfirmAssetButton")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    navigateToManual(with: invoice.address)
                } label: {
                    SendSectionView(t("wallet__send_to")) {
                        BodySSBText(invoice.address.ellipsis(maxLength: 18))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(height: 28)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(.plain)
                .accessibilityIdentifier("ReviewUri")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 16) {
                Button(action: {
                    navigationPath.append(.feeRate)
                }) {
                    SendSectionView(t("wallet__send_fee_and_speed")) {
                        HStack(spacing: 0) {
                            Image(wallet.selectedSpeed.iconName)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundColor(wallet.selectedSpeed.iconColor)
                                .frame(width: 16, height: 16)
                                .padding(.trailing, 4)

                            if transactionFee > 0 {
                                let feeText = "\(wallet.selectedSpeed.title) ("
                                HStack(spacing: 0) {
                                    BodySSBText(feeText)
                                    MoneyText(sats: transactionFee, size: .bodySSB, symbol: true, symbolColor: .textPrimary)
                                    BodySSBText(")")
                                }

                                Image("pencil")
                                    .foregroundColor(.textPrimary)
                                    .frame(width: 12, height: 12)
                                    .padding(.leading, 6)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                SendSectionView(t("wallet__send_confirming_in")) {
                    HStack(spacing: 0) {
                        Image("clock")
                            .foregroundColor(.brandAccent)
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 4)

                        BodySSBText(
                            TransactionSpeed.getFeeTierLocalized(
                                feeRate: UInt64(wallet.selectedFeeRateSatsPerVByte ?? 0),
                                feeEstimates: feeEstimatesManager.estimates,
                                variant: .range
                            )
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SendSectionView(t("wallet__tags")) {
                TagsListView(
                    tags: tagManager.selectedTagsArray,
                    icon: .close,
                    onAddTag: {
                        navigationPath.append(.tag)
                    },
                    onTagDelete: { tag in
                        tagManager.removeTagFromSelection(tag)
                    },
                    addButtonTestId: "TagsAddSend"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func lightningView(_ invoice: LightningInvoice) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SendSectionView(t("wallet__send_from")) {
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
                    .accessibilityIdentifier("SendConfirmAssetButton")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 16)

                Button {
                    navigateToManual(with: invoice.bolt11)
                } label: {
                    SendSectionView(t("wallet__send_to")) {
                        BodySSBText(invoice.bolt11.ellipsis(maxLength: 18))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(height: 28)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ReviewUri")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 16) {
                SendSectionView(t("wallet__send_fee_and_speed")) {
                    HStack(spacing: 4) {
                        Image("bolt-hollow")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)

                        if routingFee > 0 {
                            let feeText = "\(t("fee__instant__title")) (±"
                            HStack(spacing: 0) {
                                BodySSBText(feeText)
                                MoneyText(sats: routingFee, size: .bodySSB, symbol: true, symbolColor: .textPrimary)
                                BodySSBText(")")
                            }
                        } else {
                            BodySSBText(t("fee__instant__title"))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SendSectionView(t("wallet__send_invoice_expiration")) {
                    HStack(spacing: 4) {
                        Image("timer-alt")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)

                        BodySSBText(DateFormatterHelpers.formatInvoiceExpiryRelative(
                            timestampSeconds: invoice.timestampSeconds,
                            expirySeconds: invoice.expirySeconds
                        ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let description = app.scannedLightningInvoice?.description, !description.isEmpty {
                SendSectionView(t("wallet__note")) {
                    BodySSBText(description)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SendSectionView(t("wallet__tags")) {
                TagsListView(
                    tags: tagManager.selectedTagsArray,
                    icon: .close,
                    onAddTag: {
                        navigationPath.append(.tag)
                    },
                    onTagDelete: { tag in
                        tagManager.removeTagFromSelection(tag)
                    },
                    addButtonTestId: "TagsAddSend"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func waitForPinCheck() async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            pinCheckContinuation = continuation
        }
    }

    private func performPayment() async throws {
        var createdMetadataPaymentId: String? = nil

        do {
            if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                let amount = wallet.sendAmountSats ?? invoice.amountSatoshis
                // Set the amount for other screens
                wallet.sendAmountSats = amount

                // Create pre-activity metadata for tags and activity address
                let paymentHash = invoice.paymentHash.hex
                createdMetadataPaymentId = paymentHash
                await createPreActivityMetadata(paymentId: paymentHash, paymentHash: paymentHash)

                // Perform the Lightning payment (10s timeout → navigate to pending for hold invoices)
                do {
                    try await wallet.sendWithTimeout(
                        bolt11: invoice.bolt11,
                        sats: amount,
                        onTimeout: {
                            app.addPendingPaymentHash(paymentHash)
                            navigationPath.append(.pending(paymentHash: paymentHash))
                        }
                    )
                    Logger.info("Lightning payment successful: \(paymentHash)")
                    navigationPath.append(.success(paymentId: paymentHash))
                } catch is PaymentTimeoutError {
                    // onTimeout callback already navigated to .pending; suppress throw
                    return
                } catch {
                    throw error
                }
            } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                let amount = wallet.sendAmountSats ?? invoice.amountSatoshis
                // Use sendAll if explicitly MAX or if change would be dust
                let useMaxAmount = wallet.isMaxAmountSend || shouldUseSendAll
                let txid = try await wallet.send(address: invoice.address, sats: amount, isMaxAmount: useMaxAmount)

                // Create pre-activity metadata for tags and activity address
                await createPreActivityMetadata(paymentId: txid, address: invoice.address, txId: txid, feeRate: wallet.selectedFeeRateSatsPerVByte)

                // Create sent onchain activity immediately so it appears before LDK event (which can be delayed)
                await CoreService.shared.activity.createSentOnchainActivityFromSendResult(
                    txid: txid,
                    address: invoice.address,
                    amount: amount,
                    fee: UInt64(transactionFee),
                    feeRate: wallet.selectedFeeRateSatsPerVByte ?? 1
                )

                // Set the amount for the success screen
                wallet.sendAmountSats = amount

                Logger.info("Onchain send result txid: \(txid)")

                navigationPath.append(.success(paymentId: txid))
            } else {
                throw NSError(
                    domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid payment method or missing invoice data"]
                )
            }
        } catch {
            Logger.error("Payment failed: \(error)")

            if let paymentId = createdMetadataPaymentId {
                try? await CoreService.shared.activity.deletePreActivityMetadata(paymentId: paymentId)
            }

            // TODO: remove toast and use failure screen instead
            app.toast(error)

            // TODO: this is a hack to make sure the navigation binding is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                navigationPath.append(.failure)
            }
        }
    }

    private func validatePayment() async -> [WarningType] {
        var warnings: [WarningType] = []

        let amount: UInt64 = if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
            wallet.sendAmountSats ?? invoice.amountSatoshis
        } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
            wallet.sendAmountSats ?? invoice.amountSatoshis
        } else {
            0
        }

        // Check if amount > 50% of balance
        if app.selectedWalletToPayFrom == .lightning {
            let lightningBalance = wallet.totalLightningSats
            if amount > lightningBalance / 2 {
                warnings.append(.balance)
            }
        } else {
            let onchainBalance = wallet.totalOnchainSats
            if amount > onchainBalance / 2 {
                warnings.append(.balance)
            }
        }

        // Check if amount > $100 and warning is enabled
        if settings.warnWhenSendingOver100 {
            if let usdAmount = currency.convert(sats: amount, to: "USD") {
                if usdAmount.value > 100.0 {
                    warnings.append(.amount)
                }
            }
        }

        // Check if fee > $10 (only for onchain)
        if app.selectedWalletToPayFrom == .onchain {
            if let feeUsd = currency.convert(sats: UInt64(transactionFee), to: "USD") {
                if feeUsd.value > 10.0 {
                    warnings.append(.fee)
                }
            }

            // Check if fee > 50% of send amount
            if transactionFee > 0 && UInt64(transactionFee) > amount / 2 {
                warnings.append(.feePercentage)
            }

            // TODO: add minimum fee warning
            // Check minimum fee warning
            // if let feeRate = wallet.selectedFeeRateSatsPerVByte,
            //    let minimumFee = wallet.minimumFeeRateSatsPerVByte,
            //    feeRate <= minimumFee {
            //     warnings.append(.minimumFee)
            // }
        }

        return warnings
    }

    private func showWarnings(_ warnings: [WarningType]) async throws -> Bool {
        pendingWarnings = warnings

        while !pendingWarnings.isEmpty {
            let warning = pendingWarnings.removeFirst()

            let shouldProceed = try await withCheckedThrowingContinuation { continuation in
                warningContinuation = continuation
                currentWarning = warning
            }

            if !shouldProceed {
                return false
            }
        }

        return true
    }

    private func createPreActivityMetadata(
        paymentId: String,
        paymentHash: String? = nil,
        address: String? = nil,
        txId: String? = nil,
        feeRate: UInt32? = nil
    ) async {
        let currentTime = UInt64(Date().timeIntervalSince1970)
        let preActivityMetadata = BitkitCore.PreActivityMetadata(
            paymentId: paymentId,
            tags: tagManager.selectedTagsArray,
            paymentHash: paymentHash,
            txId: txId,
            address: address,
            isReceive: false,
            feeRate: feeRate.map { UInt64($0) } ?? 0,
            isTransfer: false,
            channelId: nil,
            createdAt: currentTime
        )
        try? await CoreService.shared.activity.addPreActivityMetadata(preActivityMetadata)
    }

    private func navigateToManual(with value: String) {
        guard !value.isEmpty else { return }
        app.manualEntryInput = value
        app.validateManualEntryInput(
            value,
            savingsBalanceSats: wallet.spendableOnchainBalanceSats,
            spendingBalanceSats: wallet.maxSendLightningSats
        )

        if let manualIndex = navigationPath.firstIndex(of: .manual) {
            navigationPath = Array(navigationPath.prefix(manualIndex + 1))
        } else {
            navigationPath = [.manual]
        }
    }

    private func navigateToAmount() {
        guard canEditAmount else { return }

        if let amountIndex = navigationPath.lastIndex(of: .amount) {
            navigationPath = Array(navigationPath.prefix(amountIndex + 1))
        } else {
            if let confirmIndex = navigationPath.lastIndex(of: .confirm) {
                navigationPath = Array(navigationPath.prefix(confirmIndex))
            }
            navigationPath.append(.amount)
        }
    }

    /// Ensures fee rate and UTXO selection are set when user switches to on-chain, then recalculates fee.
    private func ensureOnChainStateAndRecalculateFee() async {
        guard app.selectedWalletToPayFrom == .onchain else { return }
        guard let invoice = app.scannedOnchainInvoice else { return }

        if wallet.sendAmountSats == nil {
            await MainActor.run {
                wallet.sendAmountSats = invoice.amountSatoshis
            }
        }

        if wallet.selectedFeeRateSatsPerVByte == nil {
            do {
                try await wallet.setFeeRate(speed: settings.defaultTransactionSpeed)
            } catch {
                Logger.error("Failed to set fee rate when switching to on-chain: \(error)")
                await MainActor.run {
                    app.selectedWalletToPayFrom = .lightning
                    app.toast(type: .error, title: t("other__try_again"))
                }
                return
            }
        }

        if settings.coinSelectionMethod == .manual {
            if wallet.selectedUtxos == nil || wallet.selectedUtxos?.isEmpty == true {
                do {
                    try await wallet.loadAvailableUtxos()
                    await MainActor.run {
                        navigationPath.append(.utxoSelection)
                    }
                } catch {
                    Logger.error("Failed to load UTXOs when switching to on-chain: \(error)")
                    await MainActor.run {
                        app.selectedWalletToPayFrom = .lightning
                        app.toast(type: .error, title: t("other__try_again"))
                    }
                }
                return
            }
        } else {
            do {
                try await wallet.setUtxoSelection(coinSelectionAlgorythm: settings.coinSelectionAlgorithm)
            } catch {
                Logger.error("Failed to set UTXO selection when switching to on-chain: \(error)")
                await MainActor.run {
                    app.selectedWalletToPayFrom = .lightning
                    app.toast(
                        type: .error,
                        title: t("other__try_again"),
                        description: error.localizedDescription
                    )
                }
                return
            }
        }

        await calculateTransactionFee()
    }

    private func calculateTransactionFee() async {
        guard app.selectedWalletToPayFrom == .onchain else {
            return
        }

        guard let address = app.scannedOnchainInvoice?.address,
              let amountSats = wallet.sendAmountSats,
              let feeRate = wallet.selectedFeeRateSatsPerVByte
        else {
            return
        }

        do {
            // Fee for normal send (recipient + change outputs) - used to check if change would be dust
            let normalFee = try await wallet.calculateTotalFee(
                address: address,
                amountSats: amountSats,
                satsPerVByte: feeRate,
                utxosToSpend: wallet.selectedUtxos
            )
            let totalInput = wallet.selectedUtxos?.reduce(0) { $0 + $1.valueSats }
                ?? UInt64(wallet.spendableOnchainBalanceSats)
            let useSendAll = DustChangeHelper.shouldUseSendAllToAvoidDust(
                totalInput: totalInput,
                amountSats: amountSats,
                normalFee: normalFee
            )

            if useSendAll {
                // Change would be dust - use sendAll and add dust to fee
                let sendAllFee = try await wallet.estimateSendAllFee(
                    address: address,
                    satsPerVByte: feeRate
                )
                await MainActor.run {
                    transactionFee = Int(sendAllFee)
                    shouldUseSendAll = true
                }
            } else {
                // Normal send with change output
                await MainActor.run {
                    transactionFee = Int(normalFee)
                    shouldUseSendAll = false
                }
            }
        } catch {
            Logger.error("Failed to calculate actual fee: \(error)")
            await MainActor.run {
                transactionFee = 0
                shouldUseSendAll = false
                app.toast(type: .error, title: t("other__try_again"))
            }
        }
    }

    private func calculateRoutingFee() async {
        guard app.selectedWalletToPayFrom == .lightning else {
            return
        }

        guard let bolt11 = app.scannedLightningInvoice?.bolt11 else {
            return
        }

        do {
            let fee = try await wallet.estimateRoutingFees(bolt11: bolt11, amountSats: wallet.sendAmountSats)
            await MainActor.run {
                Logger.info("Estimated routing fees: \(fee) sat")
                routingFee = Int(fee)
            }
        } catch {
            Logger.error("Failed to calculate routing fees: \(error)")
            await MainActor.run {
                Logger.error("Failed to calculate routing fees: \(error)")
                routingFee = 0
            }
        }
    }
}
