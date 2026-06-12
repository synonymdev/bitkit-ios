import BitkitCore
import LDKNode
import SwiftUI

struct SpendingAmount: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var amountViewModel = AmountInputViewModel()
    @State private var isLoading = false
    @State private var isCalculatingMax = true
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
                errorKey: amountViewModel.errorKey,
                isDisabled: isCalculatingMax
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
        .offlineOverlay(title: t("lightning__transfer__nav_title"))
        .task(id: blocktank.info?.options.maxChannelSizeSat) {
            await reloadMaxTransferAmount()
        }
        .onChange(of: wallet.spendableOnchainBalanceSats) {
            Task {
                await reloadMaxTransferAmount()
            }
        }
        .onChange(of: maxTransferAmount) { updateInputCap() }
        .onChange(of: amountViewModel.maxExceededCount) { onMaxExceeded() }
    }

    private func updateInputCap() {
        amountViewModel.maxAmountOverride = (maxTransferAmount ?? 0) > 0 ? maxTransferAmount : nil
    }

    private func onMaxExceeded() {
        // Snap the input to the max so the user lands on the highest allowed amount.
        if let max = maxTransferAmount {
            amountViewModel.updateFromSats(max, currency: currency)
        }
        showMaxExceededToast()
    }

    private func showMaxExceededToast() {
        app.toast(
            type: .warning,
            title: t("lightning__spending_amount__error_max__title"),
            description: t(
                "lightning__spending_amount__error_max__description",
                variables: ["amount": CurrencyFormatter.formatSats(maxTransferAmount ?? 0)]
            ),
            visibilityTime: Toast.visibilityTimeShort
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
                guard let max = maxTransferAmount else { return }
                amountViewModel.updateFromSats(max / 4, currency: currency)
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
            let appError = AppError(error: error)
            app.toast(type: .error, title: appError.message, description: appError.debugMessage)
        }
    }

    /// Toggles the loading flag (which disables the number pad) around the max calculation.
    private func reloadMaxTransferAmount() async {
        await MainActor.run { isCalculatingMax = true }
        await calculateMaxTransferAmount()
        await MainActor.run { isCalculatingMax = false }
    }

    private func calculateMaxTransferAmount() async {
        guard let info = blocktank.info else {
            await MainActor.run {
                availableAmount = 0
                maxTransferAmount = 0
            }
            return
        }

        do {
            let addressType = LDKNode.AddressType.fromStorage(UserDefaults.standard.string(forKey: "selectedAddressType"))
            let address = try await PrivatePaykitAddressReservationStore.shared.nextNonReservedReceiveAddress(addressType: addressType)

            guard let feeEstimates = await feeEstimatesManager.getEstimates(refresh: true) else {
                await MainActor.run {
                    let fallback = fallbackMaxTransferAmount(info: info)
                    availableAmount = fallback
                    maxTransferAmount = fallback
                }
                return
            }
            let fastFeeRate = TransactionSpeed.fast.getFeeRate(from: feeEstimates)

            // Calculate max sendable amount (balance minus transaction fee)
            let calculatedAvailableAmount = try await wallet.calculateMaxSendableAmount(
                address: address,
                satsPerVByte: fastFeeRate
            )

            let (available, maxAmount) = try await transfer.calculateSpendingLimits(
                onchainAvailable: calculatedAvailableAmount,
                lspMaxClientBalance: info.options.maxClientBalanceSat,
                transferValues: { transfer.calculateTransferValues(clientBalanceSat: $0, blocktankInfo: info) },
                estimateOrderFee: { clientBalance, lspBalance in
                    let estimate = try await blocktank.estimateOrderFee(clientBalance: clientBalance, lspBalance: lspBalance)
                    return (estimate.networkFeeSat, estimate.serviceFeeSat)
                }
            )

            await MainActor.run {
                // "Available" intentionally equals the transferable max so it matches the MAX button.
                availableAmount = available
                maxTransferAmount = maxAmount
            }
        } catch {
            Logger.error("Failed to calculate max transfer amount: \(error)")
            await MainActor.run {
                let fallback = fallbackMaxTransferAmount(info: info)
                availableAmount = fallback
                maxTransferAmount = fallback
            }
        }
    }

    /// Fallback max when fee estimates are unavailable: clamp the client balance to the LSP's max
    /// client balance so the liquidity calculation doesn't collapse to zero on a saturating balance.
    private func fallbackMaxTransferAmount(info: IBtInfo) -> UInt64 {
        let balance = UInt64(wallet.spendableOnchainBalanceSats)
        let lspMaxClientBalance = info.options.maxClientBalanceSat
        let clientBalance = lspMaxClientBalance > 0 ? min(balance, lspMaxClientBalance) : balance
        let values = transfer.calculateTransferValues(clientBalanceSat: clientBalance, blocktankInfo: info)
        return min(values.maxClientBalance, balance)
    }
}
