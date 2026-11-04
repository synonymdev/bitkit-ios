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
            // Shrinks when the screen needs the room, so the text above never truncates.
            .frame(minHeight: 0, maxHeight: size)
            .frame(width: size)
            .rotationEffect(.degrees(rotation))
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            .onAppear {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    rotation = 16
                }
            }
    }
}

/// What a Pending screen knows of a cancellation of its original on-chain payment, beside the release and Cancel payment the
/// attempt itself records before broadcasting them.
struct OnchainCancellationState: Equatable {
    /// A cancellation the wallet holds, from its own history or accepted on this screen.
    private(set) var txid: String?
    private(set) var isFinal = false
    /// The wallet's history holds `txid`, so the wallet cannot build another spend of the same coins until it drops out.
    private(set) var isHeldByWallet = false
    private(set) var heldFeeRate: UInt32?
    private(set) var hasUnknownOutcome = false
    private(set) var highestFeeRate: UInt32?
    /// A wallet sync after the latest release or Cancel payment was sent did not find it. The node reports most refusals, such
    /// as a fee too low, as an unknown outcome, so it may never have reached the network, or may sit in another mempool.
    private(set) var mayNotHaveReachedNetwork = false

    mutating func found(_ spend: OnchainInputSpend) {
        txid = spend.txid
        isFinal = spend.isFinal
        isHeldByWallet = true
        heldFeeRate = spend.satsPerVbyte
        mayNotHaveReachedNetwork = false
    }

    /// Applies a read of the wallet's cancellations: `spend` it holds, or none, after a wallet sync since the latest release or
    /// Cancel payment was sent when `syncedSinceSent`. A cancellation that is no longer found is not held, so a new Cancel
    /// payment can be built, but it may still confirm elsewhere, so retries stay hidden.
    mutating func read(_ spend: OnchainInputSpend?, syncedSinceSent: Bool) {
        if let spend {
            found(spend)
            return
        }
        isHeldByWallet = false
        isFinal = false
        heldFeeRate = nil
        mayNotHaveReachedNetwork = syncedSinceSent
    }

    /// A cancellation refused before approval for paying too little must pay a higher rate than `rate`.
    mutating func outbid(rate: UInt32) {
        highestFeeRate = max(highestFeeRate ?? 0, rate)
    }

    /// Returns the error for a cancellation that was not accepted, judged by the cancellations before it: only an earlier
    /// one can still hold the inputs. One whose outcome is unknown may have been relayed, so it shows as sent instead.
    mutating func record(_ result: OnchainSendResult, feeRate: UInt32, attempt: OnchainSendAttempt? = nil) -> String? {
        let earlierFailureMessage = attempt.map { failureMessage(for: $0) } ?? failureMessage
        // Any dispatched cancellation may have been relayed, so a replacement must pay more than it.
        highestFeeRate = max(highestFeeRate ?? 0, feeRate)
        switch result {
        case let .accepted(txid):
            self.txid = txid
            mayNotHaveReachedNetwork = false
            return nil
        case .unknown:
            hasUnknownOutcome = true
            mayNotHaveReachedNetwork = false
            return nil
        case .rejected:
            return earlierFailureMessage
        }
    }

    private func mayHaveCancellation(_ attempt: OnchainSendAttempt) -> Bool {
        txid != nil || hasUnknownOutcome || attempt.mayHaveRelayedCancellation
    }

    /// A sent or possibly relayed cancellation may still confirm, so the original must not be retried beside it.
    func canRetry(_ attempt: OnchainSendAttempt) -> Bool {
        attempt.canRetrySamePayment && !mayHaveCancellation(attempt)
    }

    /// Only a payment request can be re-sent after it may have expired; a Blocktank order is never paid again.
    func canRetryWithoutChecking(_ attempt: OnchainSendAttempt) -> Bool {
        canRetry(attempt) && attempt.requestId != nil
    }

    /// A cancellation can drop out of mempools until it is final, so it stays replaceable over the same inputs. One the wallet
    /// holds is sped up instead.
    func canCancel(_ attempt: OnchainSendAttempt) -> Bool {
        attempt.canRetrySamePayment && !isFinal && !isHeldByWallet
    }

    func canSpeedUp(_ attempt: OnchainSendAttempt) -> Bool {
        attempt.canRetrySamePayment && isHeldByWallet && !isFinal
    }

    /// A release spends the original's coins too, so it is not sent beside another cancellation or a second release.
    func canAbandon(_ attempt: OnchainSendAttempt) -> Bool {
        !mayHaveCancellation(attempt)
    }

