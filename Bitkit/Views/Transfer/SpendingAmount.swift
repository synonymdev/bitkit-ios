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
    @State private var maxSendableAmount: UInt64?
    @State private var maxTransferAmount: UInt64 = 0

    var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    // Calculate the maximum amount that can be transferred
    private var availableAmount: UInt64 {
        return maxSendableAmount ?? UInt64(wallet.spendableOnchainBalanceSats)
    }

    private var transferValues: TransferValues {
        transfer.calculateTransferValues(clientBalanceSat: amountSats, blocktankInfo: blocktank.info)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__spending_amount__title"), accentColor: .purpleAccent)

            NumberPadTextField(viewModel: amountViewModel, showConversion: false)
                .onTapGesture {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
                .padding(.top, 32)

            Spacer()

            HStack(alignment: .bottom) {
                AvailableAmount(label: t("wallet__send_available"), amount: Int(availableAmount))

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

            CustomButton(title: t("common__continue"), isLoading: isLoading) {
                Task {
                    await onContinue()
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await calculateMaxSendableAmount()
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
                let quarter = UInt64(wallet.spendableOnchainBalanceSats) / 4
                let amount = min(quarter, maxTransferAmount)
                amountViewModel.updateFromSats(amount, currency: currency)
            }

            NumberPadActionButton(text: t("common__max")) {
                amountViewModel.updateFromSats(maxTransferAmount, currency: currency)
            }
        }
    }

    private func onContinue() async {
        // TODO: check that we have enough onchain balance to cover the fee, see react native code

        isLoading = true

        do {
            let transferValues = transfer.calculateTransferValues(clientBalanceSat: amountSats, blocktankInfo: blocktank.info)
            let lspBalance = max(transferValues.defaultLspBalance, transferValues.minLspBalance)
            let order = try await blocktank.createOrder(clientBalance: amountSats, lspBalance: lspBalance)

            isLoading = false

            transfer.onOrderCreated(order: order)
            navigation.navigate(.spendingConfirm(order: order))
        } catch {
            app.toast(error)
            isLoading = false
        }
    }

    private func calculateMaxSendableAmount() async {
        let coreService = CoreService.shared
        let lightningService = LightningService.shared

        do {
            let address = try await lightningService.newAddress()

            if let feeRates = try await coreService.blocktank.fees(refresh: true) {
                let fastFeeRate = TransactionSpeed.fast.getFeeRate(from: feeRates)

                let maxAmount = try await wallet.calculateMaxSendableAmount(
                    address: address,
                    satsPerVByte: fastFeeRate
                )

                await MainActor.run {
                    maxSendableAmount = maxAmount
                }

                // Now calculate the max transfer amount using blocktank.estimateOrderFee
                await calculateMaxTransferAmount(availableAmount: maxAmount)
            }
        } catch {
            Logger.error("Failed to calculate max sendable amount: \(error)")
            await MainActor.run {
                // Fall back to total balance if calculation fails
                maxSendableAmount = UInt64(wallet.spendableOnchainBalanceSats)
                maxTransferAmount = 0
            }
        }
    }

    private func calculateMaxTransferAmount(availableAmount: UInt64) async {
        do {
            let transferValues = transfer.calculateTransferValues(clientBalanceSat: availableAmount, blocktankInfo: blocktank.info)

            let feeEstimate = try await blocktank.estimateOrderFee(
                clientBalance: availableAmount,
                lspBalance: transferValues.maxLspBalance
            )

            let feeMaximum = UInt64(max(0, Int64(availableAmount - feeEstimate.feeSat)))

            // Maximum is the minimum of max client balance and fee maximum
            let result = min(transferValues.maxClientBalance, feeMaximum)

            await MainActor.run {
                maxTransferAmount = result
            }

        } catch {
            Logger.error("Failed to calculate max transfer amount: \(error)")
            await MainActor.run {
                // Fall back to a simplified calculation
                let transferValues = transfer.calculateTransferValues(clientBalanceSat: availableAmount, blocktankInfo: blocktank.info)
                maxTransferAmount = min(transferValues.maxClientBalance, availableAmount)
            }
        }
    }
}
