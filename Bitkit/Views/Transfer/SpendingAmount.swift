import SwiftUI

struct SpendingAmount: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(SparkTransferFlow.self) private var flow

    @State private var amountViewModel = AmountInputViewModel()
    @State private var isCalculatingMax = true
    @State private var maxTransferAmount: UInt64?
    @State private var maxAttempt = 0

    private var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    private var isValidAmount: Bool {
        guard let max = maxTransferAmount else { return false }
        return amountSats > 0 && amountSats <= max
    }

    /// Inputs the max depends on: a new balance or a retry restarts the calculation.
    private struct MaxCalcInputs: Equatable {
        let spendableOnchainBalanceSats: Int
        let attempt: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__spending_amount__title"), accentColor: .purpleAccent)
                .fixedSize(horizontal: false, vertical: true)

            NumberPadTextField(
                viewModel: amountViewModel,
                showConversion: false,
                testIdentifier: "SpendingAmountNumberField"
            )
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
                isDisabled: isCalculatingMax || maxTransferAmount == nil
            ) { key in
                amountViewModel.handleNumberPadInput(key, currency: currency)
            }

            CustomButton(
                title: t("common__continue"),
                isDisabled: !isValidAmount
            ) {
                onContinue()
            }
            .accessibilityIdentifier("SpendingAmountContinue")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SpendingAmount")
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .offlineOverlay(title: t("lightning__transfer__nav_title"))
        .task(id: MaxCalcInputs(spendableOnchainBalanceSats: wallet.spendableOnchainBalanceSats, attempt: maxAttempt)) {
            isCalculatingMax = true
            await calculateMaxTransferAmount()
            if !Task.isCancelled {
                isCalculatingMax = false
            }
        }
        .onChange(of: maxTransferAmount) { updateInputCap() }
        .onChange(of: amountViewModel.maxExceededCount) { onMaxExceeded() }
    }

    @ViewBuilder
    private var availableAmount: some View {
        if isCalculatingMax {
            HStack(spacing: 4) {
                CaptionMText(t("wallet__send_available"))
                ProgressView()
                    .scaleEffect(0.7)
            }
        } else if let max = maxTransferAmount {
            AvailableAmount(
                label: t("wallet__send_available"),
                amount: Int(max),
                testIdentifier: "SpendingAmountAvailable"
            )
        } else {
            Button {
                maxAttempt += 1
            } label: {
                CaptionMText(t("lightning__spending_amount__error_fee"), textColor: .redAccent)
                    .multilineTextAlignment(.leading)
            }
            .accessibilityIdentifier("SpendingAmountRetry")
        }
    }

    private func updateInputCap() {
        amountViewModel.maxAmountOverride = maxTransferAmount
    }

    private func onMaxExceeded() {
        if let max = maxTransferAmount {
            amountViewModel.updateFromSats(max, currency: currency)
        }
        app.toast(
            type: .warning,
            title: t("lightning__spending_amount__error_max__title"),
            description: t(
                "lightning__spending_amount__error_max__description",
                variables: ["amount": CurrencyFormatter.formatSats(maxTransferAmount ?? 0)]
            ),
            visibilityTime: Toast.visibilityTimeShort,
            accessibilityIdentifier: "SpendingAmountExceededToast"
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
                guard let cap = maxTransferAmount else { return }
                let quarter = UInt64(max(0, wallet.spendableOnchainBalanceSats)) / 4
                amountViewModel.updateFromSats(min(quarter, cap), currency: currency)
            }
            .disabled(maxTransferAmount == nil)
            .accessibilityIdentifier("SpendingAmountQuarter")

            NumberPadActionButton(text: t("common__max")) {
                guard let max = maxTransferAmount else { return }
                amountViewModel.updateFromSats(max, currency: currency)
            }
            .disabled(maxTransferAmount == nil)
            .accessibilityIdentifier("SpendingAmountMax")
        }
    }

    private func onContinue() {
        guard let max = maxTransferAmount, isValidAmount else { return }
        flow.start(amountSats: amountSats, isMaxAmount: amountSats >= max)
        navigation.navigate(.spendingConfirm)
    }

    /// The most savings can send to the Spark deposit address after the fast-rate network fee for sending all of it.
    private func calculateMaxTransferAmount() async {
        guard wallet.spendableOnchainBalanceSats > 0 else {
            maxTransferAmount = 0
            return
        }
        do {
            let address = try await SparkManager.shared.depositAddress()
            guard let feeRates = await feeEstimatesManager.getEstimates(refresh: false) else {
                throw AppError(message: t("lightning__spending_amount__error_fee"), debugMessage: "No fee estimates")
            }
            let rate = TransactionSpeed.fast.getFeeRate(from: feeRates)
            let max = try await wallet.calculateMaxSendableAmount(address: address, satsPerVByte: rate)
            guard !Task.isCancelled else { return }
            maxTransferAmount = max
        } catch {
            Logger.warn("Failed to estimate the most a transfer to spending can send: \(error)", context: "SpendingAmount")
            guard !Task.isCancelled else { return }
            maxTransferAmount = nil
        }
    }
}

#Preview {
    NavigationStack {
        SpendingAmount()
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(FeeEstimatesManager())
            .environmentObject(NavigationViewModel())
            .environmentObject(WalletViewModel())
            .environment(SparkTransferFlow())
    }
    .preferredColorScheme(.dark)
}
