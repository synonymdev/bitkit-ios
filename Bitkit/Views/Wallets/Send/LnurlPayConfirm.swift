import BitkitCore
import LocalAuthentication
import SwiftUI

struct LnurlPayConfirm: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @Binding var navigationPath: [SendRoute]
    @State private var showWarningAlert = false
    @State private var alertContinuation: CheckedContinuation<Bool, Error>?
    @State private var showPinCheck = false
    @State private var pinCheckContinuation: CheckedContinuation<Bool, Error>?
    @State private var showingBiometricError = false
    @State private var biometricErrorMessage = ""
    @State private var comment = ""

    private var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID:
            return localizedString("security__bio_touch_id")
        case .faceID:
            return localizedString("security__bio_face_id")
        default:
            return localizedString("security__bio_face_id") // Default to Face ID
        }
    }

    private var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var uri: String {
        app.lnurlPayData!.uri
    }

    var body: some View {
        VStack {
            SheetHeader(title: localizedString("wallet__lnurl_p_title"), showBackButton: true)

            VStack(alignment: .leading) {
                MoneyStack(sats: Int(wallet.sendAmountSats ?? app.lnurlPayData!.minSendable), showSymbol: true)
                    .padding(.bottom, 32)

                VStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        CaptionMText(localizedString("wallet__send_invoice"))
                            .padding(.bottom, 8)
                        BodySSBText(uri)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    VStack(alignment: .leading) {
                        CaptionMText(localizedString("wallet__send_fee_and_speed"))
                            .padding(.bottom, 8)
                        HStack(spacing: 0) {
                            Image("bolt-hollow")
                                .foregroundColor(.purpleAccent)
                                .frame(width: 16, height: 16)
                                .padding(.trailing, 6)

                            // TODO: get actual fee
                            BodySSBText("Instant (±$0.02)")
                        }
                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    if let commentAllowed = app.lnurlPayData?.commentAllowed {
                        VStack(alignment: .leading) {
                            CaptionMText(localizedString("wallet__lnurl_pay_confirm__comment"))
                                .padding(.bottom, 8)

                            TextField(localizedString("wallet__lnurl_pay_confirm__comment_placeholder"), text: $comment)
                                .lineLimit(3 ... 3)
                                .onChange(of: comment) { newValue in
                                    let maxLength = Int(commentAllowed)
                                    if newValue.count > maxLength {
                                        comment = String(newValue.prefix(maxLength))
                                    }
                                }
                        }
                        .padding(.vertical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer()

            SwipeButton(
                title: localizedString("wallet__send_swipe"),
                accentColor: .greenAccent
            ) {
                // Check if we need to show warning for amounts over $100 USD
                if settings.warnWhenSendingOver100 {
                    let sats: UInt64 = if let invoice = app.scannedLightningInvoice {
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
        .alert(localizedString("common__are_you_sure"), isPresented: $showWarningAlert) {
            Button(localizedString("common__dialog_cancel"), role: .cancel) {
                alertContinuation?.resume(returning: false)
                alertContinuation = nil
            }
            Button(localizedString("wallet__send_yes")) {
                alertContinuation?.resume(returning: true)
                alertContinuation = nil
            }
        } message: {
            Text(localizedString("wallet__send_dialog1"))
        }
        .alert(
            localizedString("security__bio_error_title"),
            isPresented: $showingBiometricError
        ) {
            Button(localizedString("common__ok")) {
                // Error handled, user acknowledged
            }
        } message: {
            Text(biometricErrorMessage)
        }
        .navigationDestination(isPresented: $showPinCheck) {
            PinCheckView(
                title: localizedString("security__pin_send_title"),
                explanation: localizedString("security__pin_send"),
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
            let reason = localizedString(
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
            biometricErrorMessage = localizedString("security__bio_not_available")
            showingBiometricError = true
        case LAError.biometryNotEnrolled.rawValue:
            biometricErrorMessage = localizedString("security__bio_not_available")
            showingBiometricError = true
        case LAError.userCancel.rawValue, LAError.userFallback.rawValue:
            // User cancelled - don't show error, just keep current state
            return
        default:
            biometricErrorMessage = localizedString(
                "security__bio_error_message",
                variables: ["type": biometryTypeName]
            )
            showingBiometricError = true
        }

        Logger.error("Biometric authentication error: \(error)", context: "SendConfirmationView")
    }

    private func performPayment() async throws {
        guard let lnurlPayData = app.lnurlPayData else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing LNURL pay data"])
        }

        let amount = wallet.sendAmountSats ?? lnurlPayData.minSendable

        // Fetch the Lightning invoice from LNURL
        let bolt11Invoice = try await LnurlHelper.fetchLnurlInvoice(
            callbackUrl: lnurlPayData.callback,
            amount: amount,
            comment: comment.isEmpty ? nil : comment
        )

        // Perform the Lightning payment
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task {
                do {
                    let paymentHash = try await wallet.send(
                        bolt11: bolt11Invoice,
                        sats: wallet.sendAmountSats,
                        onSuccess: {
                            Logger.info("LNURL payment successful")
                            continuation.resume()
                            navigationPath.append(.success)
                        },
                        onFail: { reason in
                            Logger.error("LNURL payment failed: \(reason)")
                            continuation.resume(
                                throwing: NSError(domain: "Lightning", code: -1, userInfo: [NSLocalizedDescriptionKey: reason])
                            )
                            navigationPath.append(.failure)
                        }
                    )
                    Logger.info("LNURL send initiated with payment hash: \(paymentHash)")
                } catch {
                    continuation.resume(throwing: error)
                    navigationPath.append(.failure)
                }
            }
        }
    }
}
