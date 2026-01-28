import SwiftUI

struct SpendingAmount: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @StateObject private var amountViewModel = AmountInputViewModel()
    @State private var isLoading = false
    @State private var availableAmount: UInt64?
    @State private var maxTransferAmount: UInt64?

    private var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    private var isValidAmount: Bool {
        guard let max = maxTransferAmount else { return false }
        return amountSats <= max
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
                if let available = availableAmount {
                    AvailableAmount(label: t("wallet__send_available"), amount: Int(available))
                } else {
                    HStack(spacing: 4) {
                        CaptionMText(t("wallet__send_available"))
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                Spacer()

                actionButtons
            }
            .padding(.bottom, 12)

            Divider()

            NumberPad(
                type: amountViewModel.getNumberPadType(currency: currency),
                errorKey: amountViewModel.errorKey
            ) { key in
                amountViewModel.handleNumberPadInput(key, currency: currency)
            }

            CustomButton(
                title: t("common__continue"),
                isDisabled: !isValidAmount,
                isLoading: isLoading
            ) {
                await onContinue()
            }
            .accessibilityIdentifier("SpendingAmountContinue")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task(id: blocktank.info?.options.maxChannelSizeSat) {
            await calculateMaxTransferAmount()
        }
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
                guard let max = maxTransferAmount else { return }
                let quarter = UInt64(wallet.spendableOnchainBalanceSats) / 4
                amountViewModel.updateFromSats(min(quarter, max), currency: currency)
            }
            .accessibilityIdentifier("SpendingAmountQuarter")

            NumberPadActionButton(text: t("common__max")) {
                guard let max = maxTransferAmount else { return }
                amountViewModel.updateFromSats(max, currency: currency)
            }
            .accessibilityIdentifier("SpendingAmountMax")
        }
    }

    private func onContinue() async {
        isLoading = true
        defer { isLoading = false }

        // Wait for node to be running if it's not already
        if wallet.nodeLifecycleState != .running {
            let isReady = await wallet.waitForNodeToRun(timeoutSeconds: 30.0)
            guard isReady else {
                app.toast(
                    type: .error,
                    title: "Lightning node not ready",
                    description: "Please wait for the Lightning node to start and try again."
                )
                return
            }
        }

        do {
            let values = transfer.calculateTransferValues(clientBalanceSat: amountSats, blocktankInfo: blocktank.info)
            let lspBalance = max(values.defaultLspBalance, values.minLspBalance)
            let order = try await blocktank.createOrder(clientBalance: amountSats, lspBalance: lspBalance)

            transfer.onOrderCreated(order: order)
            navigation.navigate(.spendingConfirm(order: order))
        } catch {
            app.toast(error)
        }
    }

    private func calculateMaxTransferAmount() async {
        guard let info = blocktank.info else {
            await MainActor.run {
                availableAmount = 0
                maxTransferAmount = 0
            }
            return
        }

        let coreService = CoreService.shared
        let lightningService = LightningService.shared

        do {
            let address = try await lightningService.newAddress()

            guard let feeRates = try await coreService.blocktank.fees(refresh: true) else {
                await MainActor.run {
                    let balance = UInt64(wallet.spendableOnchainBalanceSats)
                    availableAmount = balance
                    let values = transfer.calculateTransferValues(clientBalanceSat: balance, blocktankInfo: info)
                    maxTransferAmount = min(values.maxClientBalance, balance)
                }
                return
            }
            let fastFeeRate = TransactionSpeed.fast.getFeeRate(from: feeRates)

            let calculatedAvailableAmount = try await wallet.calculateMaxSendableAmount(
                address: address,
                satsPerVByte: fastFeeRate
            )

            let values = transfer.calculateTransferValues(clientBalanceSat: calculatedAvailableAmount, blocktankInfo: info)

            let feeEstimate = try await blocktank.estimateOrderFee(
                clientBalance: calculatedAvailableAmount,
                lspBalance: values.maxLspBalance
            )

            let feeMaximum = UInt64(max(0, Int64(calculatedAvailableAmount) - Int64(feeEstimate.feeSat)))
            let result = min(values.maxClientBalance, feeMaximum)

            await MainActor.run {
                availableAmount = calculatedAvailableAmount
                maxTransferAmount = result
            }
        } catch {
            Logger.error("Failed to calculate max transfer amount: \(error)")
            await MainActor.run {
                let balance = UInt64(wallet.spendableOnchainBalanceSats)
                availableAmount = balance
                let values = transfer.calculateTransferValues(clientBalanceSat: balance, blocktankInfo: info)
                maxTransferAmount = min(values.maxClientBalance, balance)
            }
        }
    }
}
