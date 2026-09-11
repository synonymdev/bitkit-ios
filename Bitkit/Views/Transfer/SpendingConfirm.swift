import BitkitCore
import LDKNode
import SwiftUI

struct SpendingConfirm: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    private var isPaying: Bool {
        transfer.isSpendingBusy
    }

    @State private var hideSwipeButton = false
    @State private var transactionFee: UInt64 = 0
    @State private var selectedUtxos: [SpendableUtxo]?
    @State private var satsPerVbyte: UInt32?
    @State private var maxSendableAmount: UInt64?
    @State private var shouldUseSendAll = false
    var lspFee: UInt64 {
        transfer.uiState.lspFeeSat
    }

    var total: UInt64 {
        transfer.uiState.feeSat + transactionFee
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .disabled(isPaying)
                .padding(.bottom, 16)

            DisplayText(t("lightning__transfer__confirm"), accentColor: .purpleAccent)

            VStack(spacing: 16) {
                HStack {
                    FeeDisplayRow(
                        label: t("lightning__spending_confirm__network_fee"),
                        amount: transactionFee
                    )
                    .frame(maxWidth: .infinity)

                    FeeDisplayRow(
                        label: t("lightning__spending_confirm__lsp_fee"),
                        amount: lspFee
                    )
                    .frame(maxWidth: .infinity)
                }

                HStack {
                    FeeDisplayRow(
                        label: t("lightning__spending_confirm__amount"),
                        amount: transfer.uiState.clientBalanceSat
                    )
                    .frame(maxWidth: .infinity)

                    FeeDisplayRow(
                        label: t("lightning__spending_confirm__total"),
                        amount: total
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 32)

            if transfer.uiState.isAdvanced {
                LightningChannel(
                    capacity: transfer.uiState.lspBalanceSat + transfer.uiState.clientBalanceSat,
                    localBalance: transfer.uiState.clientBalanceSat,
                    remoteBalance: transfer.uiState.lspBalanceSat,
                    status: .open,
                    showLabels: true
                )
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("SpendingConfirmChannel")
                .padding(.vertical, 16)
            }

            HStack(alignment: .center, spacing: 0) {
                BodyMText(t("lightning__spending_confirm__background_setup"), textColor: .textPrimary)

                Spacer()

                Toggle("", isOn: $settings.enableNotifications)
                    .toggleStyle(SwitchToggleStyle(tint: .purpleAccent))
                    .labelsHidden()
                    .accessibilityIdentifier("SpendingConfirmNotificationSwitch")
            }
            .frame(height: 50)

            Divider()
                .padding(.bottom, 16)

            HStack(spacing: 16) {
                CustomButton(title: t("common__learn_more"), size: .small) {
                    navigation.navigate(.transferLearnMore)
                }
                .accessibilityIdentifier("SpendingConfirmMore")

                if transfer.uiState.isAdvanced {
                    CustomButton(title: t("lightning__spending_confirm__default"), size: .small) {
                        do {
                            let values = transfer.calculateTransferValues(
                                clientBalanceSat: transfer.uiState.clientBalanceSat,
                                blocktankInfo: blocktank.info
                            )
                            try await transfer.onDefaultClick(lspBalance: max(values.defaultLspBalance, values.minLspBalance)) {
                                try await blocktank.estimateFundingAmount(clientBalance: $0, lspBalance: $1)
                            }
                        } catch {
                            app.toast(error)
                        }
                    }
                    .accessibilityIdentifier("SpendingConfirmDefault")
                } else {
                    CustomButton(title: t("common__advanced"), size: .small) {
                        navigation.navigate(.spendingAdvanced())
                    }
                    .accessibilityIdentifier("SpendingConfirmAdvanced")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isPaying)

            Spacer()

            if !hideSwipeButton {
                SwipeButton(
                    title: t("lightning__transfer__swipe"),
                    accentColor: .purpleAccent,
                    isLoading: isPaying
                ) {
                    try await onConfirm()
                }
                .disabled(isPaying || selectedUtxos == nil || transactionFee == 0 || satsPerVbyte == nil)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .offlineOverlay(title: t("lightning__transfer__nav_title"))
        .task(id: transfer.uiState.feeSat) {
            await sizeFunding()
        }
    }

    private func sizeFunding() async {
        do {
            let address: String = if let orderAddress = transfer.uiState.order?.payment?.onchain?.address {
                orderAddress
            } else {
                try await LightningService.shared.addressInfoForType(.nativeSegwit, atIndex: 0).address
            }
            try await calculateTransactionFee(address: address, amountSats: transfer.uiState.feeSat)
        } catch {
            app.toast(error)
        }
    }

    private func onConfirm() async throws {
        guard satsPerVbyte != nil, !transfer.isSpendingBusy else { return }
        transfer.uiState.isConfirming = true
        defer { transfer.uiState.isConfirming = false }

        do {
            let order = try await transfer.orderForConfirmation { clientBalance, lspBalance in
                try await blocktank.createOrder(clientBalance: clientBalance, lspBalance: lspBalance)
            }
            guard let address = order.payment?.onchain?.address else {
                throw AppError(message: "Order payment onchain address is nil", debugMessage: nil)
            }
            try await calculateTransactionFee(address: address, amountSats: order.feeSat)
            guard let rate = satsPerVbyte else { return }
            try await transfer.payOrder(
                order: order,
                speed: .fast,
                txFee: transactionFee,
                satsPerVbyte: rate,
                utxosToSpend: selectedUtxos,
                isMaxAmount: shouldUseSendAll,
                maxSendableAmount: maxSendableAmount
            )
            await wallet.updateBalanceState()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            navigation.navigate(.settingUp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                hideSwipeButton = true
            }
        } catch {
            app.toast(error)
            throw error
        }
    }

    private func calculateTransactionFee(address: String, amountSats: UInt64) async throws {
        do {
            let lightningService = LightningService.shared

            guard let feeEstimates = await feeEstimatesManager.getEstimates(refresh: true) else {
                Logger.error("SpendingConfirm: feeEstimates is nil")
                throw AppError(message: t("other__try_again"), debugMessage: nil)
            }

            let fastFeeRate = TransactionSpeed.fast.getFeeRate(from: feeEstimates)

            let balance = UInt64(wallet.spendableOnchainBalanceSats)
            let allUtxos = try await lightningService.listSpendableOutputs()

            var useSendAll = false
            var normalFee: UInt64 = 0
            var normalUtxos: [SpendableUtxo]?

            do {
                let utxos = try await lightningService.selectUtxosWithAlgorithm(
                    targetAmountSats: amountSats,
                    satsPerVbyte: fastFeeRate,
                    coinSelectionAlgorythm: .largestFirst,
                    utxos: nil
                )
                normalFee = try await wallet.calculateTotalFee(
                    address: address,
                    amountSats: amountSats,
                    satsPerVByte: fastFeeRate,
                    utxosToSpend: utxos
                )
                normalUtxos = utxos

                let totalInput = utxos.reduce(UInt64(0)) { $0 + $1.valueSats }
                useSendAll = DustChangeHelper.shouldUseSendAllToAvoidDust(
                    totalInput: totalInput,
                    amountSats: amountSats,
                    normalFee: normalFee,
                    isMaxAmount: true
                )
            } catch {
                Logger.info("Normal coin selection failed, using sendAll: \(error)")
                useSendAll = true
            }

            if useSendAll {
                let sendAllFee = try await wallet.estimateSendAllFee(
                    address: address,
                    satsPerVByte: fastFeeRate
                )
                let maxSendable = balance >= sendAllFee ? balance - sendAllFee : 0

                if maxSendable < amountSats {
                    Logger.error(
                        "Insufficient balance for transfer: maxSendable=\(maxSendable), orderFee=\(amountSats)",
                        context: "SpendingConfirm"
                    )
                    throw AppError(message: t("other__pay_insufficient_savings"), debugMessage: nil)
                }

                await MainActor.run {
                    transactionFee = sendAllFee
                    selectedUtxos = allUtxos
                    satsPerVbyte = fastFeeRate
                    maxSendableAmount = maxSendable
                    shouldUseSendAll = true
                }
            } else {
                await MainActor.run {
                    transactionFee = normalFee
                    selectedUtxos = normalUtxos
                    satsPerVbyte = fastFeeRate
                    shouldUseSendAll = false
                }
            }
        } catch {
            Logger.error("Failed to calculate actual fee: \(error)", context: "SpendingConfirm")
            await MainActor.run {
                transactionFee = 0
                selectedUtxos = nil
                satsPerVbyte = nil
                maxSendableAmount = nil
                shouldUseSendAll = false
            }
            throw error
        }
    }
}
