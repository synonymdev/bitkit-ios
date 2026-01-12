import BitkitCore
import SwiftUI

struct SendConfirmationView: View {
    @EnvironmentObject var activityListViewModel: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var tagManager: TagManager

    @Binding var navigationPath: [SendRoute]
    @State private var showPinCheck = false
    @State private var pinCheckContinuation: CheckedContinuation<Bool, Error>?
    @State private var showingBiometricError = false
    @State private var biometricErrorMessage = ""
    @State private var transactionFee: Int = 0
    @State private var routingFee: Int = 0

    // Warning system
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
                    .padding(.bottom, 44)
                    lightningView(invoice)
                } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                    MoneyStack(
                        sats: Int(wallet.sendAmountSats ?? invoice.amountSatoshis),
                        showSymbol: true,
                        testIdPrefix: "ReviewAmount",
                        onTap: navigateToAmount
                    )
                    .padding(.bottom, 44)
                    onchainView(invoice)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            TagSelectionView(
                onDelete: { tag in
                    tagManager.removeTagFromSelection(tag)
                },
                onAddTag: {
                    navigationPath.append(.tag)
                },
                buttonTestId: "TagsAddSend"
            )

            Spacer()

            SwipeButton(title: t("wallet__send_swipe"), accentColor: .greenAccent) {
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
        .onChange(of: wallet.selectedFeeRateSatsPerVByte) { _ in
            Task {
                await calculateTransactionFee()
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

    private func waitForPinCheck() async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            pinCheckContinuation = continuation
        }
    }

    private func performPayment() async throws {
        var createdMetadataPaymentId: String? = nil

        do {
            if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice, invoice.isExpired {
                app.toast(type: .error, title: t("other__scan__error__expired"), description: nil)
                return
            }

            if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                let amount = wallet.sendAmountSats ?? invoice.amountSatoshis
                // Set the amount for the success screen
                wallet.sendAmountSats = amount

                // Create pre-activity metadata for tags and activity address
                let paymentHash = invoice.paymentHash.hex
                createdMetadataPaymentId = paymentHash
                await createPreActivityMetadata(paymentId: paymentHash, paymentHash: paymentHash)

                // Perform the Lightning payment
                try await wallet.send(bolt11: invoice.bolt11, sats: amount)
                Logger.info("Lightning payment successful: \(paymentHash)")

                navigationPath.append(.success(paymentHash))
            } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                let amount = wallet.sendAmountSats ?? invoice.amountSatoshis
                let txid = try await wallet.send(address: invoice.address, sats: amount, isMaxAmount: wallet.isMaxAmountSend)

                // Create pre-activity metadata for tags and activity address
                await createPreActivityMetadata(paymentId: txid, address: invoice.address, txId: txid, feeRate: wallet.selectedFeeRateSatsPerVByte)

                // Set the amount for the success screen
                wallet.sendAmountSats = amount

                Logger.info("Onchain send result txid: \(txid)")

                navigationPath.append(.success(txid))
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

    @ViewBuilder
    func onchainView(_ invoice: OnChainInvoice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            editableInvoiceSection(
                title: t("wallet__send_to"),
                value: invoice.address
            )
            .padding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                Button(action: {
                    navigationPath.append(.feeRate)
                }) {
                    VStack(alignment: .leading, spacing: 8) {
                        CaptionMText(t("wallet__send_fee_and_speed"))
                        HStack(spacing: 0) {
                            Image(wallet.selectedSpeed.iconName)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundColor(wallet.selectedSpeed.iconColor)
                                .frame(width: 16, height: 16)
                                .padding(.trailing, 4)

                            if transactionFee > 0 {
                                let feeText = "\(wallet.selectedSpeed.displayTitle) ("
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

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("wallet__send_confirming_in"))
                    HStack(spacing: 0) {
                        Image("clock")
                            .foregroundColor(.brandAccent)
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 4)

                        BodySSBText(wallet.selectedSpeed.displayDescription)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
        }
    }

    @ViewBuilder
    func lightningView(_ invoice: LightningInvoice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            editableInvoiceSection(
                title: t("wallet__send_invoice"),
                value: invoice.bolt11
            )
            .padding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionMText(t("wallet__send_fee_and_speed"))
                        .padding(.bottom, 8)

                    HStack(spacing: 0) {
                        Image("bolt-hollow")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 4)

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

                    Divider()
                        .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 16)

                VStack(alignment: .leading, spacing: 0) {
                    CaptionMText(t("wallet__send_invoice_expiration"))
                        .padding(.bottom, 8)

                    HStack(spacing: 0) {
                        Image("timer-alt")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 4)

                        // TODO: get actual expiration time from invoice
                        BodySSBText("10 minutes")
                    }

                    Divider()
                        .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let description = app.scannedLightningInvoice?.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("wallet__note"))
                    BodySSBText(description)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)

                Divider()
            }
        }
    }

    @ViewBuilder
    private func editableInvoiceSection(title: String, value: String) -> some View {
        Button {
            navigateToManual(with: value)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CaptionMText(title)
                BodySSBText(value.ellipsis(maxLength: 20))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ReviewUri")
    }

    private func navigateToManual(with value: String) {
        guard !value.isEmpty else { return }
        app.manualEntryInput = value
        Task { await app.validateManualEntryInput(value) }

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
            let fee = try await wallet.calculateTotalFee(
                address: address,
                amountSats: amountSats,
                satsPerVByte: feeRate,
                utxosToSpend: wallet.selectedUtxos
            )

            await MainActor.run {
                transactionFee = Int(fee)
            }
        } catch {
            Logger.error("Failed to calculate actual fee: \(error)")
            await MainActor.run {
                transactionFee = 0
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
