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

    var lspBalance: UInt64 {
        amountViewModel.amountSats
    }

    private var isValid: Bool {
        let isAboveMin = lspBalance >= transfer.transferValues.minLspBalance
        let isBelowMax = lspBalance <= transfer.transferValues.maxLspBalance
        return isAboveMin && isBelowMax
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("lightning__spending_advanced__title"), accentColor: .purpleAccent)
                    .fixedSize(horizontal: false, vertical: true)

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
                            clientBalance: order.clientBalanceSat,
                            lspBalance: lspBalance
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

            updateFeeEstimate()
        }
        .onChange(of: lspBalance) { _ in
            updateFeeEstimate()
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            NumberPadActionButton(text: t("common__min")) {
                amountViewModel.updateFromSats(transfer.transferValues.minLspBalance, currency: currency)
            }

            Spacer()

            NumberPadActionButton(text: t("common__default")) {
                amountViewModel.updateFromSats(transfer.transferValues.defaultLspBalance, currency: currency)
            }

            Spacer()

            NumberPadActionButton(text: t("common__max")) {
                amountViewModel.updateFromSats(transfer.transferValues.maxLspBalance, currency: currency)
            }
        }
    }

    private func updateFeeEstimate() {
        guard lspBalance > 0 else { return }

        Task {
            do {
                feeEstimate = nil
                let estimate = try await blocktank.estimateOrderFee(
                    clientBalance: order.clientBalanceSat,
                    lspBalance: lspBalance
                )
                feeEstimate = estimate.feeSat
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
