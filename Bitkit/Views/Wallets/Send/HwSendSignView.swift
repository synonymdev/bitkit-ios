import BitkitCore
import SwiftUI

struct HwSendSignView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var tagManager: TagManager
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager

    @Binding var navigationPath: [SendRoute]
    let hwSend: HwSendCoordinator
    let prepareContactPayment: (ContactPaymentContext?) async throws -> Void
    let authorizeContactPayment: (ContactPaymentContext?) async throws -> Void
    let completeContactPayment: (ContactPaymentContext?, String) async -> Void
    let cancelContactPayment: (ContactPaymentContext?, PrivatePaymentListSendOutcome) async -> Void
    @State private var signingTask: Task<Void, Never>?
    @State private var signingAttempt = 0
    @State private var isCompletingPayment = false
    @State private var passphraseTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: t("hardware__send_sign_title"),
                showBackButton: hwSend.canLeave
            )

            if let invoice = app.scannedOnchainInvoice {
                MoneyStack(
                    sats: Int(wallet.sendAmountSats ?? invoice.amountSatoshis),
                    showSymbol: true,
                    testIdPrefix: "HardwareSendSignAmount"
                )

                CaptionMText(t("hardware__send_confirm_address"))
                    .padding(.top, 40)

                BodySSBText(invoice.address)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                Divider()
                    .padding(.top, 16)

                Spacer(minLength: 16)

                Image(vendor.signImageName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
                    .frame(maxWidth: .infinity)
                    .offset(y: 54)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                CustomButton(
                    title: hwSend.hasPendingBroadcast ? t("common__retry") : vendor.sendSignButtonTitle,
                    isDisabled: hwSend.isSigning || isCompletingPayment,
                    isLoading: hwSend.isSigning || isCompletingPayment
                ) {
                    startSigning()
                }
                .accessibilityIdentifier("HardwareSendOpenTrezorConnect")
            }
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .sheetBackground()
        .sheet(isPresented: passphrasePromptBinding) {
            HwPassphrasePromptSheet(
                isVerifying: hwSend.isVerifyingPassphrase,
                onSubmit: reconnectWithPassphrase,
                onCancel: dismissPassphrase
            )
        }
        .onChange(of: app.paykitOnchainPaymentResolution, initial: true) { _, resolution in
            resolvePayment(resolution)
        }
        .onDisappear {
            guard !hwSend.isBroadcastUnresolved else { return }
            signingTask?.cancel()
            signingTask = nil
            passphraseTask?.cancel()
            passphraseTask = nil
            hwSend.cancel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HardwareSendSign")
    }

    private var vendor: HwWalletVendor {
        hwWalletManager.wallets.first { $0.id == hwSend.walletId }?.vendor ?? .trezor
    }

    private var passphrasePromptBinding: Binding<Bool> {
        Binding(
            get: { hwSend.isPassphraseRequired },
            set: {
                if !$0 {
                    dismissPassphrase()
                }
            }
        )
    }

    private func startSigning() {
        guard signingTask == nil, !isCompletingPayment else { return }
        signingAttempt += 1
        let attempt = signingAttempt
        signingTask = Task { @MainActor in
            defer { if signingAttempt == attempt { signingTask = nil } }
            guard let invoice = app.scannedOnchainInvoice,
                  let amount = wallet.sendAmountSats,
                  let feeRate = wallet.selectedFeeRateSatsPerVByte,
                  let walletId = hwSend.walletId
            else {
                app.toast(type: .error, title: t("common__error"), description: t("other__try_again"))
                return
            }
            let contactPaymentContext = app.contactPaymentContext
            let paymentActivity = PaykitPaymentActivity.shared.begin()
            defer { PaykitPaymentActivity.shared.end(paymentActivity) }

            do {
                let result = try await hwSend.signAndBroadcast(
                    manager: hwWalletManager,
                    address: invoice.address,
                    sats: amount,
                    satsPerVByte: UInt64(feeRate),
                    paymentDeadline: contactPaymentContext?.incomingPaymentRequest?.paymentDeadline,
                    paykitRequestId: contactPaymentContext?.incomingPaymentRequest?.id,
                    paykitIdentity: pubkyProfile.publicKey,
                    beforeFirstBroadcast: { try await prepareContactPayment(contactPaymentContext) },
                    beforeBroadcastAttempt: { try await authorizeContactPayment(contactPaymentContext) },
                    afterBroadcast: { result in
                        await completeContactPayment(contactPaymentContext, result.txId)
                    },
                    afterFailure: { outcome in
                        await cancelContactPayment(contactPaymentContext, outcome)
                    }
                )
                guard signingAttempt == attempt, !Task.isCancelled else { return }
                await finishPayment(
                    result,
                    walletId: walletId,
                    address: invoice.address,
                    amount: amount,
                    context: contactPaymentContext
                )
            } catch is CancellationError {
                return
            } catch {
                guard signingAttempt == attempt, !Task.isCancelled else { return }
                if error is HwPassphraseError {
                    hwSend.requestPassphrase()
                } else if let error = error as? HwTransferError {
                    app.toast(error)
                } else {
                    showHardwareError(error)
                }
            }
        }
    }

    private func resolvePayment(_ resolution: PaykitOnchainPaymentResolution?) {
        guard !isCompletingPayment, let resolution,
              let context = app.contactPaymentContext,
              context.incomingPaymentRequest?.id == resolution.requestId,
              let invoice = app.scannedOnchainInvoice,
              let amount = wallet.sendAmountSats,
              let walletId = hwSend.walletId,
              let result = hwSend.resolvePayment(resolution, identity: pubkyProfile.publicKey, walletId: walletId)
        else { return }

        signingTask?.cancel()
        signingAttempt += 1
        let attempt = signingAttempt
        isCompletingPayment = true
        signingTask = Task { @MainActor in
            defer {
                if signingAttempt == attempt {
                    signingTask = nil
                    isCompletingPayment = false
                }
            }
            await completeContactPayment(context, result.txId)
            guard !Task.isCancelled else { return }
            await finishPayment(result, walletId: walletId, address: invoice.address, amount: amount, context: context)
        }
    }

    private func finishPayment(
        _ result: HwFundingBroadcastResult,
        walletId: String,
        address: String,
        amount: UInt64,
        context: ContactPaymentContext?
    ) async {
        isCompletingPayment = true
        defer { isCompletingPayment = false }
        await recordSentPayment(result, walletId: walletId, address: address, amount: amount, contactPublicKey: context?.publicKey)
        guard !Task.isCancelled else { return }
        hwSend.completeBroadcast()
        if let resolution = app.paykitOnchainPaymentResolution,
           resolution.requestId == context?.incomingPaymentRequest?.id,
           resolution.transactionId == result.txId,
           resolution.walletId == walletId,
           PubkyPublicKeyFormat.matches(resolution.identity, pubkyProfile.publicKey)
        {
            app.consumePaykitOnchainPaymentResolution(resolution)
        }
        navigationPath.append(.success(paymentId: result.txId, walletId: walletId))
    }

    private func reconnectWithPassphrase(_ passphrase: String) {
        guard passphraseTask == nil else { return }
        passphraseTask = Task { @MainActor in
            defer { passphraseTask = nil }
            do {
                try await hwSend.reconnectWithPassphrase(passphrase, manager: hwWalletManager)
                startSigning()
            } catch is CancellationError {
                return
            } catch HwPassphraseError.mismatch {
                app.toast(HwTransferError.passphraseMismatch)
            } catch {
                showHardwareError(error)
            }
        }
    }

    private func dismissPassphrase() {
        passphraseTask?.cancel()
        passphraseTask = nil
        hwSend.dismissPassphrase()
    }

    private func showHardwareError(_ error: Error) {
        if error.isHwUserCancellation() {
            return
        }
        if error is HwWalletMismatchError {
            app.toast(HwTransferError.walletMismatch)
        } else if let vendor = error.hwBusyVendor {
            app.toast(HwTransferError.deviceBusy(vendor))
        } else if error.isHwFirmwareError() {
            app.toast(HwTransferError.firmwareReconnect)
        } else if hwSend.hasPendingBroadcast, error.isBroadcastConnectivityFailure() {
            app.toast(HwTransferError.broadcastConnectivity)
        } else {
            app.toast(error)
        }
    }

    private func recordSentPayment(
        _ result: HwFundingBroadcastResult,
        walletId: String,
        address: String,
        amount: UInt64,
        contactPublicKey: String?
    ) async {
        let metadata = PreActivityMetadata(
            walletId: walletId,
            paymentId: result.txId,
            tags: tagManager.selectedTagsArray,
            paymentHash: nil,
            txId: result.txId,
            address: address,
            isReceive: false,
            feeRate: result.feeRate,
            isTransfer: false,
            channelId: nil,
            createdAt: UInt64(Date().timeIntervalSince1970)
        )
        try? await CoreService.shared.activity.addPreActivityMetadata(metadata)

        await CoreService.shared.activity.createSentOnchainActivityFromSendResult(
            txid: result.txId,
            address: address,
            amount: amount,
            fee: result.miningFeeSats,
            feeRate: UInt32(clamping: result.feeRate),
            contact: contactPublicKey,
            walletId: walletId
        )
        if !tagManager.selectedTagsArray.isEmpty {
            try? await CoreService.shared.activity.appendTags(
                toActivity: result.txId,
                tagManager.selectedTagsArray,
                walletId: walletId
            )
        }

        Logger.info("Hardware onchain send result txid: \(result.txId)")
    }
}
