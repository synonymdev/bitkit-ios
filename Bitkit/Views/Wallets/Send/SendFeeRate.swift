import BitkitCore
import SwiftUI

struct SendFeeRate: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(HwWalletManager.self) private var hwWalletManager

    @Binding var navigationPath: [SendRoute]
    let hwSend: HwSendCoordinator

    @State private var transactionFees: [TransactionSpeed: UInt64] = [:]

    /// Both on-chain and Lightning options exist and the user can pay from either (BIP21 / unified invoice).
    private var canSwitchWallet: Bool {
        guard !hwSend.isActive else { return false }
        guard app.scannedOnchainInvoice != nil, app.scannedLightningInvoice != nil else { return false }
        let amount = wallet.sendAmountSats ?? app.scannedOnchainInvoice?.amountSatoshis ?? 0
        return wallet.canSwitchWalletForUnifiedInvoice(amountSats: amount)
    }

    private var currentCustomFeeRate: UInt32 {
        if case let .custom(rate) = wallet.selectedSpeed { return rate }
        if case let .custom(rate) = settings.defaultTransactionSpeed { return rate }
        if let estimates = feeEstimatesManager.estimates { return estimates.slow }
        return 1
    }

    private func getFee(for speed: TransactionSpeed) -> UInt64 {
        return transactionFees[speed] ?? 0
    }

    private func isDisabled(for speed: TransactionSpeed) -> Bool {
        guard let amount = wallet.sendAmountSats else { return true }

        let fee = getFee(for: speed)
        let totalSats = hwSend.walletId.map { hwWalletManager.fundingBalance(walletId: $0) }
            ?? UInt64(clamping: wallet.totalOnchainSats)
        return totalSats < amount + fee && wallet.selectedSpeed != speed
    }

    private func selectFee(_ speed: TransactionSpeed) {
        wallet.selectedSpeed = speed

        Task { @MainActor in
            do {
                if speed == .instant {
                    app.selectedWalletToPayFrom = .lightning
                    navigationPath.removeLast()
                } else {
                    try await wallet.setFeeRate(speed: speed)
                    app.selectedWalletToPayFrom = .onchain
                    await refreshHardwareMaxIfNeeded()
                    navigationPath.removeLast()
                }
            } catch {
                Logger.error("Error setting fee rate: \(error)", context: "SendFeeRate")
            }
        }
    }

    /// Tier-based range for custom fee (e.g. "10–20 min") from current estimates.
    private var customFeeRangeOverride: String {
        TransactionSpeed.getFeeTierLocalized(
            feeRate: UInt64(currentCustomFeeRate),
            feeEstimates: feeEstimatesManager.estimates,
            variant: .range
        )
    }

    private func loadFeeEstimates() async {
        await feeEstimatesManager.getEstimates()
        await calculateTransactionFees()
    }

    private func calculateTransactionFees() async {
        guard let estimates = feeEstimatesManager.estimates,
              let address = app.scannedOnchainInvoice?.address,
              let amountSats = wallet.sendAmountSats
        else {
            return
        }

        let speeds: [TransactionSpeed] = [.fast, .normal, .slow, .custom(satsPerVByte: currentCustomFeeRate)]
        var newFees: [TransactionSpeed: UInt64] = [:]

        for speed in speeds {
            let feeRate = speed.getFeeRate(from: estimates)

            do {
                let fee = if let walletId = hwSend.walletId {
                    try await hwWalletManager.estimateOfflineFundingMiningFee(
                        walletId: walletId,
                        address: address,
                        sats: amountSats,
                        satsPerVByte: UInt64(feeRate)
                    )
                } else {
                    try await wallet.calculateTotalFee(
                        address: address,
                        amountSats: amountSats,
                        satsPerVByte: feeRate,
                        utxosToSpend: wallet.selectedUtxos
                    )
                }
                newFees[speed] = fee
            } catch {
                Logger.error("Error calculating fee for \(speed): \(error)", context: "SendFeeRate")
                // Fallback to estimated calculation
                let estimatedTxSize: UInt64 = 250
                newFees[speed] = UInt64(feeRate) * estimatedTxSize
            }
        }

        await MainActor.run {
            transactionFees = newFees
        }
    }

    private func refreshHardwareMaxIfNeeded() async {
        guard hwSend.isActive,
              let address = app.scannedOnchainInvoice?.address,
              let feeRate = wallet.selectedFeeRateSatsPerVByte
        else {
            return
        }
        await hwSend.refreshAvailable(
            manager: hwWalletManager,
            destinationAddress: address,
            satsPerVByte: UInt64(feeRate)
        )
        if wallet.isMaxAmountSend {
            wallet.sendAmountSats = hwSend.availableSats
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__send_fee_speed"), showBackButton: true)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("wallet__send_fee_and_speed"))
                    .padding(.bottom, 16)
                    .padding(.horizontal, 16)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if canSwitchWallet {
                            FeeItem(
                                speed: .instant,
                                amount: wallet.routingFeeEstimateSats,
                                isSelected: wallet.selectedSpeed == .instant,
                                isDisabled: false
                            ) {
                                selectFee(.instant)
                            }
                        }

                        FeeItem(
                            speed: .fast,
                            amount: getFee(for: .fast),
                            isSelected: wallet.selectedSpeed == .fast,
                            isDisabled: isDisabled(for: .fast)
                        ) {
                            selectFee(.fast)
                        }

                        FeeItem(
                            speed: .normal,
                            amount: getFee(for: .normal),
                            isSelected: wallet.selectedSpeed == .normal,
                            isDisabled: isDisabled(for: .normal)
                        ) {
                            selectFee(.normal)
                        }

                        FeeItem(
                            speed: .slow,
                            amount: getFee(for: .slow),
                            isSelected: wallet.selectedSpeed == .slow,
                            isDisabled: isDisabled(for: .slow)
                        ) {
                            selectFee(.slow)
                        }

                        FeeItem(
                            speed: .custom(satsPerVByte: currentCustomFeeRate),
                            amount: getFee(for: .custom(satsPerVByte: currentCustomFeeRate)),
                            isSelected: wallet.selectedSpeed == .custom(satsPerVByte: currentCustomFeeRate),
                            isDisabled: isDisabled(for: .custom(satsPerVByte: currentCustomFeeRate)),
                            rangeOverride: customFeeRangeOverride
                        ) {
                            navigationPath.append(.feeCustom)
                        }
                    }
                }

                Spacer()

                CustomButton(title: t("common__continue")) {
                    navigationPath.removeLast()
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationBarHidden(true)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { @MainActor in
            if app.selectedWalletToPayFrom == .lightning, canSwitchWallet {
                wallet.selectedSpeed = .instant
            }
            await loadFeeEstimates()
        }
        .onChange(of: wallet.selectedFeeRateSatsPerVByte) {
            Task {
                await calculateTransactionFees()
            }
        }
    }
}
