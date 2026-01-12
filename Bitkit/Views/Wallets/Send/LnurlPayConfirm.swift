import BitkitCore
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
    @FocusState private var isCommentFocused: Bool

    var uri: String {
        app.lnurlPayData!.uri
    }

    var body: some View {
        VStack {
            SheetHeader(title: t("wallet__lnurl_p_title"), showBackButton: true)

            VStack(alignment: .leading) {
                MoneyStack(
                    sats: Int(wallet.sendAmountSats ?? app.lnurlPayData!.minSendable),
                    showSymbol: true,
                    testIdPrefix: "ReviewAmount"
                )
                .padding(.bottom, 32)

                VStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        CaptionMText(t("wallet__send_invoice"))
                            .padding(.bottom, 8)
                        BodySSBText(uri)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    VStack(alignment: .leading) {
                        CaptionMText(t("wallet__send_fee_and_speed"))
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

                    if let commentAllowed = app.lnurlPayData?.commentAllowed, commentAllowed > 0 {
                        VStack(alignment: .leading) {
                            CaptionMText(t("wallet__lnurl_pay_confirm__comment"))
                                .padding(.bottom, 8)

                            TextField(
                                t("wallet__lnurl_pay_confirm__comment_placeholder"),
                                text: $comment,
                                axis: .vertical,
                                testIdentifier: "CommentInput",
                                submitLabel: .done
                            )
                            .focused($isCommentFocused)
                            .dismissKeyboardOnReturn(text: $comment, isFocused: $isCommentFocused)
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
                title: t("wallet__send_swipe"),
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

    private func performPayment() async throws {
        guard let lnurlPayData = app.lnurlPayData else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing LNURL pay data"])
        }

        let amount = wallet.sendAmountSats ?? lnurlPayData.minSendable

        // Fetch the Lightning invoice from LNURL
        let bolt11 = try await LnurlHelper.fetchLnurlInvoice(
            callbackUrl: lnurlPayData.callback,
            amount: amount,
            comment: comment.isEmpty ? nil : comment
        )

        do {
            // Perform the Lightning payment
            let paymentHash = try await wallet.send(bolt11: bolt11, sats: wallet.sendAmountSats)
            Logger.info("LNURL payment successful: \(paymentHash)")
            navigationPath.append(.success(paymentHash))
        } catch {
            Logger.error("LNURL payment failed: \(error)")

            // TODO: remove toast and use failure screen instead
            app.toast(error)

            // TODO: this is a hack to make sure the navigation binding is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                navigationPath.append(.failure)
            }
        }
    }
}
