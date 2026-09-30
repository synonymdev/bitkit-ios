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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__send_pending"), showBackButton: false)

            if let sendAmountSats = wallet.sendAmountSats {
                MoneyStack(sats: Int(sendAmountSats), showSymbol: true)
                    .padding(.bottom, 32)
            }

            if paymentHash == nil {
                BodyMText(onchainPendingMessage)
                if let txid = onchainAttempt?.txid {
                    BodySSBText("Transaction ID: \(txid)")
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
                do {
                    onchainAttempt = try await OnchainSendAttemptService.shared.unresolvedAttempt(
                        walletId: OnchainSendAttemptService.walletId(index: LightningService.shared.currentWalletIndex)
                    )
                } catch {
                    onchainStateUnavailable = true
                }
                if paykitPaymentRequestId == nil {
                    do {
                        if let resolution = try await OnchainSendAttemptService.shared.resumeAcceptedOrdinarySend(
                            walletId: OnchainSendAttemptService.walletId(index: LightningService.shared.currentWalletIndex)
                        ) {
                            applyOrdinarySendResolution(resolution)
                        }
                    } catch {
                        localFollowupUnavailable = true
                    }
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

    private var onchainPendingMessage: String {
        if onchainStateUnavailable {
            return "The on-chain payment state could not be read. Do not send another payment until it is checked."
        }
        switch onchainAttempt?.status {
        case .rejected:
            return "The backend rejected this transaction. It may still have reached the network. Do not send it again. \(onchainAttempt?.rejectionReason ?? "")"
        case .unknown, .pending:
            return "This transaction may have been sent. Its outcome is unknown. Do not send it again."
        case .accepted:
            if localFollowupUnavailable {
                return "This payment was sent, but its local details could not be restored. Do not send this payment again."
            }
            return "This payment was sent. Local follow-up is still pending. Do not send this payment again."
        case .none:
            return t("wallet__send_pending_note")
        }
    }

    private func applyOrdinarySendResolution(_ resolution: OnchainSendLocalResolution) {
        guard paymentHash == nil, paykitPaymentRequestId == nil, !ordinarySendResolved,
              resolution.walletId == OnchainSendAttemptService.walletId(index: LightningService.shared.currentWalletIndex),
              onchainAttempt == nil || onchainAttempt?.id == resolution.attemptId
        else { return }
        ordinarySendResolved = true
        wallet.sendAmountSats = resolution.amountSats
        app.selectedWalletToPayFrom = .onchain
        app.contactPaymentContext = resolution.contact.map { ContactPaymentContext(publicKey: $0) }
        navigationPath.append(.success(paymentId: resolution.txid))
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
