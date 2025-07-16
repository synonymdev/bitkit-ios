import SwiftUI
import BitkitCore

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
    let config: BoostSheetItem

    @State private var feeRate: UInt32?
    @State private var fetchingFees = false

    private var onchainActivity: OnchainActivity {
        config.onchainActivity
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
            return "-- --"
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
                                localizedString("settings__fee__fast__description"),
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
                    // TODO: Implement boost logic
                    sheets.hideSheet()
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
            do {
                try await wallet.setFeeRate(speed: .fast)
                await MainActor.run {
                    feeRate = wallet.selectedFeeRateSatsPerVByte
                    fetchingFees = false
                }
            } catch {
                await MainActor.run {
                    fetchingFees = false
                }
            }
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
            }
        )
        .preferredColorScheme(.dark)
} 
