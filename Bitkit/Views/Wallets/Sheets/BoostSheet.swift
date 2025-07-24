import BitkitCore
import LDKNode
import SwiftUI

struct BoostConfig {
    let onchainActivity: OnchainActivity
}

struct BoostSheetItem: SheetItem, Equatable {
    let id: SheetID = .boost
    let size: SheetSize = .small
    let onchainActivity: OnchainActivity

    init(onchainActivity: OnchainActivity) {
        self.onchainActivity = onchainActivity
    }

    static func == (lhs: BoostSheetItem, rhs: BoostSheetItem) -> Bool {
        return lhs.onchainActivity.id == rhs.onchainActivity.id
    }
}

struct BoostSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var activityList: ActivityListViewModel
    let config: BoostSheetItem

    @State private var feeRate: UInt32?
    @State private var fetchingFees = false
    @State private var isEditingFee = false
    @State private var editedFeeRate: UInt32?

    private var onchainActivity: OnchainActivity {
        config.onchainActivity
    }

    private var isIncoming: Bool {
        onchainActivity.txType == .received
    }

    // TODO: get real estimation
    private var estimatedTxSize: UInt64 { 250 }

    private var currentFeeRate: UInt32 {
        return isEditingFee ? (editedFeeRate ?? feeRate ?? 0) : (feeRate ?? 0)
    }

    private var minFeeRate: UInt32 {
        if isIncoming {
            // CPFP minimum - can be quite high to ensure effectiveness
            return 10
        } else {
            // RBF minimum - must be higher than original
            let originalFeeRate = onchainActivity.feeRate
            return max(UInt32(originalFeeRate) + 2, 2)
        }
    }

    private var maxFeeRate: UInt32 {
        if isIncoming {
            // CPFP maximum - can be very high for urgent transactions
            return 1000
        } else {
            // RBF maximum - reasonable limit to prevent accidental high fees
            return 500
        }
    }

    private var estimatedFeeSats: UInt64 {
        let rate = currentFeeRate
        guard rate > 0 else { return 0 }
        return UInt64(rate) * estimatedTxSize
    }

    private var fiatFeeString: String {
        guard estimatedFeeSats > 0,
            let converted = currency.convert(sats: estimatedFeeSats)
        else {
            return ""
        }
        return "\(converted.symbol)\(converted.formatted)"
    }

    var body: some View {
        Sheet(id: .boost, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: localizedString("wallet__boost_title"))

                VStack(spacing: 16) {
                    BodyMText(
                        localizedString("wallet__boost_fee_recomended"),
                        textColor: .textSecondary
                    )
                    .multilineTextAlignment(.center)

                    // Fee display section
                    if isEditingFee {
                        // Edit mode UI
                        VStack(spacing: 16) {
                            HStack {
                                Button(action: {
                                    let newRate = max(minFeeRate, currentFeeRate - 1)
                                    editedFeeRate = newRate
                                }) {
                                    ZStack {
                                        Image(systemName: "minus")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(currentFeeRate <= minFeeRate ? .gray : Color.redAccent)
                                    }
                                    .frame(width: 32, height: 32)
                                    .background(currentFeeRate <= minFeeRate ? Color.gray6 : Color.red16)
                                    .cornerRadius(200)
                                }
                                .disabled(currentFeeRate <= minFeeRate)

                                Spacer()

                                VStack(spacing: 4) {
                                    BodySSBText("₿ \(currentFeeRate)/vbyte (\(fiatFeeString))")
                                    if currentFeeRate > 0 {
                                        BodySSBText("₿ \(estimatedFeeSats)", textColor: Color.textSecondary)
                                    }
                                }

                                Spacer()

                                Button(action: {
                                    let newRate = min(maxFeeRate, currentFeeRate + 1)
                                    editedFeeRate = newRate
                                }) {
                                    ZStack {
                                        Image(systemName: "plus")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(currentFeeRate >= maxFeeRate ? .gray : Color.greenAccent)
                                    }
                                    .frame(width: 32, height: 32)
                                    .background(currentFeeRate >= maxFeeRate ? Color.gray6 : Color.green16)
                                    .cornerRadius(200)
                                }
                                .disabled(currentFeeRate >= maxFeeRate)
                            }

                            CustomButton(
                                title: "Use Suggested Fee",
                                variant: .primary,
                                size: .small
                            ) {
                                isEditingFee = false
                                editedFeeRate = nil
                            }
                        }
                        .padding(.vertical, 12)
                        .cornerRadius(12)
                    } else {
                        // Normal display mode
                        HStack {
                            Image("timer-alt")
                                .resizable()
                                .frame(width: 24, height: 24)
                                .foregroundColor(.yellowAccent)

                            VStack(alignment: .leading, spacing: 2) {
                                BodyMSBText(
                                    localizedString("wallet__boost"),
                                    textColor: .white
                                )

                                FootnoteText(
                                    "\(localizedString("settings__fee__fast__description"))",
                                    textColor: .textSecondary
                                )
                            }

                            Spacer()

                            Button(action: {
                                isEditingFee = true
                                editedFeeRate = feeRate
                            }) {
                                HStack(spacing: 8) {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        if let feeRate = feeRate {
                                            BodySSBText("₿ \(estimatedFeeSats)")
                                        } else if fetchingFees {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        } else {
                                            BodySSBText("--")
                                        }

                                        BodySSBText(
                                            fiatFeeString,
                                            textColor: .textSecondary
                                        )
                                    }

                                    if !fetchingFees {
                                        Image("pencil")
                                            .resizable()
                                            .frame(width: 16, height: 16)
                                            .foregroundColor(feeRate != nil ? .textSecondary : .gray)
                                    }
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(feeRate == nil || fetchingFees)
                        }
                        .padding(.vertical, 12)
                        .cornerRadius(12)
                    }
                }

                Spacer()

                SwipeButton(
                    title: localizedString("wallet__boost_swipe"),
                    accentColor: .yellowAccent
                ) {
                    try await performBoost()
                }
            }
            .padding(.horizontal, 16)
        }
        .onAppear {
            fetchFeeRate()
        }
    }

    private func fetchFeeRate() {
        Task {
            fetchingFees = true
            Logger.info("Starting fee rate fetch for boost", context: "BoostSheet.fetchFeeRate")
            Logger.debug(
                "Transaction details - ID: \(onchainActivity.txId), Type: \(onchainActivity.txType), IsIncoming: \(isIncoming)",
                context: "BoostSheet.fetchFeeRate")

            do {
                // Wait for wallet to be ready before fetching fees
                Logger.debug("Waiting for wallet node to be ready", context: "BoostSheet.fetchFeeRate")
                let isReady = await wallet.waitForNodeToRun(timeoutSeconds: 10.0)

                guard isReady else {
                    Logger.error("Wallet node not ready after timeout", context: "BoostSheet.fetchFeeRate")
                    throw AppError(message: "Wallet not ready", debugMessage: "Wallet node not ready after 10 second timeout")
                }

                Logger.debug("Setting wallet fee rate to fast", context: "BoostSheet.fetchFeeRate")
                try await wallet.setFeeRate(speed: .fast)
                Logger.info("Successfully set wallet fee rate to fast", context: "BoostSheet.fetchFeeRate")

                if isIncoming {
                    Logger.info("Processing incoming transaction - calculating CPFP fee rate", context: "BoostSheet.fetchFeeRate")

                    // For incoming transactions, calculate optimal CPFP fee rate
                    let cpfpResult = try await LightningService.shared.calculateCpfpFeeRate(
                        parentTxid: onchainActivity.txId,
                        urgent: true
                    )
                    Logger.debug("CPFP calculation result: \(cpfpResult)", context: "BoostSheet.fetchFeeRate")

                    // Get the current fast fee rate as a baseline for CPFP
                    await MainActor.run {
                        let baseFeeRate = wallet.selectedFeeRateSatsPerVByte ?? 10
                        Logger.debug("Base fee rate from wallet: \(baseFeeRate) sat/vbyte", context: "BoostSheet.fetchFeeRate")

                        // CPFP typically needs higher fees to be effective, use 1.5x the fast rate
                        // with a minimum of 20 sat/vbyte for urgent transactions
                        let calculatedFeeRate = max(UInt32(Double(baseFeeRate) * 1.5), 20)
                        feeRate = calculatedFeeRate

                        Logger.info(
                            "CPFP fee rate calculated: \(calculatedFeeRate) sat/vbyte (base: \(baseFeeRate), multiplier: 1.5x, minimum: 20)",
                            context: "BoostSheet.fetchFeeRate")
                        Logger.debug(
                            "Estimated fee cost: \(estimatedFeeSats) sats (\(calculatedFeeRate) sat/vbyte × \(estimatedTxSize) vbytes)",
                            context: "BoostSheet.fetchFeeRate")

                        fetchingFees = false
                    }
                } else {
                    Logger.info("Processing outgoing transaction - using fast fee rate", context: "BoostSheet.fetchFeeRate")

                    // For outgoing transactions, use fast fee rate
                    await MainActor.run {
                        let selectedFeeRate = wallet.selectedFeeRateSatsPerVByte

                        // Ensure we have a valid fee rate with a minimum of 2 sat/vbyte for RBF
                        // RBF requires the new fee rate to be higher than the original transaction
                        let originalFeeRate = onchainActivity.feeRate
                        let baseFeeRate = selectedFeeRate ?? 10

                        // For RBF, use at least the original fee rate + 2 sat/vbyte, with a minimum of 2 sat/vbyte
                        let minRbfFeeRate = max(UInt32(originalFeeRate) + 2, 2)
                        let validatedFeeRate = max(baseFeeRate, minRbfFeeRate)
                        feeRate = validatedFeeRate

                        Logger.info(
                            "RBF fee rate set: \(validatedFeeRate) sat/vbyte (selected: \(selectedFeeRate ?? 0), original: \(originalFeeRate), min RBF: \(minRbfFeeRate))",
                            context: "BoostSheet.fetchFeeRate")
                        Logger.debug(
                            "Estimated fee cost: \(estimatedFeeSats) sats (\(validatedFeeRate) sat/vbyte × \(estimatedTxSize) vbytes)",
                            context: "BoostSheet.fetchFeeRate")

                        fetchingFees = false
                    }
                }

                Logger.info("Fee rate fetch completed successfully", context: "BoostSheet.fetchFeeRate")

            } catch {
                Logger.error("Failed to fetch fee rate for boost: \(error)", context: "BoostSheet.fetchFeeRate")
                Logger.debug(
                    "Error details - Type: \(type(of: error)), Description: \(error.localizedDescription)", context: "BoostSheet.fetchFeeRate")

                await MainActor.run {
                    fetchingFees = false
                    app.toast(
                        type: .error,
                        title: localizedString("common__error"),
                        description: localizedString("wallet__boost_fee_error")
                    )
                }
            }
        }
    }

    private func performBoost() async throws {
        Logger.info("Starting boost transaction", context: "BoostSheet.performBoost")
        Logger.debug(
            "Transaction details - ID: \(onchainActivity.txId), Type: \(onchainActivity.txType), IsIncoming: \(isIncoming)",
            context: "BoostSheet.performBoost")

        let feeRateToUse = currentFeeRate
        guard feeRateToUse > 0 else {
            Logger.error("Fee rate not set or invalid when attempting boost: \(feeRateToUse)", context: "BoostSheet.performBoost")
            app.toast(
                type: .error,
                title: localizedString("common__error"),
                description: localizedString("wallet__boost_fee_not_set")
            )
            throw AppError(message: "Fee rate not set", debugMessage: "Fee rate not set or invalid when attempting boost: \(feeRateToUse)")
        }

        // Additional validation: Check against minimum fee rate
        guard feeRateToUse >= minFeeRate else {
            Logger.error("Fee rate too low for boost: \(feeRateToUse) < \(minFeeRate) sat/vbyte", context: "BoostSheet.performBoost")
            app.toast(
                type: .error,
                title: localizedString("common__error"),
                description: localizedString("wallet__min_possible_fee_rate_msg")
            )
            throw AppError(message: "Fee rate too low", debugMessage: "Fee rate \(feeRateToUse) is below minimum \(minFeeRate) sat/vbyte")
        }

        Logger.info("Using fee rate: \(feeRateToUse) sat/vbyte for boost", context: "BoostSheet.performBoost")
        Logger.debug(
            "Estimated transaction size: \(estimatedTxSize) vbytes, Estimated fee: \(estimatedFeeSats) sats", context: "BoostSheet.performBoost")

        do {
            // Perform the boost operation via CoreService
            let txid = try await activityList.boost(activityId: onchainActivity.id, feeRate: feeRateToUse)

            Logger.info("Boost transaction completed successfully: \(txid)", context: "BoostSheet.performBoost")

            Logger.debug("Starting wallet sync after boost", context: "BoostSheet.performBoost")
            // Sync wallet to refresh state
            try await wallet.sync()
            Logger.debug("Wallet sync completed after boost", context: "BoostSheet.performBoost")

            // Sync LDK node payments to process the new RBF transaction
            try await activityList.syncLdkNodePayments()
            Logger.debug("LDK node payments synced after boost", context: "BoostSheet.performBoost")

            // Refresh activity list state
            await activityList.syncState()
            Logger.debug("Activity list state synced after boost", context: "BoostSheet.performBoost")

            // Show success message after everything is synced
            app.toast(
                type: .success,
                title: localizedString("wallet__boost_success_title"),
                description: localizedString("wallet__boost_success_msg")
            )

            Logger.info("Boost transaction completed successfully, hiding sheet", context: "BoostSheet.performBoost")
            sheets.hideSheet()

        } catch {
            Logger.error("Failed to boost transaction: \(error)", context: "BoostSheet.performBoost")
            Logger.debug(
                "Boost error details - Type: \(type(of: error)), Description: \(error.localizedDescription)", context: "BoostSheet.performBoost")
            Logger.debug(
                "Failed boost parameters - TxID: \(onchainActivity.txId), FeeRate: \(feeRateToUse) sat/vbyte, IsIncoming: \(isIncoming)",
                context: "BoostSheet.performBoost")

            app.toast(
                type: .error,
                title: localizedString("wallet__boost_error"),
                description: error.localizedDescription
            )

            throw error
        }
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                BoostSheet(
                    config: BoostSheetItem(
                        onchainActivity: OnchainActivity(
                            id: "test-onchain-1",
                            txType: .sent,
                            txId: "abc123",
                            value: 100000,
                            fee: 500,
                            feeRate: 8,
                            address: "bc1...",
                            confirmed: false,
                            timestamp: UInt64(Date().timeIntervalSince1970),
                            isBoosted: false,
                            isTransfer: false,
                            doesExist: true,
                            confirmTimestamp: nil,
                            channelId: nil,
                            transferTxId: nil,
                            createdAt: nil,
                            updatedAt: nil
                        )
                    )
                )
                .environmentObject(AppViewModel())
                .environmentObject(SheetViewModel())
                .environmentObject(WalletViewModel())
                .environmentObject(CurrencyViewModel())
                .environmentObject(ActivityListViewModel())
                .presentationDetents([.height(400)])
            }
        )
        .preferredColorScheme(.dark)
}
