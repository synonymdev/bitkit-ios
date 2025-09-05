import BitkitCore
import SwiftUI

struct SpendingAdvancedView: View {
    let order: IBtOrder

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(\.dismiss) var dismiss

    @StateObject private var amountViewModel = AmountInputViewModel()
    @State private var feeEstimate: UInt64?

    var receivingAmountSats: UInt64 {
        amountViewModel.amountSats
    }

    private var isValid: Bool {
        let isAboveMin = receivingAmountSats >= transfer.transferValues.minLspBalance
        let isBelowMax = receivingAmountSats <= transfer.transferValues.maxLspBalance

        let result = isAboveMin && isBelowMax
        // Logger.debug("isValid computed - receivingAmountSats: \(receivingAmountSats)")
        // Logger.debug("Min LSP balance: \(transfer.transferValues.minLspBalance)")
        // Logger.debug("Max LSP balance: \(transfer.transferValues.maxLspBalance)")
        // Logger.debug("Is above min? \(isAboveMin), Is below max? \(isBelowMax)")
        // Logger.debug("defaultLspBalance: \(transfer.transferValues.defaultLspBalance)")
        // Logger.debug("isValid result: \(result)")

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("lightning__spending_advanced__title"), accentColor: .purpleAccent)

                NumberPadTextField(viewModel: amountViewModel, showConversion: false)
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
                    errorKey: amountViewModel.errorKey
                ) { key in
                    amountViewModel.handleNumberPadInput(key, currency: currency)
                }

                CustomButton(
                    title: t("common__continue"),
                    isDisabled: !isValid
                ) {
                    do {
                        // Create a new order with the specified receiving capacity
                        let newOrder = try await blocktank.createOrder(
                            spendingBalanceSats: order.clientBalanceSat,
                            receivingBalanceSats: receivingAmountSats
                        )

                        transfer.onAdvancedOrderCreated(order: newOrder)
                        dismiss()
                    } catch {
                        app.toast(error)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            transfer.updateTransferValues(
                clientBalanceSat: order.clientBalanceSat,
                blocktankInfo: blocktank.info
            )

            // Set initial receiving capacity to the default LSP balance
            amountViewModel.updateFromSats(transfer.transferValues.defaultLspBalance, currency: currency)
            updateFeeEstimate()
        }
        .onChange(of: receivingAmountSats) { _ in
            updateFeeEstimate()
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            NumberPadActionButton(text: t("common__min")) {
                Logger.debug("Min button pressed, setting to: \(transfer.transferValues.minLspBalance)")
                amountViewModel.updateFromSats(transfer.transferValues.minLspBalance, currency: currency)
            }

            Spacer()

            NumberPadActionButton(text: t("common__default")) {
                Logger.debug("Default button pressed, setting to: \(transfer.transferValues.defaultLspBalance)")
                amountViewModel.updateFromSats(transfer.transferValues.defaultLspBalance, currency: currency)
            }

            Spacer()

            NumberPadActionButton(text: t("common__max")) {
                Logger.debug("Max button pressed, setting to: \(transfer.transferValues.maxLspBalance)")
                amountViewModel.updateFromSats(transfer.transferValues.maxLspBalance, currency: currency)
            }
        }
    }

    private func updateFeeEstimate() {
        Logger.debug("Starting fee estimate update for receivingAmountSats: \(receivingAmountSats)")
        Task {
            do {
                feeEstimate = nil
                let estimate = try await blocktank.estimateOrderFee(
                    spendingBalanceSats: order.clientBalanceSat,
                    receivingBalanceSats: receivingAmountSats
                )
                feeEstimate = estimate.feeSat
                Logger.debug("Fee estimate updated successfully: \(estimate.feeSat)")
            } catch {
                feeEstimate = nil
                Logger.error("Failed to estimate fee: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    NavigationStack {
        SpendingAdvancedView(
            order: IBtOrder.mock(lspBalanceSat: 100_000, clientBalanceSat: 50000)
        )
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(CurrencyViewModel())
        .environmentObject(BlocktankViewModel())
        .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}
