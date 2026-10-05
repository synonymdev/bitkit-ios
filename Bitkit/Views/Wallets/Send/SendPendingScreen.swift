import BitkitCore
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
    @Binding var navigationPath: [SendRoute]

    @EnvironmentObject private var activityList: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var foundActivity: Activity?
    @State private var onchainAttempt: OnchainSendAttempt?
    @State private var onchainStateUnavailable = false
    @State private var ordinarySendResolved = false
    @State private var localFollowupUnavailable = false
    @State private var pendingOnchainProof: PendingPaykitPaymentProof?

    private var pendingHardwareWalletId: String? {
        hardwareWalletId ?? pendingOnchainProof?.onchainWalletId.flatMap { $0 == WalletScope.default ? nil : $0 }
    }

    private var pendingAmountSats: UInt64? {
        pendingHardwareWalletId == nil ? onchainAttempt?.amountSats ?? wallet.sendAmountSats : pendingOnchainProof?.onchainAmountSats
    }

    private var pendingTransactionId: String? {
        pendingHardwareWalletId == nil ? onchainAttempt?.txid : pendingOnchainProof?.paymentIdentifier ?? hardwareTransactionId
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
                        localFollowupUnavailable = loaded.followupUnavailable
                        if let resolution = loaded.resolution {
                            applyOrdinarySendResolution(resolution)
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

    private func applyOnchainPaymentResolution(_ resolution: PaykitOnchainPaymentResolution) {
        guard !ordinarySendResolved else { return }
        guard resolution.requestId == paykitPaymentRequestId,
              let identity = pubkyProfile.publicKey,
              PubkyPublicKeyFormat.matches(resolution.identity, identity)
        else { return }
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
        let attempt: OnchainSendAttempt? = if isOrdinary, let context {
            try await service.ordinaryPendingAttempt(context: context)
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
              resolution
              .walletId ==
              (ordinaryPendingContext?.walletId ?? OnchainSendAttemptService.walletId(index: LightningService.shared.currentWalletIndex)),
              onchainAttempt?.id == resolution.attemptId
        else { return }
        ordinarySendResolved = true
        foundActivity = .onchain(resolution.activity)
        onchainAttempt?.status = .accepted
        onchainAttempt?.localFollowupComplete = true
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