    /// A final cancellation releases the guard at the next on-chain sync, so one still shown has not been released yet.
    var isFinalButHeld: Bool {
        isFinal
    }

    func sentTxid(for attempt: OnchainSendAttempt) -> String? {
        txid ?? attempt.cancellationTxid
    }

    /// A known cancellation holds the original inputs until it confirms or drops out, so a new one fails meanwhile.
    var failureMessage: String {
        !isFinal && (txid != nil || hasUnknownOutcome) ? t("wallet__onchain_cancel_pending_error") : t("wallet__onchain_cancel_error")
    }

    func failureMessage(for attempt: OnchainSendAttempt) -> String {
        !isFinal && mayHaveCancellation(attempt) ? t("wallet__onchain_cancel_pending_error") : t("wallet__onchain_cancel_error")
    }

    /// A replacement must pay a higher rate than every candidate and cancellation it conflicts with, and confirms at least as
    /// fast as a normal send, so a stuck payment is not held for long.
    func suggestedFeeRate(cancelling attempt: OnchainSendAttempt, normalRate: UInt32? = nil) -> UInt32 {
        let candidateRate = attempt.recoveryContext.map { $0.candidateFeeRates?.values.max() ?? $0.satsPerVbyte } ?? 0
        let releaseRate = attempt.releaseTxid == nil ? 0 : attempt.releaseFeeRate ?? 0
        let cancellationRate = attempt.cancellationTxid == nil ? 0 : attempt.cancellationFeeRate ?? 0
        let outbid = min(max(candidateRate, highestFeeRate ?? 0, releaseRate, cancellationRate), 998) + 1
        return min(max(outbid, normalRate ?? 0), 999)
    }

    func suggestedSpeedUpRate(normalRate: UInt32? = nil) -> UInt32 {
        min(max(min(max(heldFeeRate ?? 0, highestFeeRate ?? 0), 998) + 1, normalRate ?? 0), 999)
    }
}

struct SendPendingScreen: View {
    private enum RecoveryAction {
        case retry
        case retryWithoutChecking
        case cancel
        case speedUp
        case abandon

        var title: String {
            switch self {
            case .retry: t("wallet__onchain_retry_original")
            case .retryWithoutChecking: t("wallet__onchain_resend")
            case .cancel: t("wallet__onchain_cancel_payment")
            case .speedUp: t("wallet__onchain_cancel_speed_up")
            case .abandon: t("wallet__onchain_abandon")
            }
        }
    }

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

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var activityList: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
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
    @State private var refreshingOrdinaryOutcome = false
    @State private var feeEntryAction: RecoveryAction?
    @State private var retryFeeRate = ""
    @State private var retryingOnchain = false
    @State private var cancellation = OnchainCancellationState()
    @State private var normalFeeRate: UInt32?
    @State private var pendingOnchainProof: PendingPaykitPaymentProof?
    @State private var retryApprovalAction = RecoveryAction.retry
    @State private var retryApprovalMessage: String?
    @State private var retryApprovalContinuation: CheckedContinuation<Bool, Never>?
    @State private var abandonableAttempt: OnchainSendAttempt?
    @State private var showingAbandonConfirmation = false
    @State private var abandoningOnchain = false
    @State private var isAuthenticatingRecovery = false
    @State private var paymentReview: UUID?

    private var isReviewingRecovery: Bool {
        Self.isReviewingRecovery(
            scenePhase: scenePhase,
            showingRetryConfirmation: feeEntryAction != nil,
            retryApprovalMessage: retryApprovalMessage,
            showingAbandonConfirmation: showingAbandonConfirmation,
            isAuthenticatingRecovery: isAuthenticatingRecovery
        )
    }

    static func isReviewingRecovery(
        scenePhase: ScenePhase,
        showingRetryConfirmation: Bool,
        retryApprovalMessage: String?,
        showingAbandonConfirmation: Bool,
        isAuthenticatingRecovery: Bool
    ) -> Bool {
        scenePhase != .background &&
            (showingRetryConfirmation || retryApprovalMessage != nil || showingAbandonConfirmation || isAuthenticatingRecovery)
    }

    private func updatePaymentReview(_ reviewing: Bool) {
        if reviewing, paymentReview == nil {
            paymentReview = PaykitPaymentActivity.shared.beginReview()
        } else if !reviewing, let paymentReview {
            PaykitPaymentActivity.shared.endReview(paymentReview)
            self.paymentReview = nil
        }
    }

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

