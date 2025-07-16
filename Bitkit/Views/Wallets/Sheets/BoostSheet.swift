import SwiftUI
import BitkitCore
import LDKNode

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

    private var onchainActivity: OnchainActivity {
        config.onchainActivity
    }
    
    private var isIncoming: Bool {
        onchainActivity.txType == .received
    }
    
    // TODO: get real estimation
    private var estimatedTxSize: UInt64 { 250 }
    
    private var estimatedFeeSats: UInt64 {
        guard let feeRate = feeRate else { return 0 }
        return UInt64(feeRate) * estimatedTxSize
    }
    
    private var fiatFeeString: String {
        guard estimatedFeeSats > 0,
              let converted = currency.convert(sats: estimatedFeeSats) else {
            return ""
        }
        return "\(converted.symbol)\(converted.formatted)"
    }

    var body: some View {
        Sheet(id: .boost) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: localizedString("wallet__boost_title"))
                
                VStack(spacing: 16) {
                    BodyMText(
                        localizedString("wallet__boost_fee_recomended"),
                        textColor: .textSecondary
                    )
                    .multilineTextAlignment(.center)
                    
                    // Fee display section
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
                    }
                    .padding(.vertical, 12)
                    .cornerRadius(12)
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
            Logger.debug("Transaction details - ID: \(onchainActivity.txId), Type: \(onchainActivity.txType), IsIncoming: \(isIncoming)", context: "BoostSheet.fetchFeeRate")
            
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
                        
                        Logger.info("CPFP fee rate calculated: \(calculatedFeeRate) sat/vbyte (base: \(baseFeeRate), multiplier: 1.5x, minimum: 20)", context: "BoostSheet.fetchFeeRate")
                        Logger.debug("Estimated fee cost: \(estimatedFeeSats) sats (\(calculatedFeeRate) sat/vbyte × \(estimatedTxSize) vbytes)", context: "BoostSheet.fetchFeeRate")
                        
                        fetchingFees = false
                    }
                } else {
                    Logger.info("Processing outgoing transaction - using fast fee rate", context: "BoostSheet.fetchFeeRate")
                    
                    // For outgoing transactions, use fast fee rate
                    await MainActor.run {
                        let selectedFeeRate = wallet.selectedFeeRateSatsPerVByte
                        feeRate = selectedFeeRate
                        
                        Logger.info("RBF fee rate set: \(selectedFeeRate ?? 0) sat/vbyte", context: "BoostSheet.fetchFeeRate")
                        Logger.debug("Estimated fee cost: \(estimatedFeeSats) sats (\(selectedFeeRate ?? 0) sat/vbyte × \(estimatedTxSize) vbytes)", context: "BoostSheet.fetchFeeRate")
                        
                        fetchingFees = false
                    }
                }
                
                Logger.info("Fee rate fetch completed successfully", context: "BoostSheet.fetchFeeRate")
                
            } catch {
                Logger.error("Failed to fetch fee rate for boost: \(error)", context: "BoostSheet.fetchFeeRate")
                Logger.debug("Error details - Type: \(type(of: error)), Description: \(error.localizedDescription)", context: "BoostSheet.fetchFeeRate")
                
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
        Logger.debug("Transaction details - ID: \(onchainActivity.txId), Type: \(onchainActivity.txType), IsIncoming: \(isIncoming)", context: "BoostSheet.performBoost")
        
        guard let feeRate = feeRate else {
            Logger.error("Fee rate not set when attempting boost", context: "BoostSheet.performBoost")
            app.toast(
                type: .error,
                title: localizedString("common__error"),
                description: localizedString("wallet__boost_fee_not_set")
            )
            throw AppError(message: "Fee rate not set", debugMessage: "Fee rate not set when attempting boost")
        }
        
        Logger.info("Using fee rate: \(feeRate) sat/vbyte for boost", context: "BoostSheet.performBoost")
        Logger.debug("Estimated transaction size: \(estimatedTxSize) vbytes, Estimated fee: \(estimatedFeeSats) sats", context: "BoostSheet.performBoost")

        do {
            // Perform the boost operation via CoreService
            let txid = try await activityList.boost(activityId: onchainActivity.id, feeRate: feeRate)
            
            Logger.info("Boost transaction completed successfully: \(txid)", context: "BoostSheet.performBoost")
            
            // Show success message
            app.toast(
                type: .success,
                title: localizedString("wallet__boost_success_title"),
                description: localizedString("wallet__boost_success_msg")
            )
            
            Logger.debug("Starting wallet sync after boost", context: "BoostSheet.performBoost")
            // Sync wallet to refresh state
            Task {
                try await wallet.sync()
                Logger.debug("Wallet sync completed after boost", context: "BoostSheet.performBoost")
            }
            
            // Activity list state is automatically synced in the boost function
            Logger.debug("Activity list state synced after boost", context: "BoostSheet.performBoost")
            
            Logger.info("Boost transaction completed successfully, hiding sheet", context: "BoostSheet.performBoost")
            sheets.hideSheet()
            
        } catch {
            Logger.error("Failed to boost transaction: \(error)", context: "BoostSheet.performBoost")
            Logger.debug("Boost error details - Type: \(type(of: error)), Description: \(error.localizedDescription)", context: "BoostSheet.performBoost")
            Logger.debug("Failed boost parameters - TxID: \(onchainActivity.txId), FeeRate: \(feeRate) sat/vbyte, IsIncoming: \(isIncoming)", context: "BoostSheet.performBoost")
            
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
            }
        )
        .preferredColorScheme(.dark)
} 
