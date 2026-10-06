import BitkitCore
import LDKNode
import SwiftUI

struct HourglassLoadingView: View {
    @State private var rotation: Double = -16

    private var size: CGFloat {
        UIScreen.main.isSmall ? 160 : 256
    }

    var body: some View {
        Image("hourglass")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .frame(maxWidth: .infinity)
            .onAppear {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    rotation = 16
                }
            }
    }
}

struct SendPendingScreen: View {
    let paymentHash: String?
    let retryRoute: SendRetryRoute
    let paymentRequest: String?
    let paykitPaymentRequestId: PaykitPaymentRequest.ID?
    let routingCacheResetAttempted: Bool
    var attemptService: OnchainSendAttemptService = .shared
    var ordinaryPendingContext: OnchainSendPendingContext?
    var hardwareWalletId: String?
    var hardwareTransactionId: String?
    var hardwarePaymentIdentity: String?
    var proofService: PaykitPaymentProofService = .shared
    var requestPinCheck: () async -> Bool = { false }
    @Binding var navigationPath: [SendRoute]

    @EnvironmentObject private var activityList: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var foundActivity: Activity?
    @State private var onchainAttempt: OnchainSendAttempt?
    @State private var onchainStateUnavailable = false
    @State private var ordinarySendResolved = false
    @State private var localFollowupUnavailable = false
    @State private var showingRetryConfirmation = false
    @State private var retryFeeRate = ""
    @State private var retryingOnchain = false
    @State private var pendingOnchainProof: PendingPaykitPaymentProof?

    private var pendingHardwareWalletId: String? {
        hardwareWalletId ?? pendingOnchainProof?.onchainWalletId.flatMap { $0 == WalletScope.default ? nil : $0 }
    }

    private var pendingAmountSats: UInt64? {
        pendingHardwareWalletId == nil ? onchainAttempt?.amountSats ?? pendingOnchainProof?.onchainAmountSats ?? wallet
            .sendAmountSats : pendingOnchainProof?.onchainAmountSats
    }

