import BitkitCore
import SwiftUI

struct HwSendSignView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var tagManager: TagManager
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @Environment(HwWalletManager.self) private var hwWalletManager

    @Binding var navigationPath: [SendRoute]
    let hwSend: HwSendCoordinator
    let contactPaymentRequestId: PaykitPaymentRequest.ID?
    let contactPaymentIdentity: String?
    let contactPaymentDeadline: PaykitPreciseInstant?
    let prepareContactPayment: (HwFundingSignedTx) async throws -> Void
    let authorizeContactPayment: () async throws -> Void
    let completeContactPayment: (String) async -> Bool
    let cancelContactPayment: (PrivatePaymentListSendOutcome) async -> Void
    @State private var signingTask: Task<Void, Never>?
    @State private var passphraseTask: Task<Void, Never>?
    @State private var observedResolution: PaykitOnchainPaymentResolution?
    @State private var appliedResolution = false

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
                    isDisabled: hwSend.isSigning,
                    isLoading: hwSend.isSigning
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
        .onReceive(PaykitPaymentProofService.onchainPaymentResolutionPublisher.receive(on: DispatchQueue.main)) { resolution in
            guard resolution.requestId == contactPaymentRequestId,
                  resolution.walletId == hwSend.walletId,
                  PubkyPublicKeyFormat.matches(resolution.identity, contactPaymentIdentity)
            else { return }
            observedResolution = resolution
            applyObservedResolution()
        }
        .onChange(of: app.paykitOnchainPaymentResolution, initial: true) { _, resolution in
            guard let resolution,
                  resolution.requestId == contactPaymentRequestId,
                  resolution.walletId == hwSend.walletId,
                  PubkyPublicKeyFormat.matches(resolution.identity, contactPaymentIdentity)
            else { return }
            observedResolution = resolution
            applyObservedResolution()
        }
        .onChange(of: hwSend.isSigning) { _, isSigning in
            if !isSigning {
                applyObservedResolution()
            }
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

    private func applyObservedResolution() {
        guard !appliedResolution, let resolution = observedResolution,
              let route = hwSend.resolveObservedShopPayment(
                  resolution, paymentIdentity: contactPaymentIdentity, currentIdentity: pubkyProfile.publicKey
              )
        else { return }
        appliedResolution = true
        app.prepareResolvedOnchainContactContext(resolution, isHardware: true)
        app.consumePaykitOnchainPaymentResolution(resolution)
        navigationPath.append(route)
        Task { await PaykitPaymentProofService.shared.consumeOnchainPaymentResolution(resolution, activeIdentity: pubkyProfile.publicKey) }
    }

    private func startSigning() {
        guard signingTask == nil else { return }
        signingTask = Task { @MainActor in
            let paymentActivity = PaykitPaymentActivity.shared.begin()
            defer {
                PaykitPaymentActivity.shared.end(paymentActivity)
                signingTask = nil
            }
            guard let invoice = app.scannedOnchainInvoice,
                  let amount = wallet.sendAmountSats,
                  let feeRate = wallet.selectedFeeRateSatsPerVByte,
                  let walletId = hwSend.walletId
            else {
                app.toast(type: .error, title: t("common__error"), description: t("other__try_again"))
                return
            }
            let contactPublicKey = app.contactPaymentContext?.publicKey
            let requestId = contactPaymentRequestId
            let tags = tagManager.selectedTagsArray

            do {
                var proofVerified = requestId == nil
                let result = try await PaykitPaymentProofService.shared.withHardwarePaymentOwnership(walletId: walletId) {
                    try await hwSend.signAndBroadcast(
                        manager: hwWalletManager,
                        address: invoice.address,
                        sats: amount,
                        satsPerVByte: UInt64(feeRate),
                        paymentDeadline: contactPaymentDeadline,
                        paymentRequestId: requestId,
                        loadSignedPayment: {
                            guard let requestId else { return nil }
                            guard let identity = contactPaymentIdentity else { throw PaykitPaymentRequestError.requestUnavailable }
                            return try await PaykitPaymentProofService.shared.retainedHardwareOnchainPayment(
                                requestId: requestId, paymentIdentity: identity, walletId: walletId,
                                address: invoice.address, amountSats: amount
                            )
                        },
                        beforeFirstBroadcast: prepareContactPayment,
                        beforeBroadcastAttempt: authorizeContactPayment,
                        retainSignedPayment: { signed in
                            guard let requestId else { return }
                            guard let identity = contactPaymentIdentity else { throw PaykitPaymentRequestError.requestUnavailable }
                            try await PaykitPaymentProofService.shared.retainHardwareOnchainCandidate(
                                requestId: requestId, paymentIdentity: identity, walletId: walletId,
                                address: invoice.address, amountSats: amount, serializedTx: signed.serializedTx
                            )
                        },
                        markSignedPaymentRefused: { signed, refused in
                            guard let requestId else { return }
                            guard let identity = contactPaymentIdentity else { throw PaykitPaymentRequestError.requestUnavailable }
                            try await PaykitPaymentProofService.shared.markHardwareCandidateRefused(
                                requestId: requestId, paymentIdentity: identity, walletId: walletId,
                                serializedTx: signed.serializedTx, refused: refused
                            )
                        },
                        clearSignedPaymentBeforeDispatch: { signed in
                            guard let requestId else { return true }
                            guard let identity = contactPaymentIdentity else { return false }
                            return await PaykitPaymentProofService.shared.clearHardwareCandidateBeforeDispatch(
                                requestId: requestId, paymentIdentity: identity, walletId: walletId, serializedTx: signed.serializedTx
                            )
                        },
                        afterBroadcast: { result in
                            if requestId != nil {
                                // Save original tags before proof reconciliation can complete.
                                // This retains metadata only; a bare Core txid is not Sent.
                                await Self.recordPaymentResult(
                                    result, walletId: walletId, address: invoice.address, amount: amount,
                                    contactPublicKey: contactPublicKey, tags: tags, requestId: requestId,
                                    proofVerified: false
                                )
                            }
                            proofVerified = await completeContactPayment(result.txId)
                        },
                        afterFailure: cancelContactPayment
                    )
                }
                await Self.recordPaymentResult(
                    result,
                    walletId: walletId,
                    address: invoice.address,
                    amount: amount,
                    contactPublicKey: contactPublicKey,
                    tags: tags,
                    requestId: requestId,
                    proofVerified: proofVerified
                )
                guard !appliedResolution else { return }
                hwSend.completeBroadcast()
                let completionRoute = await hwSend.completionRoute(
                    result: result, walletId: walletId, requestId: requestId, paymentIdentity: contactPaymentIdentity,
                    completeContactPayment: { _ in
                        proofVerified && (requestId == nil || PubkyPublicKeyFormat.matches(pubkyProfile.publicKey, contactPaymentIdentity))
                    }
                )
                navigationPath.append(completionRoute)
            } catch is CancellationError {
                return
            } catch is HwPassphraseError {
                hwSend.requestPassphrase()
            } catch let error as HwTransferError {
                app.toast(error)
            } catch {
                showHardwareError(error)
            }
        }
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

    static func recordPaymentResult(
        _ result: HwFundingBroadcastResult,
        walletId: String,
        address: String,
        amount: UInt64,
        contactPublicKey: String?,
        tags: [String],
        requestId: PaykitPaymentRequest.ID?,
        proofVerified: Bool
    ) async {
        let metadata = PreActivityMetadata(
            walletId: walletId,
            paymentId: result.txId,
            tags: tags,
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

        // Retain original metadata for an eventual exact observation. A Shop payment's
        // local Core txid alone must not create a Sent row.
        guard requestId == nil || proofVerified else { return }
        await CoreService.shared.activity.createSentOnchainActivityFromSendResult(
            txid: result.txId,
            address: address,
            amount: amount,
            fee: result.miningFeeSats,
            feeRate: UInt32(clamping: result.feeRate),
            contact: contactPublicKey,
            walletId: walletId
        )
        if !tags.isEmpty {
            try? await CoreService.shared.activity.appendTags(
                toActivity: result.txId,
                tags,
                walletId: walletId
            )
        }

        Logger.info("Hardware onchain send result txid: \(result.txId)")
    }
}
