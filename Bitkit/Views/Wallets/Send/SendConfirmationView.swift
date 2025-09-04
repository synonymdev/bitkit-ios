import BitkitCore
import LocalAuthentication
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
    @State private var showWarningAlert = false
    @State private var alertContinuation: CheckedContinuation<Bool, Error>?
    @State private var showPinCheck = false
    @State private var pinCheckContinuation: CheckedContinuation<Bool, Error>?
    @State private var showingBiometricError = false
    @State private var biometricErrorMessage = ""
    @State private var transactionFee: Int = 0

    private var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID:
            return t("security__bio_touch_id")
        case .faceID:
            return t("security__bio_face_id")
        default:
            return t("security__bio_face_id") // Default to Face ID
        }
    }

    private var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__send_review"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                    MoneyStack(sats: Int(wallet.sendAmountSats ?? invoice.amountSatoshis), showSymbol: true)
                        .padding(.bottom, 44)
                    lightningView(invoice)
                } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                    MoneyStack(sats: Int(wallet.sendAmountSats ?? invoice.amountSatoshis), showSymbol: true)
                        .padding(.bottom, 44)
                    onchainView(invoice)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            TagSelectionView(navigationPath: $navigationPath)
                .padding(.top, 16)

            Spacer()

            SwipeButton(title: t("wallet__send_swipe"), accentColor: .greenAccent) {
                // Check if we need to show warning for amounts over $100 USD
                if settings.warnWhenSendingOver100 {
                    let sats: UInt64 = if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                        wallet.sendAmountSats ?? invoice.amountSatoshis
                    } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                        wallet.sendAmountSats ?? invoice.amountSatoshis
                    } else {
                        0
                    }

                    // Convert to USD to check if over $100
                    if let usdAmount = currency.convert(sats: sats, to: "USD") {
                        if usdAmount.value > 100.0 {
                            showWarningAlert = true
                            // Wait for the alert to be dismissed
                            let shouldProceed = try await waitForAlertDismissal()
                            if !shouldProceed {
                                // User cancelled, throw error to reset SwipeButton
                                throw CancellationError()
                            }
                            // User confirmed, continue with authentication if needed
                        }
                    }
                }

                // Check if authentication is required for payments
                if settings.requirePinForPayments && settings.pinEnabled {
                    // Use biometrics if available and enabled, otherwise use PIN
                    if settings.useBiometrics && isBiometricAvailable {
                        let shouldProceed = try await requestBiometricAuthentication()
                        if !shouldProceed {
                            // User cancelled biometric authentication, throw error to reset SwipeButton

                            throw CancellationError()
                        }
                        // Biometric authentication successful, continue with payment
                    } else {
                        // Fall back to PIN
                        showPinCheck = true
                        let shouldProceed = try await waitForPinCheck()
                        if !shouldProceed {
                            // User cancelled PIN entry, throw error to reset SwipeButton
                            throw CancellationError()
                        }
                        // PIN verified, continue with payment
                    }
                }

                // Proceed with payment
                try await performPayment()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await calculateTransactionFee()
        }
        .onChange(of: wallet.selectedFeeRateSatsPerVByte) { _ in
            Task {
                await calculateTransactionFee()
            }
        }
        .alert(t("common__are_you_sure"), isPresented: $showWarningAlert) {
            Button(t("common__dialog_cancel"), role: .cancel) {
                alertContinuation?.resume(returning: false)
                alertContinuation = nil
            }
            Button(t("wallet__send_yes")) {
                alertContinuation?.resume(returning: true)
                alertContinuation = nil
            }
        } message: {
            Text(t("wallet__send_dialog1"))
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

    private func waitForAlertDismissal() async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            alertContinuation = continuation
        }
    }

    private func waitForPinCheck() async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            pinCheckContinuation = continuation
        }
    }

    private func requestBiometricAuthentication() async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            let context = LAContext()
            var error: NSError?

            // Check if biometric authentication is available
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                handleBiometricError(error)
                continuation.resume(returning: false)
                return
            }

            // Request biometric authentication
            let reason = t(
                "security__bio_confirm",
                variables: ["biometricsName": biometryTypeName]
            )

            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authenticationError in
                DispatchQueue.main.async {
                    if success {
                        Logger.debug("Biometric authentication successful for payment", context: "SendConfirmationView")
                        continuation.resume(returning: true)
                    } else {
                        if let error = authenticationError {
                            handleBiometricError(error)
                        }
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    private func handleBiometricError(_ error: Error?) {
        guard let error else { return }

        let nsError = error as NSError

        switch nsError.code {
        case LAError.biometryNotAvailable.rawValue:
            biometricErrorMessage = t("security__bio_not_available")
            showingBiometricError = true
        case LAError.biometryNotEnrolled.rawValue:
            biometricErrorMessage = t("security__bio_not_available")
            showingBiometricError = true
        case LAError.userCancel.rawValue, LAError.userFallback.rawValue:
            // User cancelled - don't show error, just keep current state
            return
        default:
            biometricErrorMessage = t(
                "security__bio_error_message",
                variables: ["type": biometryTypeName]
            )
            showingBiometricError = true
        }

        Logger.error("Biometric authentication error: \(error)", context: "SendConfirmationView")
    }

    private func performPayment() async throws {
        do {
            if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                let amount = wallet.sendAmountSats ?? invoice.amountSatoshis
                // Set the amount for the success screen
                wallet.sendAmountSats = amount

                // Perform the Lightning payment
                let paymentHash = try await wallet.send(bolt11: invoice.bolt11, sats: amount)
                Logger.info("Lightning payment successful: \(paymentHash)")

                // Apply tags to the Lightning payment
                await applyTagsToPayment(paymentId: paymentHash)

                navigationPath.append(.success(paymentHash))
            } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                let amount = wallet.sendAmountSats ?? invoice.amountSatoshis
                let txid = try await wallet.send(address: invoice.address, sats: amount)

                // Set the amount for the success screen
                wallet.sendAmountSats = amount

                Logger.info("Onchain send result txid: \(txid)")

                // Apply tags to the transaction
                await applyTagsToPayment(paymentId: txid)

                navigationPath.append(.success(txid))
            } else {
                throw NSError(
                    domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid payment method or missing invoice data"]
                )
            }
        } catch {
            Logger.error("Payment failed: \(error)")

            // TODO: remove toast and use failure screen instead
            app.toast(error)

            // TODO: this is a hack to make sure the navigation binding is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                navigationPath.append(.failure)
            }
        }
    }

    private func applyTagsToPayment(paymentId: String) async {
        if !tagManager.selectedTags.isEmpty {
            Logger.info("Applying tags to payment: \(tagManager.selectedTagsArray)")

            Task {
                do {
                    try await activityListViewModel.findActivityAndAddTags(
                        paymentHashOrTxId: paymentId,
                        tags: tagManager.selectedTagsArray
                    )
                    Logger.info("Applied tags to payment: \(tagManager.selectedTagsArray)")
                } catch {
                    Logger.warn("Failed to apply tags to payment \(paymentId): \(error)")
                    // Don't fail the payment if tagging fails
                }
            }
        }
    }

    @ViewBuilder
    func onchainView(_ invoice: OnChainInvoice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                CaptionMText(t("wallet__send_to"))
                BodySSBText(invoice.address.ellipsis(maxLength: 20))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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
    func lightningView(_: LightningInvoice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                CaptionMText(t("wallet__send_invoice"))
                BodySSBText(app.scannedLightningInvoice?.bolt11.ellipsis(maxLength: 20) ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("wallet__send_fee_and_speed"))
                    HStack(spacing: 0) {
                        Image("bolt-hollow")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 4)

                        // TODO: get actual fee
                        BodySSBText("Instant (±$0.01)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("wallet__send_invoice_expiration"))
                    HStack(spacing: 0) {
                        Image("timer-alt")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 4)

                        // TODO: get actual fee
                        BodySSBText("Expires in 10 minutes")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if let description = app.scannedLightningInvoice?.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("wallet__note"))
                    BodySSBText(description)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)

                Divider()
            }
        }
    }

    private func calculateTransactionFee() async {
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
}
