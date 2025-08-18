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

    @State private var receivingSatsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var feeEstimate: UInt64?

    private var isValid: Bool {
        let isAboveMin = receivingSatsAmount >= transfer.transferValues.minLspBalance
        let isBelowMax = receivingSatsAmount <= transfer.transferValues.maxLspBalance

        let result = isAboveMin && isBelowMax
        // Logger.debug("isValid computed - receivingSatsAmount: \(receivingSatsAmount)")
        // Logger.debug("Min LSP balance: \(transfer.transferValues.minLspBalance)")
        // Logger.debug("Max LSP balance: \(transfer.transferValues.maxLspBalance)")
        // Logger.debug("Is above min? \(isAboveMin), Is below max? \(isBelowMax)")
        // Logger.debug("defaultLspBalance: \(transfer.transferValues.defaultLspBalance)")
        // Logger.debug("isValid result: \(result)")

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(localizedString("lightning__spending_advanced__title"), accentColor: .purpleAccent)

                // Receiving capacity input
                AmountInput(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats) { newSats in
                    receivingSatsAmount = newSats
                    overrideSats = nil
                    updateFeeEstimate()
                }
                .padding(.vertical, 8)

                // Fee estimate
                HStack(spacing: 4) {
                    CaptionMText(localizedString("lightning__spending_advanced__fee"))

                    if let feeEstimate {
                        MoneyText(sats: Int(feeEstimate), size: .bodySSB, symbol: true)
                    } else {
                        CaptionMText("—")
                    }
                }
                .frame(height: 20)
                .padding(.bottom, 8)

                Spacer()

                // Action buttons
                HStack(alignment: .bottom) {
                    Spacer()

                    actionButtons
                }
                .padding(.vertical, 8)
            }

            Divider()

            Spacer()

            CustomButton(
                title: localizedString("common__continue"),
                isDisabled: !isValid
            ) {
                do {
                    // Create a new order with the specified receiving capacity
                    let newOrder = try await blocktank.createOrder(
                        spendingBalanceSats: order.clientBalanceSat,
                        receivingBalanceSats: receivingSatsAmount
                    )

                    transfer.onAdvancedOrderCreated(order: newOrder)
                    dismiss()
                } catch {
                    app.toast(error)
                }
            }
            .padding(.vertical, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(localizedString("lightning__transfer__nav_title"))
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            transfer.updateTransferValues(
                clientBalanceSat: order.clientBalanceSat,
                blocktankInfo: blocktank.info
            )

            // Set initial receiving capacity to the default LSP balance
            receivingSatsAmount = transfer.transferValues.defaultLspBalance
            overrideSats = transfer.transferValues.defaultLspBalance
            updateFeeEstimate()
        }
        .onChange(of: receivingSatsAmount) { _ in
            updateFeeEstimate()
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            NumberPadActionButton(text: localizedString("common__min")) {
                Logger.debug("Min button pressed, setting to: \(transfer.transferValues.minLspBalance)")
                overrideSats = transfer.transferValues.minLspBalance
            }

            Spacer()

            NumberPadActionButton(text: localizedString("common__default")) {
                Logger.debug("Default button pressed, setting to: \(transfer.transferValues.defaultLspBalance)")
                overrideSats = transfer.transferValues.defaultLspBalance
            }

            Spacer()

            NumberPadActionButton(text: localizedString("common__max")) {
                Logger.debug("Max button pressed, setting to: \(transfer.transferValues.maxLspBalance)")
                overrideSats = transfer.transferValues.maxLspBalance
            }
        }
    }

    private func updateFeeEstimate() {
        Logger.debug("Starting fee estimate update for receivingSatsAmount: \(receivingSatsAmount)")
        Task {
            do {
                feeEstimate = nil
                let estimate = try await blocktank.estimateOrderFee(
                    spendingBalanceSats: order.clientBalanceSat,
                    receivingBalanceSats: receivingSatsAmount
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