    private var pendingTransactionId: String? {
        pendingHardwareWalletId == nil ? onchainAttempt?.txid ?? pendingOnchainProof?.paymentIdentifier : pendingOnchainProof?
            .paymentIdentifier ?? hardwareTransactionId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__send_pending"), showBackButton: false)

            if let sendAmountSats = pendingAmountSats {
                if onchainAttempt?.requestId == nil, onchainAttempt != nil {
                    BodySSBText(t("wallet__onchain_earlier_payment"))
                        .accessibilityIdentifier("EarlierOnchainPayment")
                }
                MoneyStack(sats: Int(sendAmountSats), showSymbol: true)
                    .padding(.bottom, 32)
            }

            if paymentHash == nil {
                BodyMText(onchainPendingMessage)
                if let txid = pendingTransactionId {
                    BodySSBText(t("wallet__onchain_transaction_id", variables: ["txid": txid]))
                        .textSelection(.enabled)
                }
            } else {
                BodyMText(t("wallet__send_pending_note"))
            }

            Spacer()

            HourglassLoadingView()

            Spacer()

            if pendingHardwareWalletId == nil, onchainAttempt?.canRetrySamePayment == true, !onchainStateUnavailable {
                CustomButton(title: t("wallet__onchain_retry_original"), isDisabled: retryingOnchain) {
                    retryFeeRate = String(onchainAttempt?.recoveryContext?.satsPerVbyte ?? 1)
                    showingRetryConfirmation = true
                }
                .accessibilityIdentifier("RetryOriginalOnchainPayment")
                .padding(.bottom, 16)
            }

            HStack(spacing: 16) {
                CustomButton(
                    title: t("wallet__send_details"),
                    variant: .secondary,
                    isDisabled: foundActivity == nil
                ) {
                    if let foundActivity {
                        navigation.navigate(.activityDetail(foundActivity))
                        sheets.hideSheet()
                    }
                }

                CustomButton(title: t("common__close")) {
                    sheets.hideSheet()
                }
            }
        }
        .alert(t("wallet__onchain_retry_original"), isPresented: $showingRetryConfirmation) {
            TextField(t("wallet__onchain_retry_fee"), text: $retryFeeRate).keyboardType(.numberPad)
                .disabled(onchainAttempt?.isMaxAmount == true)
            Button(t("common__cancel"), role: .cancel) {}
            Button(t("common__retry")) {
                guard let rate = UInt32(retryFeeRate), rate > 0 else {
                    app.toast(type: .warning, title: t("wallet__onchain_retry_invalid_fee"))
                    return
                }
                Task { await retryOriginalPayment(feeRate: rate) }
            }
            .disabled(UInt32(retryFeeRate).map { $0 > 0 } != true)
        } message: {
            Text(t(onchainAttempt?.isMaxAmount == true ? "wallet__onchain_retry_max_note" : "wallet__onchain_retry_note", variables: [
                "amount": CurrencyFormatter.formatSats(onchainAttempt?.amountSats ?? 0),
                "address": onchainAttempt?.address ?? "",
                "fee": String(onchainAttempt?.recoveryContext?.satsPerVbyte ?? 1),
            ]))
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if paymentHash == nil {
                if let requestId = paykitPaymentRequestId {
                    if let identity = hardwarePaymentIdentity ?? pubkyProfile.publicKey {
                        do {
                            pendingOnchainProof = try await proofService.pendingOnchainPayment(requestId: requestId, identity: identity)
                        } catch { onchainStateUnavailable = true }
                    } else {
                        onchainStateUnavailable = true
                    }
                }
                if let walletId = pendingHardwareWalletId {
                    if let proofWalletId = pendingOnchainProof?.onchainWalletId, proofWalletId != walletId {
                        onchainStateUnavailable = true
                    }
                    if let expected = hardwareTransactionId, let stored = pendingOnchainProof?.paymentIdentifier,
                       expected.caseInsensitiveCompare(stored) != .orderedSame
                    {
                        onchainStateUnavailable = true
                    }
                    if !onchainStateUnavailable, let txid = pendingTransactionId,
                       let activity = try? await CoreService.shared.activity.getOnchainActivityByTxId(txid: txid, walletId: walletId)
                    {
                        foundActivity = .onchain(activity)
                    }
                    if !onchainStateUnavailable, let requestId = paykitPaymentRequestId,
                       let identity = hardwarePaymentIdentity ?? pendingOnchainProof?.identity,
                       let txid = pendingTransactionId,
                       let resolution = await proofService.resolvedHardwarePayment(
                           requestId: requestId,
                           identity: identity,
                           walletId: walletId,
                           txid: txid
                       )
                    {
                        applyOnchainPaymentResolution(resolution)
                    }
                } else if !onchainStateUnavailable {
                    do {
                        let loaded = try await Self.loadOrdinaryPending(
                            using: attemptService, context: ordinaryPendingContext,
                            walletId: OnchainSendAttemptService.walletId(index: LightningService.shared.currentWalletIndex),
                            isOrdinary: paykitPaymentRequestId == nil
                        )
                        onchainAttempt = loaded.attempt
                        if onchainAttempt?.requestId != paykitPaymentRequestId {
                            onchainAttempt = nil
                            onchainStateUnavailable = true
                        }
                        localFollowupUnavailable = loaded.followupUnavailable
                        if let resolution = loaded.resolution {
                            applyOrdinarySendResolution(resolution)
                        } else if let attempt = onchainAttempt, attempt.orderId != nil {
                            let context = ordinaryPendingContext ?? OnchainSendPendingContext(
                                attemptId: attempt.id, walletId: attempt.walletId, txid: attempt.txid
                            )
                            if let resolution = try await wallet.resolvedAcceptedOnchainTransfer(context: context, attempts: attemptService) {
                                applyOrdinarySendResolution(resolution)
                            }
                        }
                        if let requestId = paykitPaymentRequestId, let identity = pendingOnchainProof?.identity ?? pubkyProfile.publicKey,
                           let resolution = await proofService.resolvedOnchainPayment(
                               requestId: requestId, identity: identity, context: ordinaryPendingContext
                           )
                        {
                            applyOnchainPaymentResolution(resolution)
                        }
                    } catch { onchainStateUnavailable = true }
                }
            }
            applyPendingResolutionIfNeeded(app.sendSheetPendingResolution)
            await searchForActivity()
        }
        .onChange(of: app.sendSheetPendingResolution) { _, resolution in
            applyPendingResolutionIfNeeded(resolution)
        }
        .onReceive(OnchainSendAttemptService.localResolutionPublisher) { resolution in
            applyOrdinarySendResolution(resolution)
        }
        .onReceive(PaykitPaymentProofService.onchainPaymentResolutionPublisher) { resolution in
            applyOnchainPaymentResolution(resolution)
        }
    }

    @MainActor
    private func retryOriginalPayment(feeRate: UInt32) async {
        guard !retryingOnchain, let original = onchainAttempt, original.canRetrySamePayment else { return }
        retryingOnchain = true
        defer { retryingOnchain = false }
        let context = OnchainSendPendingContext(attemptId: original.id, walletId: original.walletId, txid: original.txid)
        do {
            let result = try await attemptService.retrySamePayment(
                using: LightningService.shared, context: context, satsPerVbyte: feeRate,
                authorize: { attempt, _ in
                    if settings.requirePinForPayments && settings.pinEnabled {
                        if settings.useBiometrics && BiometricAuth.isAvailable {
                            guard case .success = await BiometricAuth.authenticate() else { throw CancellationError() }
                        } else {
                            guard await requestPinCheck() else { throw CancellationError() }
                        }
                    }
                    if attempt.requestId != nil {
                        let request = try await proofService.authorizeOnchainRecovery(attempt)
                        try await paymentRequests.ensurePaymentAllowed(request)
                        guard let payer = attempt.recoveryContext?.paymentIdentity else { throw PaykitPaymentRequestError.requestUnavailable }
                        try await proofService.requireRecoveryPayer(payer)
                    } else if let orderId = attempt.orderId {
                        let orders = try await CoreService.shared.blocktank.orders(orderIds: [orderId], refresh: true)
                        guard let order = orders.first(where: { $0.id == orderId }), order.state2 == .created,
                              order.payment?.onchain?.address == attempt.address,
                              order.clientBalanceSat == attempt.transferContext?.clientBalanceSats,
                              order.feeSat <= attempt.amountSats
                        else { throw OnchainSendAttemptError.unresolved }
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        guard let expiry = formatter.date(from: order.orderExpiresAt) ?? ISO8601DateFormatter().date(from: order.orderExpiresAt),
                              expiry > Date()
                        else { throw OnchainSendAttemptError.unresolved }
                    }
                }
            )
            _ = result
            try await refreshOriginalOutcome(context: context)
        } catch is CancellationError {
            // A positive original observation may have won while authentication awaited.
            try? await refreshOriginalOutcome(context: context)
        } catch {
            try? await refreshOriginalOutcome(context: context)
            app.toast(error is NodeError ? OnchainSendAttemptError.retryUnavailable : error)
        }
    }

    @MainActor
    private func refreshOriginalOutcome(context: OnchainSendPendingContext) async throws {
        onchainAttempt = try await attemptService.pendingAttempt(context: context)
        guard let original = onchainAttempt, original.status == .accepted, let txid = original.txid else { return }
        if let requestId = original.requestId {
            await proofService.reconcile()
            if let payer = original.recoveryContext?.paymentIdentity,
               let resolution = await proofService.resolvedOnchainPayment(requestId: requestId, identity: payer, context: context)
            {
                applyOnchainPaymentResolution(resolution)
            }
        } else if original.orderId != nil {
            if let resolution = try await wallet.resolvedAcceptedOnchainTransfer(context: context, attempts: attemptService) {
                applyOrdinarySendResolution(resolution)
            }
        } else if let resolution = try await attemptService.resumeAcceptedOrdinarySend(walletId: original.walletId, pendingContext: context) {
            applyOrdinarySendResolution(resolution)
        }
    }

    private func applyOnchainPaymentResolution(_ resolution: PaykitOnchainPaymentResolution) {
        guard !ordinarySendResolved else { return }
        guard resolution.requestId == paykitPaymentRequestId,
              let identity = pubkyProfile.publicKey,
              PubkyPublicKeyFormat.matches(resolution.identity, identity)
        else { return }
        if pendingHardwareWalletId == nil, let attempt = onchainAttempt {
            guard attempt.requestId == resolution.requestId, attempt.containsCandidate(resolution.transactionId),
                  attempt.recoveryContext?.paymentIdentity == nil ||
                  PubkyPublicKeyFormat.matches(attempt.recoveryContext?.paymentIdentity, resolution.identity)
            else { return }
        }
        if let walletId = pendingHardwareWalletId {
            guard resolution.walletId == walletId,
                  let txid = pendingTransactionId,
                  txid.caseInsensitiveCompare(resolution.transactionId) == .orderedSame,
                  PubkyPublicKeyFormat.matches(resolution.identity, hardwarePaymentIdentity ?? pendingOnchainProof?.identity)
            else { return }
        }
        ordinarySendResolved = true
        app.addPendingContactPaymentContext(
            resolution.transactionId,
            context: ContactPaymentContext(publicKey: resolution.requestId.counterparty)
        )
        Task {
            await proofService.consumeOnchainPaymentResolution(resolution)
            guard PubkyPublicKeyFormat.matches(resolution.identity, pubkyProfile.publicKey) else { return }
            navigationPath.append(.success(paymentId: resolution.transactionId, walletId: resolution.walletId))
        }
    }

    private var onchainPendingMessage: String {
        if onchainStateUnavailable {
            return t("wallet__onchain_state_unavailable")
        }
        if pendingHardwareWalletId != nil {
            return t("wallet__onchain_hardware_pending")
        }
        switch onchainAttempt?.status {
        case .rejected:
            return t("wallet__onchain_rejected_pending", variables: ["reason": onchainAttempt?.rejectionReason ?? ""])
        case .unknown, .pending:
            return t("wallet__onchain_unknown_pending")
        case .accepted:
            if ordinarySendResolved {
                return t("wallet__onchain_earlier_restored")
            }
            if localFollowupUnavailable {
                return t("wallet__onchain_pending_followup_failed")
            }
            return t("wallet__onchain_pending_followup")
        case .none:
            return t("wallet__send_pending_note")
        }
    }

    static func loadOrdinaryPending(
        using service: OnchainSendAttemptService, context: OnchainSendPendingContext?,
        walletId: String, isOrdinary: Bool = true
    ) async throws -> (attempt: OnchainSendAttempt?, resolution: OnchainSendLocalResolution?, followupUnavailable: Bool) {
        let attempt: OnchainSendAttempt? = if let context {
            try await service.pendingAttempt(context: context)
        } else {
            try await service.unresolvedAttempt(walletId: walletId)
        }
        if isOrdinary, let attempt {
            do {
                let resolution = try await service.resumeAcceptedOrdinarySend(walletId: attempt.walletId, pendingContext: context)
                return (attempt, resolution, false)
            } catch {
                // Retain original txid/amount/status even if durable local follow-up is unavailable.
                return (attempt, nil, true)
            }
        }
        return (attempt, nil, false)
    }

    private func applyOrdinarySendResolution(_ resolution: OnchainSendLocalResolution) {
        guard paymentHash == nil, paykitPaymentRequestId == nil, !ordinarySendResolved,
              Self.matchesLocalResolution(resolution, attempt: onchainAttempt, context: ordinaryPendingContext,
                                          walletId: OnchainSendAttemptService.walletId(index: LightningService.shared.currentWalletIndex))
        else { return }
        ordinarySendResolved = true
        foundActivity = .onchain(resolution.activity)
        onchainAttempt?.status = .accepted
        onchainAttempt?.localFollowupComplete = true
    }

    static func matchesLocalResolution(_ resolution: OnchainSendLocalResolution, attempt: OnchainSendAttempt?,
                                       context: OnchainSendPendingContext?, walletId: String) -> Bool
    {
        guard let attempt, attempt.requestId == nil, attempt.id == resolution.attemptId,
              attempt.walletId == resolution.walletId, resolution.walletId == (context?.walletId ?? walletId),
              context == nil || context?.attemptId == attempt.id,
              attempt.containsCandidate(resolution.txid),
              context?.txid == nil || attempt.containsCandidate(context?.txid)
        else { return false }
        return true
    }

    private func applyPendingResolutionIfNeeded(_ resolution: SendSheetPendingResolution?) {
        guard let paymentHash, let resolution, resolution.paymentHash == paymentHash else { return }
        app.consumeSendSheetPendingResolution(paymentHash: paymentHash)
        if resolution.success {
            Task { @MainActor in
                if retryRoute == .quickpay, let feePaidSats = resolution.feePaidSats, let amountSats = wallet.sendAmountSats {
                    wallet.sendAmountSats = QuickPayLimits.amountWithFeeSats(
                        amountSats: amountSats,
                        feePaidSats: feePaidSats
                    )
                }
                await applyPendingContactContextIfNeeded()
                navigationPath.append(.success(paymentId: paymentHash))
            }
        } else {
            let contactPaymentContext = app.contactPaymentContext(forPendingPaymentHash: paymentHash) ?? app.contactPaymentContext
            app.consumeContactPaymentContext(forPendingPaymentHash: paymentHash)
            navigationPath.append(.failure(SendFailureContext(
                error: AppError(paymentFailureReason: resolution.failureReason),
                retryRoute: retryRoute,
                routingCacheResetAttempted: routingCacheResetAttempted,
                paymentRequest: paymentRequest,
                contactPaymentContext: contactPaymentContext
            )))
        }
    }

    private func searchForActivity() async {
        guard let paymentHash else { return }
        do {
            try? await activityList.syncLdkNodePayments()

            let activity = try await tryNTimes(
                toTry: { try await activityList.findActivity(byPaymentId: paymentHash) },
                times: 12,
                interval: 2
            )
            await applyPendingContactContextIfNeeded()
            let updatedActivity = try? await activityList.findActivity(byPaymentId: paymentHash)
            foundActivity = updatedActivity ?? activity
        } catch {
            Logger.warn("Could not find activity for pending payment \(paymentHash): \(error)")
        }
    }

    private func applyPendingContactContextIfNeeded() async {
        guard let paymentHash,
              let contactPublicKey = app.contactPaymentContext(forPendingPaymentHash: paymentHash)?.publicKey
        else {
            return
        }

        do {
            try await activityList.setContact(contactPublicKey, forPaymentId: paymentHash)
            app.consumeContactPaymentContext(forPendingPaymentHash: paymentHash)
        } catch {
            Logger.warn("Failed to set pending contact for payment \(paymentHash): \(error)", context: "SendPendingScreen")
        }
    }
}
