import BitkitCore
import SwiftUI

struct HwSendSignView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var tagManager: TagManager
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager

    @Binding var navigationPath: [SendRoute]
    let hwSend: HwSendCoordinator
    let prepareContactPayment: () async throws -> Void
    @State private var signingTask: Task<Void, Never>?
    @State private var passphraseTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: t("hardware__send_sign_title"),
                showBackButton: !hwSend.isSigning && !hwSend.isBroadcastUnresolved
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

                Image("trezor-card")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
                    .frame(maxWidth: .infinity)
                    .offset(y: 54)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                CustomButton(
                    title: t(hwSend.hasPendingBroadcast ? "common__retry" : "hardware__send_open_connect"),
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

    private var passphrasePromptBinding: Binding<Bool> {
        Binding(
            get: { hwSend.isPassphraseRequired },
            set: { if !$0 { dismissPassphrase() } }
        )
    }

    private func startSigning() {
        guard signingTask == nil else { return }
        signingTask = Task { @MainActor in
            defer { signingTask = nil }
            guard let invoice = app.scannedOnchainInvoice,
                  let amount = wallet.sendAmountSats,
                  let feeRate = wallet.selectedFeeRateSatsPerVByte,
                  let walletId = hwSend.walletId
            else {
                app.toast(type: .error, title: t("common__error"), description: t("other__try_again"))
                return
            }
            let contactPublicKey = app.contactPaymentContext?.publicKey

            do {
                let result = try await hwSend.signAndBroadcast(
                    manager: hwWalletManager,
                    address: invoice.address,
                    sats: amount,
                    satsPerVByte: UInt64(feeRate),
                    beforeBroadcast: prepareContactPayment
                )
                await recordSentPayment(
                    result,
                    walletId: walletId,
                    address: invoice.address,
                    amount: amount,
                    contactPublicKey: contactPublicKey
                )
                hwSend.completeBroadcast()
                navigationPath.append(.success(paymentId: result.txId, walletId: walletId))
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
        if error.isTrezorUserCancellation() {
            return
        }
        if error.isTrezorDeviceBusy() {
            app.toast(HwTransferError.deviceBusy)
        } else if error.isTrezorFirmwareError() {
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
