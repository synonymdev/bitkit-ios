import BitkitCore
import SwiftUI

struct SendFeeRate: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]

    @State private var feeEstimates: FeeRates?
    @State private var transactionFees: [TransactionSpeed: UInt64] = [:]

    private var onchainBalance: UInt64 {
        // This would come from wallet balance
        return UInt64(wallet.totalBalanceSats)
    }

    private var currentCustomFeeRate: UInt32 {
        // Get the current custom fee rate from wallet or settings
        if let walletFeeRate = wallet.selectedFeeRateSatsPerVByte {
            return walletFeeRate
        } else if case let .custom(rate) = settings.defaultTransactionSpeed {
            return rate
        } else {
            return 1 // Default fallback
        }
    }

    private func getFee(for speed: TransactionSpeed) -> UInt64 {
        return transactionFees[speed] ?? 0
    }

    private func isDisabled(for speed: TransactionSpeed) -> Bool {
        let fee = getFee(for: speed)
        let hasEnoughBalance = onchainBalance >= wallet.sendAmountSats! + fee

        // Disable if not enough balance and not already selected
        return !hasEnoughBalance && wallet.selectedSpeed != speed
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

    private func loadFeeEstimates() async {
        let estimates = await wallet.getCurrentFeeEstimates()
        await MainActor.run {
            feeEstimates = estimates
        }

        await calculateTransactionFees()
    }

    private func calculateTransactionFees() async {
        guard let estimates = feeEstimates,
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
                            isDisabled: isDisabled(for: .custom(satsPerVByte: currentCustomFeeRate))
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
