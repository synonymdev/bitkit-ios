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

struct OnchainBroadcastPendingScreen: View {
    let txid: Txid
    let amountSats: UInt64?
    let onAccepted: (Txid) async -> Void
    let onAbandoned: () async -> Void

    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var isResolving = false
    @State private var hasResolved = false
    @State private var activeTxid: Txid

    init(
        txid: Txid,
        amountSats: UInt64?,
        onAccepted: @escaping (Txid) async -> Void,
        onAbandoned: @escaping () async -> Void
    ) {
        self.txid = txid
        self.amountSats = amountSats
        self.onAccepted = onAccepted
        self.onAbandoned = onAbandoned
        _activeTxid = State(initialValue: txid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__send_pending"), showBackButton: false)
                .accessibilityIdentifier("OnchainBroadcastPending")

            if let amountSats {
                MoneyStack(sats: Int(amountSats), showSymbol: true)
                    .padding(.bottom, 32)
            }

            BodyMText(t("wallet__send_pending_note"))
                .accessibilityIdentifier("OnchainBroadcastPendingMessage")

            Spacer()

            HourglassLoadingView()

            Spacer()

            HStack(spacing: 16) {
                CustomButton(title: t("common__close"), variant: .secondary, isDisabled: isResolving) {
                    sheets.hideSheet()
                }
                .accessibilityIdentifier("OnchainBroadcastPendingClose")

                CustomButton(title: t("common__retry"), isLoading: isResolving) {
                    Task { await rebroadcast() }
                }
                .accessibilityIdentifier("OnchainBroadcastPendingRetry")
            }
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await reconcile()
        }
    }

    @MainActor
    private func reconcile() async {
        guard !isResolving, !hasResolved else { return }
        isResolving = true
        defer { isResolving = false }

        do {
            try await wallet.sync()
        } catch {
            Logger.warn("On-chain pending reconciliation sync failed: \(error)", context: "OnchainBroadcastPendingScreen")
        }

        do {
            try await applyBroadcastOutcome()
        } catch {
            Logger.warn("Failed to reconcile on-chain broadcast outcome: \(error)", context: "OnchainBroadcastPendingScreen")
        }
    }

    @MainActor
    private func rebroadcast() async {
        guard !isResolving, !hasResolved else { return }
        isResolving = true
        defer { isResolving = false }

        do {
            let acceptedTxid = try await wallet.rebroadcastOnchainTransaction(txid: activeTxid)
            await accept(acceptedTxid)
        } catch {
            do {
                try await applyBroadcastOutcome()
            } catch {
                Logger.warn("Failed to reconcile on-chain rebroadcast error: \(error)", context: "OnchainBroadcastPendingScreen")
            }
            guard !hasResolved else { return }
            app.toast(error)
        }
    }

    @MainActor
    private func applyBroadcastOutcome() async throws {
        guard let outcome = try await wallet.onchainBroadcastOutcome(txid: txid) else { return }

        switch outcome.status {
        case .pending:
            activeTxid = outcome.txid
        case .accepted:
            await accept(outcome.txid)
        case .abandoned:
            await abandon()
        }
    }

    @MainActor
    private func accept(_ acceptedTxid: Txid) async {
        guard !hasResolved else { return }
        hasResolved = true
        await onAccepted(acceptedTxid)
    }

    @MainActor
    private func abandon() async {
        guard !hasResolved else { return }
        hasResolved = true
        await onAbandoned()
    }
}

struct SendPendingScreen: View {
    let paymentHash: String?
    let retryRoute: SendRetryRoute
    let paymentRequest: String?
    let paykitPaymentRequestId: PaykitPaymentRequest.ID?
    let routingCacheResetAttempted: Bool
    @Binding var navigationPath: [SendRoute]

    @EnvironmentObject private var activityList: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var foundActivity: Activity?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__send_pending"), showBackButton: false)

            if let sendAmountSats = wallet.sendAmountSats {
                MoneyStack(sats: Int(sendAmountSats), showSymbol: true)
                    .padding(.bottom, 32)
            }

            BodyMText(t("wallet__send_pending_note"))

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
            applyPendingResolutionIfNeeded(app.sendSheetPendingResolution)
            await searchForActivity()
        }
        .onChange(of: app.sendSheetPendingResolution) { _, resolution in
            applyPendingResolutionIfNeeded(resolution)
        }
        .onReceive(PaykitPaymentProofService.onchainPaymentResolutionPublisher) { resolution in
            guard resolution.requestId == paykitPaymentRequestId,
                  let identity = pubkyProfile.publicKey,
                  PubkyPublicKeyFormat.matches(resolution.identity, identity)
            else { return }
            app.addPendingContactPaymentContext(
                resolution.transactionId,
                context: ContactPaymentContext(publicKey: resolution.requestId.counterparty)
            )
            Task {
                await PaykitPaymentProofService.shared.consumeOnchainPaymentResolution(resolution)
                navigationPath.append(.success(paymentId: resolution.transactionId))
            }
        }
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
