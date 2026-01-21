import BitkitCore
import LDKNode
import SwiftUI

struct SpendingConfirm: View {
    let order: IBtOrder

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var isPaying = false
    @State private var hideSwipeButton = false
    @State private var transactionFee: UInt64 = 0
    @State private var selectedUtxos: [SpendableUtxo]?
    @State private var satsPerVbyte: UInt32?

    private var currentOrder: IBtOrder {
        transfer.displayOrder(for: order)
    }

    var lspFee: UInt64 {
        currentOrder.feeSat - currentOrder.clientBalanceSat
    }

    var total: UInt64 {
        currentOrder.feeSat + transactionFee
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
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
                        amount: currentOrder.clientBalanceSat
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
                    capacity: currentOrder.lspBalanceSat + currentOrder.clientBalanceSat,
                    localBalance: currentOrder.clientBalanceSat,
                    remoteBalance: currentOrder.lspBalanceSat,
                    status: .open,
                    showLabels: true
                )
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("SpendingConfirmChannel")
                .padding(.vertical, 16)
            }

            HStack(alignment: .center, spacing: 0) {
                BodyMText(tTodo("Set up in background"), textColor: .textPrimary)

                Spacer()

                Toggle("", isOn: $settings.enableNotifications)
                    .toggleStyle(SwitchToggleStyle(tint: .purpleAccent))
                    .labelsHidden()
            }
            .frame(height: 50)

            Divider()
                .padding(.bottom, 16)

            HStack(spacing: 16) {
                CustomButton(title: t("common__learn_more"), size: .small) {
                    navigation.navigate(.transferLearnMore(order: currentOrder))
                }
                .accessibilityIdentifier("SpendingConfirmMore")

                if transfer.uiState.isAdvanced {
                    CustomButton(title: t("lightning__spending_confirm__default"), size: .small) {
                        transfer.onDefaultClick()
                    }
                    .accessibilityIdentifier("SpendingConfirmDefault")
                } else {
                    CustomButton(title: t("common__advanced"), size: .small) {
                        navigation.navigate(.spendingAdvanced(order: currentOrder))
                    }
                    .accessibilityIdentifier("SpendingConfirmAdvanced")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            if !hideSwipeButton {
                SwipeButton(title: t("lightning__transfer__swipe"), accentColor: .purpleAccent) {
                    Task {
                        await onConfirm()
                    }
                }
                .disabled(isPaying || selectedUtxos == nil || transactionFee == 0 || satsPerVbyte == nil)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await calculateTransactionFee()
        }
    }

    private func onConfirm() async {
        isPaying = true

        do {
            try await transfer.payOrder(
                order: currentOrder,
                speed: .fast,
                txFee: transactionFee,
                utxosToSpend: selectedUtxos,
                satsPerVbyte: satsPerVbyte
            )
            await wallet.updateBalanceState()

            try await Task.sleep(nanoseconds: 1_000_000_000)

            navigation.navigate(.settingUp)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                hideSwipeButton = true
            }
        } catch {
            app.toast(error)
            isPaying = false
        }

        isPaying = false
    }

    private func calculateTransactionFee() async {
        do {
            let coreService = CoreService.shared
            let lightningService = LightningService.shared

            if let feeRates = try await coreService.blocktank.fees(refresh: true) {
                let fastFeeRate = TransactionSpeed.fast.getFeeRate(from: feeRates)

                guard let address = currentOrder.payment?.onchain?.address else {
                    throw AppError(message: "Order payment onchain address is nil", debugMessage: nil)
                }

                // Pre-select UTXOs to ensure same fee is used in send
                let utxos = try await lightningService.selectUtxosWithAlgorithm(
                    targetAmountSats: currentOrder.feeSat,
                    satsPerVbyte: fastFeeRate,
                    coinSelectionAlgorythm: .largestFirst,
                    utxos: nil
                )

                let fee = try await wallet.calculateTotalFee(
                    address: address,
                    amountSats: currentOrder.feeSat,
                    satsPerVByte: fastFeeRate,
                    utxosToSpend: utxos
                )

                await MainActor.run {
                    transactionFee = fee
                    selectedUtxos = utxos
                    satsPerVbyte = fastFeeRate
                }
            }
        } catch {
            Logger.error("Failed to calculate actual fee: \(error)")
            await MainActor.run {
                transactionFee = 0
                selectedUtxos = nil
                satsPerVbyte = nil
            }
        }
    }
}
