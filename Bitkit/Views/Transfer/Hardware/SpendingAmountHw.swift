import SwiftUI

/// Amount entry for a transfer to spending funded from a paired hardware wallet. Mirrors `SpendingAmount`, but the
/// available/MAX/quarter limits come from the device's balance, and Continue advances to the on-device Sign step.
struct SpendingAmountHw: View {
    let walletId: String

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager
    @Environment(SparkTransferFlow.self) private var flow

    @State private var amountViewModel = AmountInputViewModel()
    @State private var isPricingFailed = false
    @State private var maxAttempt = 0

    private var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    private var isLoading: Bool {
        flow.hwSend.isFundingSourceLoading && !isPricingFailed
    }

    private var maxAllowed: UInt64 {
        flow.hwSend.availableSats
    }

    private var isValidAmount: Bool {
        !isLoading && !isPricingFailed && amountSats > 0 && amountSats <= maxAllowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__spending_amount__title"), accentColor: .purpleAccent)
                .fixedSize(horizontal: false, vertical: true)

            NumberPadTextField(viewModel: amountViewModel, showConversion: false)
                .onTapGesture {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
                .padding(.top, 32)

            Spacer()

            HStack(alignment: .bottom) {
                availableAmount

                Spacer()

                actionButtons
            }
            .padding(.bottom, 12)

            Divider()

            NumberPad(
                type: amountViewModel.getNumberPadType(currency: currency),
                errorKey: amountViewModel.errorKey,
                isDisabled: isLoading || isPricingFailed
            ) { key in
                amountViewModel.handleNumberPadInput(key, currency: currency)
            }

            CustomButton(title: t("common__continue"), isDisabled: !isValidAmount) {
                flow.start(amountSats: amountSats, isMaxAmount: amountSats >= maxAllowed, walletId: walletId)
                navigation.navigate(.spendingHwSign(walletId: walletId))
            }
            .accessibilityIdentifier("HardwareTransferAmountContinue")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HardwareTransferAmount")
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .offlineOverlay(title: t("lightning__transfer__nav_title"))
        .onAppear { flow.beginIfBroadcast() }
        .task(id: maxAttempt) {
            await loadAvailable()
        }
        .onChange(of: maxAllowed, initial: true) { updateInputCap() }
        .onChange(of: isLoading) { updateInputCap() }
        .onChange(of: amountViewModel.maxExceededCount) { onMaxExceeded() }
    }

    @ViewBuilder
    private var availableAmount: some View {
        if isLoading {
            HStack(spacing: 4) {
                CaptionMText(t("wallet__send_available"))
                ProgressView()
                    .scaleEffect(0.7)
            }
        } else if isPricingFailed {
            Button {
                maxAttempt += 1
            } label: {
                CaptionMText(t("lightning__spending_amount__error_fee"), textColor: .redAccent)
                    .multilineTextAlignment(.leading)
            }
            .accessibilityIdentifier("HardwareTransferAmountRetry")
        } else {
            AvailableAmount(
                label: t("wallet__send_available"),
                amount: Int(maxAllowed),
                testIdentifier: "HardwareTransferAmountAvailable"
            )
        }
    }

    private func loadAvailable() async {
        isPricingFailed = false
        flow.hwSend.selectWallet(walletId, initialAvailableSats: 0, showsLoading: true)
        do {
            let address = try await SparkManager.shared.depositAddress()
            guard let feeRates = await feeEstimatesManager.getEstimates(refresh: false) else {
                throw AppError(message: t("lightning__spending_amount__error_fee"), debugMessage: "No fee estimates")
            }
            let rate = TransactionSpeed.fast.getFeeRate(from: feeRates)
            await flow.hwSend.refreshAvailable(manager: hwWalletManager, destinationAddress: address, satsPerVByte: UInt64(rate))
            isPricingFailed = false
        } catch {
            Logger.warn("Failed to estimate the most a hardware transfer to spending can send: \(error)", context: "SpendingAmountHw")
            isPricingFailed = true
        }
    }

    private func updateInputCap() {
        guard !isLoading else { return }
        amountViewModel.maxAmountOverride = maxAllowed
    }

    private func onMaxExceeded() {
        amountViewModel.updateFromSats(maxAllowed, currency: currency)
        app.toast(
            type: .warning,
            title: t("lightning__spending_amount__error_max__title"),
            description: t(
                "lightning__spending_amount__error_max__description",
                variables: ["amount": CurrencyFormatter.formatSats(maxAllowed)]
            ),
            visibilityTime: Toast.visibilityTimeShort,
            accessibilityIdentifier: "HardwareTransferAmountExceededToast"
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            NumberPadActionButton(
                text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                imageName: "arrow-up-down"
            ) {
                withAnimation {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
            }

            NumberPadActionButton(text: t("lightning__spending_amount__quarter")) {
                let quarter = hwWalletManager.fundingBalance(walletId: walletId) / 4
                amountViewModel.updateFromSats(min(quarter, maxAllowed), currency: currency)
            }
            .disabled(isLoading || isPricingFailed)
            .accessibilityIdentifier("HardwareTransferAmountQuarter")

            NumberPadActionButton(text: t("common__max")) {
                amountViewModel.updateFromSats(maxAllowed, currency: currency)
            }
            .disabled(isLoading || isPricingFailed)
            .accessibilityIdentifier("HardwareTransferAmountMax")
        }
    }
}
