import SwiftUI

struct SendFeeCustom: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]

    @State private var feeRate: UInt32 = 1
    @State private var maxFee: UInt32 = 999
    @State private var minFee: UInt32 = 1
    @State private var transactionFee: UInt64 = 0

    private var isValid: Bool {
        return feeRate != 0
    }

    private var totalFeeText: String {
        if let fiatAmount = currency.convert(sats: transactionFee) {
            return t(
                "wallet__send_fee_total_fiat",
                variables: [
                    "feeSats": String(transactionFee),
                    "fiatSymbol": fiatAmount.symbol,
                    "fiatFormatted": fiatAmount.formatted,
                ]
            )
        } else {
            return t("wallet__send_fee_total", variables: ["feeSats": String(transactionFee)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__send_fee_custom"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("common__sat_vbyte"))
                    .padding(.bottom, 16)

                MoneyText(sats: Int(feeRate), symbol: true, color: feeRate == 0 ? .textSecondary : .textPrimary)
                    .padding(.bottom, 16)

                if isValid {
                    BodyMText(totalFeeText)
                        .padding(.bottom, 32)
                }

                Spacer()

                NumberPad { key in
                    handleNumberPadInput(key)
                }

                CustomButton(title: t("common__continue")) {
                    onContinue()
                }
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadFeeLimits()
            await initializeFromCurrentFee()
        }
    }

    private func loadFeeLimits() async {
        let limits = await wallet.getFeeLimits()
        minFee = limits.minFee
        maxFee = limits.maxFee
    }

    private func initializeFromCurrentFee() async {
        feeRate = wallet.selectedFeeRateSatsPerVByte ?? 0

        // Calculate the initial fee
        await calculateTransactionFee()
    }

    private func calculateTransactionFee() async {
        guard feeRate > 0 else {
            transactionFee = 0
            return
        }

        // Get the destination address and amount from the send flow
        let address = app.scannedOnchainInvoice!.address
        let amountSats = wallet.sendAmountSats!

        do {
            let fee = try await wallet.calculateTotalFee(
                address: address,
                amountSats: amountSats,
                satsPerVByte: feeRate,
                utxosToSpend: wallet.selectedUtxos
            )

            await MainActor.run {
                transactionFee = fee
            }
        } catch {
            Logger.error("Failed to calculate actual fee: \(error)")
            // Fall back to estimated calculation
            await MainActor.run {
                let estimatedTxSize: UInt64 = 250 // vbytes - typical transaction size
                transactionFee = UInt64(feeRate) * estimatedTxSize
            }
        }
    }

    private func handleNumberPadInput(_ key: String) {
        let current = String(feeRate)

        if key == "delete" {
            if current.count > 1 {
                let newString = String(current.dropLast())
                feeRate = UInt32(newString) ?? 0
            } else {
                feeRate = 0
            }
        } else {
            // Handle leading zero
            let newString: String = if current == "0" {
                key
            } else {
                current + key
            }

            // Limit to 3 digits (max 999 sat/vB)
            if newString.count <= 3, let newRate = UInt32(newString) {
                feeRate = newRate
            }
        }

        // Recalculate the transaction fee when fee rate changes
        Task {
            await calculateTransactionFee()
        }
    }

    private func validateFeeRate() -> Bool {
        if feeRate > maxFee {
            app.toast(
                type: .info,
                title: t("wallet__max_possible_fee_rate"),
                description: t("wallet__max_possible_fee_rate_msg")
            )
            return false
        }

        if feeRate < minFee {
            app.toast(
                type: .info,
                title: t("wallet__min_possible_fee_rate"),
                description: t("wallet__min_possible_fee_rate_msg")
            )
            return false
        }

        return true
    }

    private func onContinue() {
        if !validateFeeRate() {
            return
        }

        wallet.selectedSpeed = .custom(satsPerVByte: feeRate)

        // Set the custom fee rate
        Task {
            do {
                try await wallet.setFeeRate(speed: .custom(satsPerVByte: feeRate))
                // Go back to fee selection
                navigationPath.removeLast()
            } catch {
                Logger.error("Failed to set custom fee rate: \(error)")
                app.toast(
                    type: .warning,
                    title: t("wallet__send_fee_error"),
                    description: error.localizedDescription
                )
            }
        }
    }
}
