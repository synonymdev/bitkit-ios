import BitkitCore
import LDKNode
import SwiftUI

struct LnurlPayConfirm: View {
    @Environment(PaykitPaymentRequestManager.self) private var paykitPaymentRequestManager
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var transfer: TransferViewModel

    @Binding var navigationPath: [SendRoute]
    @Binding var isSubmittingPayment: Bool
    let requestPinCheck: () async -> Bool
    let prepareIncomingPaymentRequest: () async throws -> Void
    let routingCacheResetAttempted: Bool
    /// Tells the sheet when a running swipe holds this screen, so its drag waits too.
    var onLockChange: (Bool) -> Void = { _ in }

    @State private var showWarningAlert = false
    @State private var alertContinuation: CheckedContinuation<Bool, Error>?
    @State private var showingBiometricError = false
    @State private var biometricErrorMessage = ""
    @State private var comment = ""
    @State private var hasStartedAutomaticPayment = false
    /// The spending balance update a payment that fits only across the channels and Spark runs first.
    @State private var sparkUpdateQuote: MoveToSparkQuote?
    @State private var isSparkUpdateQuoting = false
    @State private var screenVisit = ConfirmScreenVisit()
    @State private var swipeLock = ConfirmSwipeLock()
    /// A first subscription payment that needs the update waits for a swipe on its update fee instead of paying by itself.
    @State private var needsUpdateConfirmation = false
    @FocusState private var isCommentFocused: Bool

    static func sendLightningPayment<Result>(
        request: PaykitPaymentRequest?,
        authorize: (PaykitPaymentRequest) async throws -> Void,
        onAuthorizationFailure: (Error) async -> Void,
        send: () async throws -> Result
    ) async throws -> Result {
        if let request {
            do {
                try await authorize(request)
            } catch {
                await onAuthorizationFailure(error)
                throw error
            }
        }
        return try await send()
    }

    private var shouldAutomaticallyPay: Bool {
        Self.shouldAutomaticallyPay(
            isInitialSubscriptionPayment: app.contactPaymentContext?.isInitialSubscriptionPayment == true,
            hasConversion: app.contactPaymentContext?.incomingPaymentRequest?.pricing.conversion != nil,
            needsUpdateConfirmation: needsUpdateConfirmation
        )
    }

    /// A refusal that returns after the send was closed or replaced has no review to go back to.
    static func isCurrentRefusedSend(uri: String, currentUri: String?) -> Bool {
        uri == currentUri
    }

    static func shouldAutomaticallyPay(isInitialSubscriptionPayment: Bool, hasConversion: Bool, needsUpdateConfirmation: Bool) -> Bool {
        isInitialSubscriptionPayment && !hasConversion && !needsUpdateConfirmation
    }

