import BitkitCore
import SwiftUI

struct SendFeeRate: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]

    @State private var transactionFees: [TransactionSpeed: UInt64] = [:]

    private var currentCustomFeeRate: UInt32 {
        if let rate = wallet.selectedFeeRateSatsPerVByte { return rate }
        if case let .custom(rate) = settings.defaultTransactionSpeed { return rate }
        return 1
    }

    private func getFee(for speed: TransactionSpeed) -> UInt64 {
        return transactionFees[speed] ?? 0
    }

    private func isDisabled(for speed: TransactionSpeed) -> Bool {
        let fee = getFee(for: speed)
        guard let amount = wallet.sendAmountSats else { return true }
        // Disable if not enough balance and not already selected
        return wallet.totalBalanceSats < amount + fee && wallet.selectedSpeed != speed
    }

    private func selectFee(_ speed: TransactionSpeed) {
        wallet.selectedSpeed = speed

        Task {
            do {
                try await wallet.setFeeRate(speed: speed)
                // Go back to confirmation screen
                navigationPath.removeLast()
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
                let fee = try await wallet.calculateTotalFee(
                    address: address,
                    amountSats: amountSats,
                    satsPerVByte: feeRate,
                    utxosToSpend: wallet.selectedUtxos
                )
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
        .task {
            await loadFeeEstimates()
        }
        .onChange(of: wallet.selectedFeeRateSatsPerVByte) { _ in
            Task {
                await calculateTransactionFees()
            }
        }
    }
}
