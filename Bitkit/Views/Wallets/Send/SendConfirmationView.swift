import BitkitCore
import LocalAuthentication
import SwiftUI

struct SendConfirmationView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @Binding var navigationPath: [SendRoute]
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin
    @State private var showWarningAlert = false
    @State private var alertContinuation: CheckedContinuation<Bool, Error>?
    @State private var showPinCheck = false
    @State private var pinCheckContinuation: CheckedContinuation<Bool, Error>?
    @State private var showingBiometricError = false
    @State private var biometricErrorMessage = ""

    private var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID:
            return NSLocalizedString("security__bio_touch_id", comment: "")
        case .faceID:
            return NSLocalizedString("security__bio_face_id", comment: "")
        default:
            return NSLocalizedString("security__bio_face_id", comment: "") // Default to Face ID
        }
    }

    private var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var body: some View {
        VStack {
            SheetHeader(title: localizedString("wallet__send_review"), showBackButton: true)

            VStack(alignment: .leading) {
                if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                    MoneyStack(sats: Int(wallet.sendAmountSats ?? invoice.amountSatoshis), showSymbol: true)
                        .padding(.bottom, 32)
                    lightningView(invoice)
                } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                    MoneyStack(sats: Int(wallet.sendAmountSats ?? invoice.amountSatoshis), showSymbol: true)
                        .padding(.bottom, 32)
                    onchainView(invoice)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            SwipeButton(
                title: NSLocalizedString("wallet__send_swipe", comment: ""),
                accentColor: .greenAccent
            ) {
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
        .alert(NSLocalizedString("common__are_you_sure", comment: ""), isPresented: $showWarningAlert) {
            Button(NSLocalizedString("common__dialog_cancel", comment: ""), role: .cancel) {
                alertContinuation?.resume(returning: false)
                alertContinuation = nil
            }
            Button(NSLocalizedString("wallet__send_yes", comment: "")) {
                alertContinuation?.resume(returning: true)
                alertContinuation = nil
            }
        } message: {
            Text(NSLocalizedString("wallet__send_dialog1", comment: ""))
        }
        .alert(
            NSLocalizedString("security__bio_error_title", comment: ""),
            isPresented: $showingBiometricError
        ) {
            Button(NSLocalizedString("common__ok", comment: "")) {
                // Error handled, user acknowledged
            }
        } message: {
            Text(biometricErrorMessage)
        }
        .navigationDestination(isPresented: $showPinCheck) {
            PinCheckView(
                title: NSLocalizedString("security__pin_send_title", comment: ""),
                explanation: NSLocalizedString("security__pin_send", comment: ""),
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
                "security__bio_confirm", comment: "",
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
            biometricErrorMessage = NSLocalizedString("security__bio_not_available", comment: "")
            showingBiometricError = true
        case LAError.biometryNotEnrolled.rawValue:
            biometricErrorMessage = NSLocalizedString("security__bio_not_available", comment: "")
            showingBiometricError = true
        case LAError.userCancel.rawValue, LAError.userFallback.rawValue:
            // User cancelled - don't show error, just keep current state
            return
        default:
            biometricErrorMessage = localizedString(
                "security__bio_error_message", comment: "",
                variables: ["type": biometryTypeName]
            )
            showingBiometricError = true
        }

        Logger.error("Biometric authentication error: \(error)", context: "SendConfirmationView")
    }

    private func performPayment() async throws {
        do {
            if app.selectedWalletToPayFrom == .lightning, let bolt11 = app.scannedLightningBolt11Invoice {
                // A LN payment can throw an error right away, be successful right away, or take a while to complete/fail because it's retrying
                // different paths.
                // So we need to handle all these cases here.
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task {
                        do {
                            let paymentHash = try await wallet.send(
                                bolt11: bolt11,
                                sats: wallet.sendAmountSats,
                                onSuccess: {
                                    Logger.info("Lightning payment successful")
                                    continuation.resume()
                                    navigationPath.append(.success)
                                },
                                onFail: { reason in
                                    Logger.error("Lightning payment failed: \(reason)")
                                    app.toast(type: .error, title: "Payment failed", description: reason)
                                    continuation.resume(
                                        throwing: NSError(domain: "Lightning", code: -1, userInfo: [NSLocalizedDescriptionKey: reason])
                                    )
                                }
                            )
                            Logger.info("Lightning send initiated with payment hash: \(paymentHash)")
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                let sats = wallet.sendAmountSats ?? invoice.amountSatoshis
                let txid = try await wallet.send(address: invoice.address, sats: sats)

                Logger.info("Onchain send result txid: \(txid)")

                // TODO: this send function returns instantly, find a way to check it was actually sent before reseting send state
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                navigationPath.append(.success)
            } else {
                throw NSError(
                    domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid payment method or missing invoice data"]
                )
            }
        } catch {
            app.toast(error)
            Logger.error("Error sending: \(error)")
            throw error // Passing error up to SwipeButton so it knows to reset state
        }
    }

    @ViewBuilder
    func toView(_ address: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(localizedString("wallet__send_to"))
            BodyMBoldText(address.ellipsis(maxLength: 20), textColor: .textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    func onchainView(_ invoice: OnChainInvoice) -> some View {
        VStack {
            toView(invoice.address)

            // Divider()

            // HStack {
            //     VStack(alignment: .leading) {
            //         Text("Speed and fee")
            //             .foregroundColor(.secondary)
            //             .font(.caption)
            //         Text("TODO")
            //     }
            //     Spacer()
            //     VStack(alignment: .leading) {
            //         Text("Confirming in")
            //             .foregroundColor(.secondary)
            //             .font(.caption)
            //         Text("TODO")
            //     }
            // }
            // .padding(.vertical)

            Divider()
        }
    }

    @ViewBuilder
    func lightningView(_: LightningInvoice) -> some View {
        VStack {
            toView(app.scannedLightningBolt11Invoice ?? "")

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("wallet__send_fee_and_speed", comment: ""))
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("1")
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text("Confirms in")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("1 second")
                }
            }
            .padding(.vertical)

            Divider()
        }
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationStack {
                    SendConfirmationView(navigationPath: .constant([]))
                        .environmentObject(AppViewModel())
                        .environmentObject(SheetViewModel())
                        .environmentObject(WalletViewModel())
                        .environmentObject(SettingsViewModel())
                        .environmentObject(
                            {
                                let vm = CurrencyViewModel()
                                vm.primaryDisplay = .bitcoin
                                return vm
                            }()
                        )
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
