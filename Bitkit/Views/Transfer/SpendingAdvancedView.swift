import BitkitCore
import SwiftUI

struct SpendingAdvancedView: View {
    let order: IBtOrder
    /// Set when the transfer is funded by a hardware wallet, so the capacity is priced against the
    /// device account instead of this wallet's savings.
    var walletId: String?

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(\.dismiss) var dismiss

    @State private var amountViewModel = AmountInputViewModel()
    @State private var feeEstimate: UInt64?
    @State private var isLoading = false
    @State private var feeEstimateTask: Task<Void, Never>?
    /// Reserved once and reused, so re-reading the budget on Continue doesn't burn a receive index.
    @State private var fundingAddress: String?

    var lspBalance: UInt64 {
        amountViewModel.amountSats
    }

    private var isValid: Bool {
        let values = transfer.transferValues
        guard !transfer.isSettlingAdvancedCapacity, lspBalance > 0, values.maxLspBalance > 0 else { return false }
        return lspBalance >= values.minLspBalance && lspBalance <= values.maxLspBalance
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("lightning__spending_advanced__title"), accentColor: .purpleAccent)
                    .fixedSize(horizontal: false, vertical: true)

                NumberPadTextField(
                    viewModel: amountViewModel,
                    showConversion: false,
                    testIdentifier: "SpendingAdvancedNumberField"
                )
                .onTapGesture {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
                .padding(.top, 32)

                // Fee estimate
                HStack(spacing: 4) {
                    CaptionMText(t("lightning__spending_advanced__fee"))

                    if let feeEstimate {
                        MoneyText(sats: Int(feeEstimate), size: .bodySSB, symbol: true)
                    } else {
                        CaptionMText("—")
                    }
                }
                .frame(height: 20)
                .padding(.top, 16)

                Spacer()

                // Action buttons
                HStack(alignment: .bottom) {
                    Spacer()

                    actionButtons
                }
                .padding(.vertical, 8)

                Divider()

                NumberPad(
                    type: amountViewModel.getNumberPadType(currency: currency),
                    errorKey: amountViewModel.errorKey,
                    isDisabled: transfer.isSettlingAdvancedCapacity
                ) { key in
                    amountViewModel.handleNumberPadInput(key, currency: currency)
                }

                CustomButton(
                    title: t("common__continue"),
                    isDisabled: !isValid,
                    isLoading: isLoading
                ) {
                    isLoading = true
                    defer { isLoading = false }

                    do {
                        let canFund = await transfer.canFundAdvancedOrder(
                            clientBalance: order.clientBalanceSat,
                            receivingAmount: lspBalance,
                            budget: fundingBudget(),
                            estimateOrderFee: estimateOrderFee
                        )
                        guard canFund else {
                            app.toast(
                                type: .warning,
                                title: t("lightning__spending_advanced__error_balance__title"),
                                description: t("lightning__spending_advanced__error_balance__description"),
                                visibilityTime: Toast.visibilityTimeShort
                            )
                            return
                        }

                        let newOrder = try await blocktank.createOrder(
                            clientBalance: order.clientBalanceSat,
                            lspBalance: lspBalance
                        )
                        transfer.onAdvancedOrderCreated(order: newOrder)
                        dismiss()
                    } catch {
                        app.toast(error)
                    }
                }
                .accessibilityIdentifier("SpendingAdvancedContinue")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await transfer.updateAdvancedTransferValues(
                clientBalanceSat: order.clientBalanceSat,
                budget: fundingBudget(),
                transferValues: { transfer.calculateTransferValues(clientBalanceSat: $0, blocktankInfo: blocktank.info) },
                estimateOrderFee: estimateOrderFee
            )

            updateFeeEstimate()
        }
        .onChange(of: lspBalance) {
            if isValid {
                updateFeeEstimate()
            } else {
                feeEstimate = nil
            }
        }
        .onChange(of: transfer.transferValues.maxLspBalance, initial: true) { updateInputCap() }
        .onChange(of: amountViewModel.maxExceededCount) { onMaxExceeded() }
    }

    private var estimateOrderFee: (UInt64, UInt64) async throws -> (networkFeeSat: UInt64, serviceFeeSat: UInt64) {
        { clientBalance, lspBalance in
            let estimate = try await blocktank.estimateOrderFee(clientBalance: clientBalance, lspBalance: lspBalance)
            return (estimate.networkFeeSat, estimate.serviceFeeSat)
        }
    }

    /// The budget this order has to fit under: the device account for a hardware transfer, this
    /// wallet's on-chain savings otherwise.
    private func fundingBudget() async -> UInt64? {
        if let walletId {
            return await transfer.hwFundingBudget(walletId: walletId)
        }

        do {
            let address: String
            if let fundingAddress {
                address = fundingAddress
            } else {
                address = try await TransferFundingBudget.reserveSizingAddress()
                fundingAddress = address
            }
            return await TransferFundingBudget.onchainBudget(
                address: address,
                feeEstimatesManager: feeEstimatesManager,
                wallet: wallet
            )
        } catch {
            Logger.warn("Failed to resolve advanced funding budget: \(error)", context: "SpendingAdvancedView")
            return nil
        }
    }

    private func updateInputCap() {
        let maxLspBalance = transfer.transferValues.maxLspBalance
        amountViewModel.maxAmountOverride = maxLspBalance > 0 ? maxLspBalance : nil

        // Settling the max can land it below what is already entered, so the amount comes down with
        // it rather than leaving a capacity that no longer exists selected.
        if maxLspBalance > 0, maxLspBalance < amountViewModel.amountSats {
            amountViewModel.updateFromSats(maxLspBalance, currency: currency)
        }
    }

    private func onMaxExceeded() {
        // Snap the input to the max so the user lands on the highest allowed amount.
        let maxLspBalance = transfer.transferValues.maxLspBalance
        if maxLspBalance > 0 {
            amountViewModel.updateFromSats(maxLspBalance, currency: currency)
        }
        showMaxExceededToast()
    }

    private func showMaxExceededToast() {
        app.toast(
            type: .warning,
            title: t("lightning__spending_advanced__error_max__title"),
            description: t(
                "lightning__spending_advanced__error_max__description",
                variables: ["amount": CurrencyFormatter.formatSats(transfer.transferValues.maxLspBalance)]
            ),
            visibilityTime: Toast.visibilityTimeShort
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            NumberPadActionButton(text: t("common__min")) {
                amountViewModel.updateFromSats(transfer.transferValues.minLspBalance, currency: currency)
            }
            .accessibilityIdentifier("SpendingAdvancedMin")

            Spacer()

            NumberPadActionButton(text: t("common__default")) {
                amountViewModel.updateFromSats(transfer.transferValues.defaultLspBalance, currency: currency)
            }
            .accessibilityIdentifier("SpendingAdvancedDefault")

            Spacer()

            NumberPadActionButton(text: t("common__max")) {
                amountViewModel.updateFromSats(transfer.transferValues.maxLspBalance, currency: currency)
            }
            .accessibilityIdentifier("SpendingAdvancedMax")
        }
    }

    private func updateFeeEstimate() {
        guard lspBalance > 0 else { return }

        feeEstimateTask?.cancel()
        feeEstimate = nil

        feeEstimateTask = Task {
            do {
                let estimate = try await blocktank.estimateOrderFee(
                    clientBalance: order.clientBalanceSat,
                    lspBalance: lspBalance
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    feeEstimate = estimate.feeSat
                }
            } catch {
                guard !Task.isCancelled else { return }
                Logger.debug("Fee estimation failed: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    NavigationStack {
        SpendingAdvancedView(
            order: IBtOrder.mock(lspBalanceSat: 100_000, clientBalanceSat: 50000)
        )
        .environmentObject(AppViewModel())
        .environmentObject(CurrencyViewModel())
        .environmentObject(BlocktankViewModel())
        .environmentObject(FeeEstimatesManager())
        .environmentObject(TransferViewModel())
        .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
