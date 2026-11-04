import SwiftUI

/// Sign a transfer to spending on the paired hardware wallet: the device pays the Spark deposit address, then the
/// setting-up screen claims the deposit at the chosen speed.
struct SpendingHwSign: View {
    let walletId: String

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager
    @Environment(SparkTransferFlow.self) private var flow

    @State private var signingTask: Task<Void, Never>?
    @State private var passphraseTask: Task<Void, Never>?

    private var hwSend: HwSendCoordinator {
        flow.hwSend
    }

    private struct QuoteInputs: Equatable {
        let amountSats: UInt64
        let speed: SparkTransferSpeed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .disabled(!hwSend.canLeave)
                .padding(.bottom, 16)

            DisplayText(
                t(hwSend.hasPendingBroadcast ? "lightning__transfer_hw__signed_title" : "lightning__transfer_hw__sign_title"),
                accentColor: .purpleAccent
            )

            SpendingConfirmFees(quote: flow.quote, speed: flow.speed, isLoading: flow.quote == nil && flow.quoteError == nil)
                .padding(.top, 16)

            if let error = flow.quoteError {
                BodyMText(error, textColor: .redAccent)
                    .padding(.bottom, 16)
            }

            SpendingSpeedPicker(quote: flow.quote, speed: Bindable(flow).speed)
                .disabled(isBusy || hwSend.hasPendingBroadcast)
                .padding(.horizontal, -16)
                .padding(.bottom, 16)

            CustomButton(title: t("common__learn_more"), size: .small, isDisabled: isBusy || hwSend.hasPendingBroadcast) {
                navigation.navigate(.transferLearnMore)
            }
            .accessibilityIdentifier("HardwareTransferSignLearnMore")

            Spacer(minLength: 16)

            Image(vendor.signImageName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 200, maxHeight: 200)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Spacer(minLength: 16)

            CustomButton(
                title: hwSend.hasPendingBroadcast ? t("common__retry") : vendor.sendSignButtonTitle,
                isDisabled: isBusy || flow.quote == nil,
                isLoading: isBusy
            ) {
                startSigning()
            }
            .accessibilityIdentifier("HardwareTransferOpenTrezorConnect")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HardwareTransferSign")
        .navigationBarHidden(true)
        .allowSwipeBack(hwSend.canLeave)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .offlineOverlay(title: t("lightning__transfer__nav_title"))
        .task(id: QuoteInputs(amountSats: flow.amountSats, speed: flow.speed)) {
            guard !SparkTransferFlow.isRunningInPreview, !hwSend.hasPendingBroadcast else { return }
            hwWalletManager.warmUpConnection(walletId: walletId)
            await flow.refreshQuote(wallet: wallet, feeEstimatesManager: feeEstimatesManager, hwWalletManager: hwWalletManager)
        }
        .sheet(isPresented: passphrasePromptBinding) {
            HwPassphrasePromptSheet(
                isVerifying: hwSend.isVerifyingPassphrase,
                onSubmit: reconnectWithPassphrase,
                onCancel: dismissPassphrase
            )
        }
        .onDisappear {
            let stillInFlow = navigation.path.contains {
                if case .spendingHwSign = $0 {
                    return true
                }
                return false
            }
            guard !stillInFlow, !hwSend.isBroadcastUnresolved else { return }
            signingTask?.cancel()
            signingTask = nil
            passphraseTask?.cancel()
            passphraseTask = nil
            hwSend.cancel()
        }
    }

    private var isBusy: Bool {
        hwSend.isSigning || flow.isQuoting
    }

    private var vendor: HwWalletVendor {
        hwWalletManager.wallets.first { $0.id == walletId }?.vendor ?? .trezor
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
        guard signingTask == nil else { return }
        signingTask = Task { @MainActor in
            defer { signingTask = nil }
            guard let quote = await quoteToSign() else { return }
            do {
                let result = try await PaykitPaymentProofService.shared.withHardwarePaymentOwnership(walletId: walletId) {
                    try await hwSend.signAndBroadcast(
                        manager: hwWalletManager,
                        address: quote.address,
                        sats: quote.depositSats,
                        satsPerVByte: UInt64(quote.satsPerVbyte)
                    )
                }
                await CoreService.shared.activity.createSentOnchainActivityFromSendResult(
                    txid: result.txId,
                    address: quote.address,
                    amount: quote.depositSats,
                    fee: result.miningFeeSats,
                    feeRate: UInt32(clamping: result.feeRate),
                    isTransfer: true,
                    walletId: walletId
                )
                hwSend.completeBroadcast()
                SparkManager.shared.onDepositBroadcast(txid: result.txId, amountSats: quote.depositSats)
                flow.onBroadcast(txid: result.txId)
                Logger.info("Funded Spark wallet with \(quote.depositSats) sats from hardware wallet in \(result.txId)", context: "SpendingHwSign")
                navigation.navigate(.spendingHwSigned)
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

    /// A fresh quote to sign with, or nil when it failed or the fees went up since the screen showed them. A retry of a
    /// signed transaction keeps the quote it was signed with.
    private func quoteToSign() async -> SparkTransferQuote? {
        guard let shown = flow.quote else { return nil }
        if hwSend.hasPendingBroadcast {
            return shown
        }
        guard let fresh = await flow.refreshQuote(wallet: wallet, feeEstimatesManager: feeEstimatesManager, hwWalletManager: hwWalletManager)
        else { return nil }
        let speed = flow.speed
        let shownCost = shown.networkFeeSats.saturatingAdd(shown.claimFeeSats(for: speed))
        let freshCost = fresh.networkFeeSats.saturatingAdd(fresh.claimFeeSats(for: speed))
        guard freshCost <= shownCost else {
            app.toast(
                type: .info,
                title: t("lightning__spending_confirm__fees_changed_title"),
                description: t(
                    "lightning__spending_confirm__fees_changed_network",
                    variables: ["amount": currency.primaryAmountText(sats: freshCost - shownCost)]
                )
            )
            return nil
        }
        return fresh
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
}
