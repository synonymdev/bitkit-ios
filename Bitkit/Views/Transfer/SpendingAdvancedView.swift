import BitkitCore
import SwiftUI

struct SpendingAdvancedView: View {
    let order: IBtOrder

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @Environment(\.dismiss) var dismiss

    @StateObject private var amountViewModel = AmountInputViewModel()
    @State private var feeEstimate: UInt64?
    @State private var isLoading = false
    @State private var feeEstimateTask: Task<Void, Never>?

    var lspBalance: UInt64 {
        amountViewModel.amountSats
    }

    private var isValid: Bool {
        let values = transfer.transferValues
        guard lspBalance > 0, values.maxLspBalance > 0 else { return false }
        return lspBalance >= values.minLspBalance && lspBalance <= values.maxLspBalance
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
                    isDisabled: !isValid,
                    isLoading: isLoading
                ) {
                    isLoading = true
                    defer { isLoading = false }

                    do {
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
            transfer.updateTransferValues(
                clientBalanceSat: order.clientBalanceSat,
                blocktankInfo: blocktank.info
            )

            updateFeeEstimate()
        }
        .onChange(of: lspBalance) { _ in
            if isValid {
                updateFeeEstimate()
            } else {
                feeEstimate = nil
            }
        }
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
        .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}