    var body: some View {
        ZStack {
            if let lnurlPayData = app.lnurlPayData {
                confirmationContent(lnurlPayData: lnurlPayData)
            }
            if shouldAutomaticallyPay {
                InitialSubscriptionPaymentProgress()
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
        .task {
            // The invoice comes only with the swipe, so the update is quoted before the callback.
            await estimateSparkUpdateFee()
            guard !Task.isCancelled else { return }
            // PIN navigation can cancel the view task while authorization is awaiting its result.
            Task { @MainActor in await startAutomaticPaymentIfNeeded() }
        }
        .onAppear {
            if screenVisit.isLeft {
                screenVisit = ConfirmScreenVisit()
            }
        }
        .confirmSwipeLock($swipeLock, isSubmittingPayment: isSubmittingPayment, onLockChange: onLockChange)
        .onDisappear {
            screenVisit.leave()
        }
    }

    private func confirmationContent(lnurlPayData: LnurlPayData) -> some View {
        VStack {
            SheetHeader(
                title: reviewTitle,
                showBackButton: !isSwipeLocked,
                action: AnyView(SendContactHeaderAvatar())
            )

            VStack(alignment: .leading) {
                MoneyStack(
                    sats: Int(wallet.sendAmountSats ?? lnurlPayData.minSendableSat),
                    showSymbol: true,
                    testIdPrefix: "ReviewAmount"
                )
                .padding(.bottom, 32)

                VStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        CaptionMText(t("wallet__send_invoice"))
                            .padding(.bottom, 8)
                        BodySSBText(lnurlPayData.uri)
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

                    if let feeSats = sparkUpdateQuote?.feeSats {
                        SendUpdateFeeSection(feeSats: feeSats)
                            .padding(.vertical)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()
                    }

                    if let commentAllowed = lnurlPayData.commentAllowed, commentAllowed > 0 {
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
                            // The comment stays as swiped while the swipe runs
                            .disabled(isSwipeLocked)
                            .onChange(of: comment) { _, newValue in
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
                title: app.contactPaymentContext?.isInitialSubscriptionPayment == true
                    ? t("subscriptions__swipe_to_subscribe_and_pay")
                    : t("wallet__send_swipe"),
                accentColor: .greenAccent,
                isDisabled: isSparkUpdateQuoting,
                isLoading: hasStartedAutomaticPayment || isSubmittingPayment,
                isSubmitted: hasStartedAutomaticPayment
            ) {
                swipeLock.begin()
                defer { swipeLock.end() }
                try await submitPayment(isAutomatic: false)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
    }

    private var isSwipeLocked: Bool {
        swipeLock.isLocked(isSubmittingPayment: isSubmittingPayment)
    }

    private var reviewTitle: String {
        paykitPaymentReviewTitle(context: app.contactPaymentContext, fallback: t("wallet__lnurl_p_title"))
    }

    @MainActor
    private func startAutomaticPaymentIfNeeded() async {
        guard let lnurlPayData = app.lnurlPayData,
              shouldAutomaticallyPay,
              !hasStartedAutomaticPayment
        else { return }
        guard sparkUpdateAmountSats == nil else {
            Logger.info("Opening manual confirmation for first subscription payment: update fee", context: "LnurlPayConfirm")
            needsUpdateConfirmation = true
            return
        }
        hasStartedAutomaticPayment = true
        do {
            try await submitPayment(isAutomatic: true)
        } catch is CancellationError {
            navigationPath.append(.failure(SendFailureContext(
                error: CancellationError(),
                retryRoute: .lnurlPayConfirm,
                routingCacheResetAttempted: routingCacheResetAttempted,
                paymentRequest: app.scannedLightningInvoice?.bolt11,
                contactPaymentContext: app.contactPaymentContext
            )))
        } catch {
            navigationPath.append(.failure(SendFailureContext(
                error: error,
                retryRoute: .lnurlPayConfirm,
                routingCacheResetAttempted: routingCacheResetAttempted,
                paymentRequest: "LNURL: \(lnurlPayData.uri)",
                contactPaymentContext: app.contactPaymentContext
            )))
        }
    }

    @MainActor
    static func withSubmissionLock(isSubmitting: Binding<Bool>, operation: () async throws -> Void) async throws {
        guard !isSubmitting.wrappedValue else { return }
        isSubmitting.wrappedValue = true
        defer { isSubmitting.wrappedValue = false }
        try await operation()
    }

    private func submitPayment(isAutomatic: Bool) async throws {
        try await Self.withSubmissionLock(isSubmitting: $isSubmittingPayment) {
            try await authorizeAndPerformPayment(isAutomatic: isAutomatic)
        }
    }

    /// The payment a swipe started on, so a swipe never pays an amount or LNURL edited while it waited.
    private var swipedPayment: SwipedLnurlPayment {
        SwipedLnurlPayment(uri: app.lnurlPayData?.uri, amountSats: wallet.sendAmountSats)
    }

    private func authorizeAndPerformPayment(isAutomatic: Bool) async throws {
        let swipe = swipedPayment
        guard await confirmSparkUpdateQuote() else { throw CancellationError() }
        // Going Back and continuing with another amount while the update was quoted stops this swipe.
        guard swipedPayment == swipe else {
            Logger.info("Stopped a swipe whose amount changed while the update was quoted", context: "LnurlPayConfirm")
            throw CancellationError()
        }
        // The quote this swipe approved: the PIN screen reruns `.task`, which can replace `sparkUpdateQuote` meanwhile.
        let approvedUpdateQuote = sparkUpdateQuote

        // Check if we need to show warning for amounts over $100 USD
        if settings.warnWhenSendingOver100 {
            let sats: UInt64 = if let invoice = app.scannedLightningInvoice {
                wallet.sendAmountSats ?? invoice.amountSatoshis
            } else {
                0
            }

            // Convert to USD to check if over $100
            if let usdAmount = currency.convert(sats: sats, to: "USD"), usdAmount.value > 100.0 {
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
                let shouldProceed = await requestPinCheck()
                guard shouldProceed else {
                    throw CancellationError()
                }
            }
        }

        guard swipedPayment == swipe else { throw CancellationError() }
        try await performPayment(approvedUpdateQuote: approvedUpdateQuote, isAutomatic: isAutomatic)
    }

    private func waitForAlertDismissal() async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            alertContinuation = continuation
        }
    }

    private func performPayment(approvedUpdateQuote: MoveToSparkQuote?, isAutomatic: Bool) async throws {
        guard let lnurlPayData = app.lnurlPayData else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing LNURL pay data"])
        }

        let reviewedAmount = wallet.sendAmountSats ?? lnurlPayData.minSendableSat
        guard lnurlPayData.accepts(amountSats: reviewedAmount) else {
            throw PaykitPaymentRequestError.amountMismatch
        }
        let amountMsats = lnurlPayData.callbackAmountMsats(userSats: reviewedAmount)
        let contactPaymentContext = app.contactPaymentContext
        let incomingPaymentRequest = contactPaymentContext?.incomingPaymentRequest
        let paymentActivity = PaykitPaymentActivity.shared.begin()
        defer { PaykitPaymentActivity.shared.end(paymentActivity) }
        var bolt11Invoice: String?
        var lightningPaymentHash: String?
        var shouldCancelPaymentProof = false
        var lightningPaymentSubmitted = false
        var privatePaymentListOutcome = PrivatePaymentListSendOutcome.definitePreBroadcastFailure

        do {
            try validateIncomingPaymentRequest(contactPaymentContext, amountMsats: amountMsats)
            if let incomingPaymentRequest {
                let endpointIdentifier = PublicPaykitService.MethodId.bitcoinLightningLnurl.rawValue
                guard let privateContext = contactPaymentContext?.privatePaymentContext else {
                    throw PaykitPaymentRequestError.requestUnavailable
                }
                try await PaykitPaymentProofService.shared.prepare(
                    request: incomingPaymentRequest,
                    paymentAppId: privateContext.paymentAppId(for: endpointIdentifier),
                    paymentEndpointIdentifier: endpointIdentifier,
                    kind: .lightning,
                    paymentTerms: app.paykitPaymentTerms
                )
                shouldCancelPaymentProof = true
            }
            try await prepareIncomingPaymentRequest()
            try validateIncomingPaymentRequest(contactPaymentContext, amountMsats: amountMsats)

            // Fetch the Lightning invoice from LNURL
            let bolt11 = try await LnurlHelper.fetchLnurlInvoice(
                data: lnurlPayData,
                amountMsats: amountMsats,
                comment: comment.isEmpty ? nil : comment
            )
            bolt11Invoice = bolt11

            let parsedInvoice = try Bolt11Invoice.fromStr(invoiceStr: bolt11)
            let paymentHash = String(describing: parsedInvoice.paymentHash())
            if let incomingPaymentRequest {
                try await PaykitPaymentProofService.shared.associateLightningPayment(
                    incomingPaymentRequest,
                    paymentHash: paymentHash
                )
            }

            // Perform the Lightning payment (10s timeout → navigate to pending for hold invoices)
            // LNURL server returns invoices with the amount baked in, so pass sats: nil
            // to let LDK use the invoice's native millisatoshi precision.
            _ = try await Self.sendLightningPayment(
                request: incomingPaymentRequest,
                authorize: { try await paykitPaymentRequestManager.ensurePaymentAllowed($0) },
                onAuthorizationFailure: { _ in
                    await PaykitPaymentProofService.shared.failLightningPayment(paymentHash: paymentHash)
                }
            ) {
                lightningPaymentHash = paymentHash
                // After the allowance check above, so a refused request moves nothing.
                try await MoveToSparkManager.shared.updateSpendingBalanceIfNeeded(
                    bolt11: bolt11,
                    amountSats: reviewedAmount,
                    shown: approvedUpdateQuote,
                    paymentDeadline: incomingPaymentRequest?.submissionDeadline(quoteId: app.paykitPaymentTerms?.quoteId),
                    wallet: wallet,
                    transfer: transfer,
                    onUnseen: { sparkUpdateQuote = $0 }
                )
                privatePaymentListOutcome = .uncertain
                try await wallet.sendWithTimeout(
                    bolt11: bolt11,
                    sats: nil,
                    paymentDeadline: incomingPaymentRequest?.submissionDeadline(quoteId: app.paykitPaymentTerms?.quoteId),
                    afterListening: { _ in lightningPaymentSubmitted = true },
                    onTimeout: { timedOutHash in
                        app.addPendingPaymentHash(timedOutHash, contactPaymentContext: contactPaymentContext)
                        navigationPath.append(.pending(paymentHash: timedOutHash, retryRoute: .lnurlPayConfirm, paymentRequest: bolt11))
                    }
                )
            }
            shouldCancelPaymentProof = false
            privatePaymentListOutcome = .succeeded
            await contactPaymentContext?.resolvePrivatePaymentListConsumption(privatePaymentListOutcome)
            app.addPendingContactPaymentContext(paymentHash, context: contactPaymentContext)
            Logger.info("LNURL payment successful: \(paymentHash)")
            navigationPath.append(.success(paymentId: paymentHash))
        } catch is PaymentTimeoutError {
            // onTimeout callback already navigated to .pending; suppress throw
            shouldCancelPaymentProof = false
            await contactPaymentContext?.resolvePrivatePaymentListConsumption(.uncertain)
            return
        } catch is CancellationError {
            if shouldCancelPaymentProof, let incomingPaymentRequest {
                await PaykitPaymentProofService.shared.cancelPreparation(incomingPaymentRequest)
            }
            await contactPaymentContext?.resolvePrivatePaymentListConsumption(privatePaymentListOutcome)
            return
        } catch {
            if let lightningPaymentHash {
                if incomingPaymentRequest != nil, !lightningPaymentSubmitted {
                    let failed = await PaykitPaymentProofService.shared.failLightningPayment(
                        paymentHash: lightningPaymentHash,
                        submissionError: error
                    )
                    if !failed {
                        shouldCancelPaymentProof = false
                        await contactPaymentContext?.resolvePrivatePaymentListConsumption(.uncertain)
                        app.addPendingPaymentHash(lightningPaymentHash, contactPaymentContext: contactPaymentContext)
                        navigationPath.append(.pending(
                            paymentHash: lightningPaymentHash,
                            retryRoute: .lnurlPayConfirm,
                            paymentRequest: bolt11Invoice
                        ))
                        return
                    }
                    privatePaymentListOutcome = .definitePreBroadcastFailure
                } else {
                    await PaykitPaymentProofService.shared.failLightningPayment(paymentHash: lightningPaymentHash)
                }
            }
            await contactPaymentContext?.resolvePrivatePaymentListConsumption(privatePaymentListOutcome)
            if shouldCancelPaymentProof, let incomingPaymentRequest {
                await PaykitPaymentProofService.shared.cancelPreparation(incomingPaymentRequest)
            }
            if error as? MoveToSparkError == .updateFeeUnseen {
                // Nothing moved or paid: the new update fee shows and the swipe resets to pay with it.
                guard await SendConfirmationView.restoreRequestForAnotherSwipe(
                    contactPaymentContext, app: app, manager: paykitPaymentRequestManager,
                    isCurrentSend: { Self.isCurrentRefusedSend(uri: lnurlPayData.uri, currentUri: app.lnurlPayData?.uri) }
                ) else { return }
                if isAutomatic {
                    // As for an invoice: the first subscription payment waits for a swipe on the new fee.
                    Logger.info("Opening manual confirmation for first subscription payment: update fee", context: "LnurlPayConfirm")
                    needsUpdateConfirmation = true
                    hasStartedAutomaticPayment = false
                    return
                }
                throw CancellationError()
            }
            Logger.error("LNURL payment failed: \(error)")

            navigationPath.append(.failure(SendFailureContext(
                error: error,
                retryRoute: .lnurlPayConfirm,
                routingCacheResetAttempted: routingCacheResetAttempted,
                paymentRequest: bolt11Invoice ?? "LNURL: \(lnurlPayData.uri)",
                contactPaymentContext: contactPaymentContext
            )))
        }
    }

    private var sparkUpdateAmountSats: UInt64? {
        // A swap route pays through its own service and never needs the update.
        guard let lnurlPayData = app.lnurlPayData, app.paykitSwapRoute == nil else { return nil }
        let amountSats = wallet.sendAmountSats ?? lnurlPayData.minSendableSat
        return MoveToSparkMath.needsUpdateToSend(amountSats: amountSats) ? amountSats : nil
    }

    @MainActor
    private func estimateSparkUpdateFee() async {
        guard sparkUpdateAmountSats != nil else { return }
        isSparkUpdateQuoting = true
        defer { isSparkUpdateQuoting = false }
        sparkUpdateQuote = try? await MoveToSparkManager.shared.updateQuote(wallet: wallet)
    }

    /// Quotes the update again at the swipe; a quote the user did not see, or a fee above the one shown, stops the swipe
    /// and shows the new fee instead.
    @MainActor
    private func confirmSparkUpdateQuote() async -> Bool {
        guard sparkUpdateAmountSats != nil, let lnurlPayData = app.lnurlPayData else { return true }
        let swipe = swipedPayment
        let visit = screenVisit
        let fresh: MoveToSparkQuote
        do {
            fresh = try await MoveToSparkManager.shared.updateQuote(wallet: wallet)
        } catch {
            Logger.error("Failed to quote the spending balance update: \(error)", context: "LnurlPayConfirm")
            // An amount or LNURL changed while quoting is no longer this swipe's, so its failure stays off the new one.
            guard !visit.isLeft, swipedPayment == swipe else { return false }
            navigationPath.append(.failure(SendFailureContext(
                error: MoveToSparkError.updateFailed,
                retryRoute: .lnurlPayConfirm,
                routingCacheResetAttempted: routingCacheResetAttempted,
                paymentRequest: "LNURL: \(lnurlPayData.uri)",
                contactPaymentContext: app.contactPaymentContext
            )))
            return false
        }
        // A quote for an edited payment, or one finishing after LNURL Confirm was left, would show this swipe's fee on it.
        guard !visit.isLeft, swipedPayment == swipe else { return false }
        let shown = sparkUpdateQuote
        sparkUpdateQuote = fresh
        return !MoveToSparkMath.isUpdateFeeUnseen(shownFeeSats: shown?.feeSats, freshFeeSats: fresh.feeSats)
    }

    private func validateIncomingPaymentRequest(_ context: ContactPaymentContext?, amountMsats: UInt64) throws {
        guard let context, let request = context.incomingPaymentRequest else { return }
        guard !request.isExpired(at: Date()) || paykitPaymentRequestManager.isApprovedForPayment(request) else {
            throw PaykitPaymentRequestError.requestExpired
        }
        guard app.ownsContactPaymentContext(context) else { throw PaykitPaymentRequestError.requestUnavailable }
        guard let amountSats = wallet.sendAmountSats,
              request.acceptsPaymentAmount(amountSats, method: .bitcoinLightningLnurl, paymentTerms: app.paykitPaymentTerms),
              request.acceptsLightningInvoiceAmount(milliSatoshis: amountMsats, paymentTerms: app.paykitPaymentTerms)
        else {
            throw PaykitPaymentRequestError.amountMismatch
        }
    }
}

/// The LNURL and amount a swipe on LNURL Confirm started on.
struct SwipedLnurlPayment: Equatable {
    let uri: String?
    let amountSats: UInt64?
}