    private var recoverableAttempt: OnchainSendAttempt? {
        guard pendingHardwareWalletId == nil, !ordinarySendResolved, let onchainAttempt, onchainAttempt.canRetrySamePayment
        else { return nil }
        return onchainAttempt
    }

    /// Retries need the payment's own state, while cancelling needs only the wallet.
    private var canRetryOriginal: Bool {
        !onchainStateUnavailable && recoverableAttempt.map(cancellation.canRetry) == true
    }

    private var canRetryOriginalWithoutChecking: Bool {
        canRetryOriginal && recoverableAttempt.map(cancellation.canRetryWithoutChecking) == true
    }

    private var canCancelOriginal: Bool {
        recoverableAttempt.map(cancellation.canCancel) == true
    }

    private var canSpeedUpCancellation: Bool {
        recoverableAttempt.map(cancellation.canSpeedUp) == true
    }

    private var canAbandon: Bool {
        abandonableAttempt.map(cancellation.canAbandon) == true && pendingHardwareWalletId == nil && !ordinarySendResolved
    }

    private var isRecoveryRunning: Bool {
        retryingOnchain || abandoningOnchain
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
                    .fixedSize(horizontal: false, vertical: true)
                if let txid = pendingTransactionId {
                    BodyMText(t("wallet__onchain_transaction_id", variables: ["txid": txid]))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                }
                if canCancelOriginal, recoverableAttempt.map(cancellation.canAbandon) == true {
                    BodyMText(t("wallet__onchain_cancel_hint"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                }
                if recoverableAttempt != nil, cancellation.mayNotHaveReachedNetwork {
                    BodyMText(t("wallet__onchain_cancel_not_seen"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                } else if let attempt = recoverableAttempt, let txid = cancellation.sentTxid(for: attempt) {
                    BodyMText(t(cancellation.isFinalButHeld ? "wallet__onchain_cancel_final_held" : "wallet__onchain_cancel_pending"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                    BodyMText(t("wallet__onchain_transaction_id", variables: ["txid": txid]))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if recoverableAttempt?.releaseTxid != nil {
                    BodyMText(t("wallet__onchain_abandon_pending"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                }
            } else {
                BodyMText(t("wallet__send_pending_note"))
            }

            Spacer()

            // The recovery actions take the hourglass's place, so they fit on small screens.
            if !canRetryOriginal && !canCancelOriginal && !canSpeedUpCancellation && !canAbandon {
                HourglassLoadingView()

                Spacer()
            }

            if canRetryOriginal {
                CustomButton(title: RecoveryAction.retry.title, variant: .secondary, isDisabled: isRecoveryRunning) {
                    beginRecovery(.retry)
                }
                .accessibilityIdentifier("RetryOriginalOnchainPayment")
                .padding(.bottom, 16)
            }

            if canCancelOriginal {
                CustomButton(title: RecoveryAction.cancel.title, variant: .secondary, isDisabled: isRecoveryRunning) {
                    beginRecovery(.cancel)
                }
                .accessibilityIdentifier("CancelOriginalOnchainPayment")
                .padding(.bottom, 16)
            }

            if canSpeedUpCancellation {
                CustomButton(title: RecoveryAction.speedUp.title, variant: .secondary, isDisabled: isRecoveryRunning) {
                    beginRecovery(.speedUp)
                }
                .accessibilityIdentifier("SpeedUpOnchainCancellation")
                .padding(.bottom, 16)
            }

            if canAbandon {
                CustomButton(title: RecoveryAction.abandon.title, variant: .secondary, isDisabled: isRecoveryRunning) {
                    showingAbandonConfirmation = true
                }
                .accessibilityIdentifier("AbandonExpiredOnchainPayment")
                .padding(.bottom, abandoningOnchain ? 8 : 16)
                if abandoningOnchain {
                    BodyMText(t("wallet__onchain_abandon_checking"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 16)
                }
            }

            if canRetryOriginalWithoutChecking {
                CustomButton(title: RecoveryAction.retryWithoutChecking.title, variant: .tertiary, isDisabled: isRecoveryRunning) {
                    beginRecovery(.retryWithoutChecking)
                }
                .accessibilityIdentifier("RetryOriginalOnchainPaymentWithoutChecking")
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
        .alert(feeEntryAction?.title ?? "", isPresented: Binding(
            get: { feeEntryAction != nil },
            set: {
                if !$0 {
                    feeEntryAction = nil
                }
            }
        ), presenting: feeEntryAction) { action in
            if action == .cancel || action == .speedUp || onchainAttempt?.isMaxAmount != true {
                TextField(t("wallet__onchain_retry_fee"), text: $retryFeeRate).keyboardType(.numberPad)
            }
            Button(t("common__cancel"), role: .cancel) {}
            Button(t("common__continue")) {
                guard let rate = UInt32(retryFeeRate), rate > 0, rate <= 999 else {
                    app.toast(type: .warning, title: t("wallet__onchain_retry_invalid_fee"))
                    return
                }
                Task { await recover(action, feeRate: rate) }
            }
            .disabled(UInt32(retryFeeRate).map { $0 > 0 && $0 <= 999 } != true)
        } message: { action in
            Text(feeEntryNote(for: action))
        }
        .alert(retryApprovalAction.title, isPresented: Binding(
            get: { retryApprovalMessage != nil },
            set: {
                if !$0 {
                    finishRetryApproval(false)
                }
            }
        )) {
            Button(t("common__cancel"), role: .cancel) { finishRetryApproval(false) }
            Button(retryApprovalAction == .cancel ? t("wallet__onchain_cancel_authorize") : t("wallet__send_yes")) {
                finishRetryApproval(true)
            }
        } message: {
            Text(retryApprovalMessage ?? "")
        }
        .alert(RecoveryAction.abandon.title, isPresented: $showingAbandonConfirmation) {
            Button(t("common__cancel"), role: .cancel) {}
            Button(t("common__continue")) {
                Task { await abandonExpiredPayment() }
            }
        } message: {
            Text(t(abandonableAttempt?.isBlocktankFunding == true ? "wallet__onchain_abandon_transfer_note" : "wallet__onchain_abandon_note"))
        }
        .onChange(of: isReviewingRecovery, initial: true) { _, reviewing in
            updatePaymentReview(reviewing)
        }
        .onDisappear {
            finishRetryApproval(false)
            updatePaymentReview(false)
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
                } else {
                    // Loaded even when the request's state is unavailable, as cancelling the original needs only the wallet.
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
                        if !onchainStateUnavailable, let requestId = paykitPaymentRequestId,
                           let identity = pendingOnchainProof?.identity ?? pubkyProfile.publicKey,
                           let resolution = await proofService.resolvedOnchainPayment(
                               requestId: requestId, identity: identity, context: ordinaryPendingContext
                           )
                        {
                            applyOnchainPaymentResolution(resolution)
                        }
                    } catch { onchainStateUnavailable = true }
                    await showKnownCancellation()
                    normalFeeRate = await wallet.normalFeeRate()
                }
            }
            applyPendingResolutionIfNeeded(app.sendSheetPendingResolution)
            await searchForActivity()
            // Completion events are one-shot. Keep the visible original operation in sync
            // with its durable result even when an event preceded subscription or initialization.
            while paymentHash == nil, paykitPaymentRequestId == nil, pendingHardwareWalletId == nil,
                  !ordinarySendResolved, !Task.isCancelled
            {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                await refreshVisibleOrdinaryOutcome()
            }
        }
        .task {
            // The request can end, or a failed check recover, while this screen stays open.
            while paymentHash == nil, abandonableAttempt == nil, !Task.isCancelled {
                if pendingHardwareWalletId == nil {
                    guard await loadAbandonableAttempt() else { return }
                }
                guard abandonableAttempt == nil else { return }
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
        .onChange(of: app.sendSheetPendingResolution) { _, resolution in
            applyPendingResolutionIfNeeded(resolution)
        }
        .onReceive(activityList.activitiesChangedPublisher.receive(on: DispatchQueue.main)) { _ in
            Task {
                await refreshVisibleOrdinaryOutcome()
                await showKnownCancellation()
            }
        }
        .onReceive(OnchainSendAttemptService.localResolutionPublisher.receive(on: DispatchQueue.main)) { resolution in
            applyOrdinarySendResolution(resolution)
        }
        .onReceive(PaykitPaymentProofService.onchainPaymentResolutionPublisher.receive(on: DispatchQueue.main)) { resolution in
            applyOnchainPaymentResolution(resolution)
        }
        .onReceive(OnchainSendAttemptService.cancellationReleasePublisher) { attemptId in
            // A refresh may already have dropped the released attempt, so the route's own context counts too.
            if [ordinaryPendingContext?.attemptId, onchainAttempt?.id].contains(attemptId) {
                sheets.hideSheet()
            }
        }
    }

    @MainActor
    private func beginRecovery(_ action: RecoveryAction) {
        guard let attempt = recoverableAttempt else { return }
        let feeRate = switch action {
        case .cancel: cancellation.suggestedFeeRate(cancelling: attempt, normalRate: normalFeeRate)
        case .speedUp: cancellation.suggestedSpeedUpRate(normalRate: normalFeeRate)
        case .retry, .retryWithoutChecking, .abandon: attempt.recoveryContext?.satsPerVbyte ?? 1
        }
        retryFeeRate = String(feeRate)
        feeEntryAction = action
    }

    private func feeEntryNote(for action: RecoveryAction) -> String {
        let variables = [
            "amount": CurrencyFormatter.formatSats(onchainAttempt?.amountSats ?? 0),
            "address": onchainAttempt?.address ?? "",
            "fee": String(onchainAttempt?.recoveryContext?.satsPerVbyte ?? 1),
        ]
        if action == .cancel {
            return t("wallet__onchain_cancel_note", variables: variables)
        }
        if action == .speedUp {
            let current = cancellation.heldFeeRate.map(String.init) ?? "?"
            return t("wallet__onchain_cancel_speed_up_note", variables: ["fee": current])
        }
        let note = t(onchainAttempt?.isMaxAmount == true ? "wallet__onchain_retry_max_note" : "wallet__onchain_retry_note", variables: variables)
        return action == .retryWithoutChecking ? t("wallet__onchain_resend_warning") + "\n\n" + note : note
    }

    @MainActor
    private func recover(_ action: RecoveryAction, feeRate: UInt32) async {
        switch action {
        case .retry: await retryOriginalPayment(feeRate: feeRate, reauthorize: true)
        case .retryWithoutChecking: await retryOriginalPayment(feeRate: feeRate, reauthorize: false)
        case .cancel: await cancelOriginalPayment(feeRate: feeRate)
        case .speedUp: await speedUpCancellation(feeRate: feeRate)
        // Prices its own release, so it never asks for a fee rate.
        case .abandon: await abandonExpiredPayment()
        }
    }

    @MainActor
    private func retryOriginalPayment(feeRate: UInt32, reauthorize: Bool) async {
        guard canRetryOriginal, !isRecoveryRunning, let original = recoverableAttempt else { return }
        retryingOnchain = true
        defer { retryingOnchain = false }
        let context = OnchainSendPendingContext(attemptId: original.id, walletId: original.walletId, txid: original.txid)
        do {
            // Blocktank no longer sells channels, so an unpaid order is never paid again.
            if original.orderId != nil {
                Logger.warn("Stopped a retry of a transfer to spending: transfers are unavailable", context: "SendPendingScreen")
                sheets.showSheet(.transferUnavailable)
                return
            }
            let feeLimits = await wallet.getFeeLimits()
            guard feeRate > 0, feeRate <= feeLimits.maxFee else {
                app.toast(type: .warning, title: t("wallet__onchain_retry_invalid_fee"))
                return
            }
            // Capture the original request deadline without mutating its proof before authentication.
            let paymentDeadline: PaykitPreciseInstant? = if reauthorize, original.requestId != nil {
                try await proofService.authorizeOnchainRecovery(original, restoreStartedProof: false).paymentDeadline
            } else {
                nil
            }
            let result = try await attemptService.retrySamePayment(
                using: LightningService.shared, context: context, satsPerVbyte: feeRate, paymentDeadline: paymentDeadline,
                approvePrepared: { try await approveRecoveryFee($0, original: original, action: reauthorize ? .retry : .retryWithoutChecking) },
                authorize: { attempt, _ in
                    try await authenticateSpend()
                    try await Self.authorizeOriginalRetry(
                        attempt,
                        reauthorize: reauthorize,
                        reauthorizeOriginal: { try await reauthorizeOriginal($0, paymentDeadline: paymentDeadline) },
                        authorizeUnchecked: { attempt in
                            // A request that cannot be read fresh is never re-sent unchecked.
                            guard await paymentRequests.refresh(forceFresh: true) else { throw PaykitPaymentRequestError.requestUnavailable }
                            try await proofService.authorizeUncheckedOnchainRecovery(attempt)
                        }
                    )
                }
            )
            let proofPriority: PaykitSdkOperationLock.Priority =
                if case .accepted = result, original.walletId == OnchainSendAttemptService.walletId(index: 0) {
                    .interactive
                } else {
                    .ordered
                }
            try await refreshOriginalOutcome(context: context, proofPriority: proofPriority)
        } catch is CancellationError {
            // A positive original observation may have won while authentication awaited.
            try? await refreshOriginalOutcome(context: context)
        } catch {
            try? await refreshOriginalOutcome(context: context)
            app.toast(error is NodeError ? OnchainSendAttemptError.retryUnavailable : error)
        }
    }

    @MainActor
    private func cancelOriginalPayment(feeRate: UInt32) async {
        guard canCancelOriginal, !isRecoveryRunning, let original = recoverableAttempt else { return }
        retryingOnchain = true
        defer { retryingOnchain = false }
        let context = OnchainSendPendingContext(attemptId: original.id, walletId: original.walletId, txid: original.txid)
        do {
            let feeLimits = await wallet.getFeeLimits()
            guard feeRate > 0, feeRate <= feeLimits.maxFee else {
                app.toast(type: .warning, title: t("wallet__onchain_retry_invalid_fee"))
                return
            }
            let result = try await attemptService.cancelOriginalPayment(
                using: LightningService.shared, context: context, satsPerVbyte: feeRate,
                approvePrepared: { try await approveRecoveryFee($0, original: original, action: .cancel) },
                authorize: { try await authenticateSpend() }
            )
            // A refused or unknown cancellation leaves the guard unchanged.
            if let failureMessage = cancellation.record(result, feeRate: feeRate, attempt: original) {
                app.toast(type: .error, title: t("common__error"), description: failureMessage)
            }
        } catch is CancellationError {
            // Declined before dispatch, so nothing was sent.
        } catch let error as OnchainCancellationFeeTooLowError {
            // The next Cancel payment suggests a rate that outbids what it replaces.
            cancellation.outbid(rate: error.feeRate)
            app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
        } catch {
            Logger.warn("The original on-chain payment was not cancelled: \(error)", context: "SendPendingScreen")
            // A cancellation the wallet now holds spends the same coins, so a new one cannot be built over them.
            await showKnownCancellation()
            app.toast(type: .error, title: t("common__error"), description: cancellation.failureMessage(for: original))
        }
        // A positive original observation may have won while the cancellation was prepared.
        try? await refreshOriginalOutcome(context: context)
    }

    @MainActor
    private func speedUpCancellation(feeRate: UInt32) async {
        guard canSpeedUpCancellation, !isRecoveryRunning, let original = recoverableAttempt else { return }
        retryingOnchain = true
        defer { retryingOnchain = false }
        let context = OnchainSendPendingContext(attemptId: original.id, walletId: original.walletId, txid: original.txid)
        do {
            let feeLimits = await wallet.getFeeLimits()
            guard feeRate > 0, feeRate <= feeLimits.maxFee else {
                app.toast(type: .warning, title: t("wallet__onchain_retry_invalid_fee"))
                return
            }
            _ = try await attemptService.speedUpCancellation(
                using: LightningService.shared, context: context, satsPerVbyte: feeRate, authorize: { try await authenticateSpend() }
            )
            cancellation.outbid(rate: feeRate)
        } catch is CancellationError {
            // Declined before dispatch, so nothing was sent.
        } catch let error as OnchainCancellationFeeTooLowError {
            cancellation.outbid(rate: error.feeRate)
            app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
        } catch let error as OnchainCancellationNotRecordedError {
            cancellation.outbid(rate: feeRate)
            app.toast(type: .warning, title: t("common__error"), description: error.localizedDescription)
        } catch {
            Logger.warn("The cancellation was not sped up: \(error)", context: "SendPendingScreen")
            app.toast(type: .error, title: t("common__error"), description: t("wallet__onchain_cancel_error"))
        }
        try? await refreshOriginalOutcome(context: context)
        await showKnownCancellation()
    }

    @MainActor
    private func approveRecoveryFee(_ prepared: PreparedOnchainSendDispatch, original: OnchainSendAttempt, action: RecoveryAction) async throws {
        guard let fee = prepared.miningFeeSats else { throw OnchainSendAttemptError.retryUnavailable }
        let feeTotal = t("wallet__send_fee_total", variables: ["feeSats": String(fee)])
        // A cancellation pays only this wallet, so its own address and dust output are not shown.
        let message = action == .cancel ? feeTotal : original.address + "\n" + CurrencyFormatter.formatSats(original.amountSats) + "\n" + feeTotal
        guard await requestRetryApproval(message, action: action) else { throw CancellationError() }
        if let usd = currency.convert(sats: fee, to: "USD"), usd.value > 10 {
            guard await requestRetryApproval(t("wallet__send_dialog4"), action: action) else { throw CancellationError() }
        }
        if fee > original.amountSats / 2 {
            guard await requestRetryApproval(t("wallet__send_dialog3"), action: action) else { throw CancellationError() }
        }
    }

    @MainActor
    private func authenticateSpend() async throws {
        guard settings.requirePinForPayments && settings.pinEnabled else { return }
        if settings.useBiometrics && BiometricAuth.isAvailable {
            isAuthenticatingRecovery = true
            defer { isAuthenticatingRecovery = false }
            guard case .success = await BiometricAuth.authenticate() else { throw CancellationError() }
        } else {
            guard await requestPinCheck() else { throw CancellationError() }
        }
    }

    @MainActor
    private func reauthorizeOriginal(_ attempt: OnchainSendAttempt, paymentDeadline: PaykitPreciseInstant?) async throws {
        guard attempt.requestId != nil else { return }
        let authorization = try await paymentRequests.ensureOnchainRecoveryAllowed(attempt, proofService: proofService)
        guard authorization.paymentDeadline == paymentDeadline,
              let payer = attempt.recoveryContext?.paymentIdentity else { throw PaykitPaymentRequestError.requestUnavailable }
        try await proofService.requireRecoveryPayer(payer)
    }

    /// Without `reauthorize`, the request's expiry and deadline are waived, but it is read fresh, and one its payee ended or
    /// that is already paid is never paid twice.
    static func authorizeOriginalRetry(
        _ attempt: OnchainSendAttempt,
        reauthorize: Bool,
        reauthorizeOriginal: (OnchainSendAttempt) async throws -> Void,
        authorizeUnchecked: (OnchainSendAttempt) async throws -> Void
    ) async throws {
        if reauthorize {
            try await reauthorizeOriginal(attempt)
        } else {
            try await authorizeUnchecked(attempt)
        }
    }

    /// Returns whether to check again later. Transfers do not come back once unavailable, so one check decides a
    /// Blocktank funding.
    @MainActor
    private func loadAbandonableAttempt() async -> Bool {
        guard let attempt = try? await attemptService.blockingAttempt(), attempt.canBeAbandoned else { return true }
        let hasEnded = await (try? proofService.onchainRequestHasEnded(attempt)) ?? false
        abandonableAttempt = hasEnded ? attempt : nil
        return !attempt.isBlocktankFunding
    }

    @MainActor
    private func abandonExpiredPayment() async {
        guard canAbandon, !isRecoveryRunning, let attempt = abandonableAttempt else { return }
        abandoningOnchain = true
        defer { abandoningOnchain = false }
        let context = OnchainSendPendingContext(attemptId: attempt.id, walletId: attempt.walletId, txid: attempt.txid)
        do {
            try await proofService.abandonUnbroadcastOnchainPayment(
                context: context,
                wallet: LightningService.shared,
                approveRelease: { prepared in
                    guard let fee = prepared.miningFeeSats else { throw OnchainSendAttemptError.retryUnavailable }
                    let message = t("wallet__onchain_abandon_release", variables: ["fee": CurrencyFormatter.formatSats(fee)])
                    guard await requestRetryApproval(message, action: .abandon) else { throw CancellationError() }
                    try await authenticateSpend()
                }
            )
        } catch is CancellationError {
            // Declined before dispatch, so nothing was sent.
        } catch {
            Logger.warn("Could not release on-chain payment \(attempt.txid ?? ""): \(error)", context: "SendPendingScreen")
            // Only a final cancellation or a wipe removes the guard, and a final cancellation closes this screen itself.
            if await isGuardReleased(context) {
                return
            }
            if case .releasePending = error as? OnchainSendAbandonError {
                app.toast(type: .info, title: t("wallet__onchain_abandon_pending"))
            } else {
                app.toast(error)
            }
        }
        // A release recorded, sent or found in the wallet holds the original like a sent cancellation.
        if let current = try? await attemptService.pendingAttempt(context: context) {
            abandonableAttempt = current
        }
        try? await refreshOriginalOutcome(context: context)
        await showKnownCancellation()
    }

    private func isGuardReleased(_ context: OnchainSendPendingContext) async -> Bool {
        do {
            return try await attemptService.pendingAttempt(context: context) == nil
        } catch {
            // A store that cannot be read proves nothing.
            return false
        }
    }

    @MainActor
    private func showKnownCancellation() async {
        guard let attempt = recoverableAttempt else { return }
        let sentAt = attempt.lastCancellationSentAt
        do {
            let walletCancellation = try await attemptService.cancellation(of: attempt, using: LightningService.shared)
            let latestSync = LightningService.shared.status?.latestOnchainWalletSyncTimestamp
            let syncedSinceSent = attempt.mayHaveRelayedCancellation && sentAt.map { sent in latestSync.map { $0 > sent } ?? false } == true
            cancellation.read(walletCancellation, syncedSinceSent: syncedSinceSent)
            if let walletCancellation {
                try? await attemptService.recordHeldCancellationFee(walletCancellation, attemptId: attempt.id)
            }
        } catch {
            // A read that fails proves nothing, so what is known stays as it is.
        }
    }

    @MainActor
    private func requestRetryApproval(_ message: String, action: RecoveryAction) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                retryApprovalContinuation = continuation
                retryApprovalAction = action
                retryApprovalMessage = message
            }
        } onCancel: {
            Task { @MainActor in finishRetryApproval(false) }
        }
    }

    private func finishRetryApproval(_ approved: Bool) {
        let continuation = retryApprovalContinuation
        retryApprovalContinuation = nil
        retryApprovalMessage = nil
        continuation?.resume(returning: approved)
    }

    @MainActor
    private func refreshOriginalOutcome(
        context: OnchainSendPendingContext, proofPriority: PaykitSdkOperationLock.Priority = .ordered
    ) async throws {
        onchainAttempt = try await attemptService.pendingAttempt(context: context)
        guard let original = onchainAttempt, original.status == .accepted, original.txid != nil else { return }
        if let requestId = original.requestId {
            if proofPriority == .ordered {
                await proofService.reconcile()
            }
            if let payer = original.recoveryContext?.paymentIdentity,
               let resolution = await proofService.resolvedOnchainPayment(
                   requestId: requestId, identity: payer, context: context, priority: proofPriority
               )
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
        guard !ordinarySendResolved, resolution.requestId == paykitPaymentRequestId,
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
                  hardwareTransactionId == nil || hardwareTransactionId?.caseInsensitiveCompare(resolution.transactionId) == .orderedSame,
                  let txid = pendingTransactionId,
                  txid.caseInsensitiveCompare(resolution.transactionId) == .orderedSame,
                  PubkyPublicKeyFormat.matches(resolution.identity, hardwarePaymentIdentity ?? pendingOnchainProof?.identity)
            else { return }
        }
        ordinarySendResolved = true
        app.prepareResolvedOnchainContactContext(resolution, isHardware: pendingHardwareWalletId != nil)
        navigationPath.append(.recoveredSuccess(paymentId: resolution.transactionId, walletId: resolution.walletId))
        Task {
            await proofService.consumeOnchainPaymentResolution(resolution, activeIdentity: pubkyProfile.publicKey)
        }
    }

    private var onchainPendingMessage: String {
        if onchainStateUnavailable {
            return t("wallet__onchain_state_unavailable")
        }
        if pendingHardwareWalletId != nil {
            return t("wallet__onchain_hardware_pending")
        }
        if ordinarySendResolved {
            return t("wallet__onchain_earlier_restored")
        }
        switch onchainAttempt?.status {
        case .rejected:
            return t("wallet__onchain_rejected_pending", variables: ["reason": onchainAttempt?.rejectionReason ?? ""])
        case .unknown, .pending:
            return t("wallet__onchain_unknown_pending")
        case .accepted:
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

    @MainActor
    private func refreshVisibleOrdinaryOutcome() async {
        guard paymentHash == nil, paykitPaymentRequestId == nil, pendingHardwareWalletId == nil,
              !ordinarySendResolved, !refreshingOrdinaryOutcome, let original = onchainAttempt,
              original.requestId == nil
        else { return }
        refreshingOrdinaryOutcome = true
        defer { refreshingOrdinaryOutcome = false }
        let context = ordinaryPendingContext ?? OnchainSendPendingContext(
            attemptId: original.id, walletId: original.walletId, txid: original.txid
        )
        do {
            // Recover a one-shot resolution missed while the visible sheet changed routes.
            // The existing path validates the original operation before reading durable Details.
            try await refreshOriginalOutcome(context: context)
        } catch {
            localFollowupUnavailable = true
        }
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
