import SwiftUI

struct FundManualAmountView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    
    let lnPeer: LnPeer
    
    @State private var satsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString("lightning__external_amount__title", comment: ""), accentColor: .purpleAccent)
                    .padding(.top, 16)
                
                // Visible balance display that acts as a button
                AmountInput(primaryDisplay: $primaryDisplay, overrideSats: $overrideSats) { newSats in
                    satsAmount = newSats
                    overrideSats = nil
                }
                .padding(.vertical, 16)
                
                Spacer()
                
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading) {
                        BodySText(NSLocalizedString("wallet__send_available", comment: "").uppercased(), textColor: .textSecondary)
                        
                        if let converted = currency.convert(sats: UInt64(wallet.totalOnchainSats)) {
                            if primaryDisplay == .bitcoin {
                                let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                                BodySText("\(btcComponents.symbol) \(btcComponents.value)")
                            } else {
                                BodySText("\(converted.symbol) \(converted.formatted)")
                            }
                        }
                    }
                    
                    Spacer()
                    
                    amountButtons
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)
            
            Spacer()
            
            CustomButton(
                title: NSLocalizedString("common__continue", comment: ""),
                isDisabled: satsAmount == 0,
                destination: FundManualConfirmView(lnPeer: lnPeer, satsAmount: satsAmount)
            )
            .disabled(satsAmount == 0)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color.black)
        .navigationTitle(NSLocalizedString("lightning__connections", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    app.showTransferToSpendingSheet = false
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                }
            }
        }
        .task {
            primaryDisplay = currency.primaryDisplay
        }
    }
    
    private var amountButtons: some View {
        HStack(spacing: 16) {
            NumberPadActionButton(
                text: primaryDisplay == .bitcoin ? currency.selectedCurrency : "BTC",
                imageName: "transfer-purple"
            ) {
                withAnimation {
                    primaryDisplay = primaryDisplay == .bitcoin ? .fiat : .bitcoin
                }
            }
            
            NumberPadActionButton(text: "25%") {
                overrideSats = UInt64(wallet.totalOnchainSats) / 4
            }
            
            NumberPadActionButton(text: NSLocalizedString("common__max", comment: "")) {
                overrideSats = UInt64(wallet.totalOnchainSats)
            }
        }
    }
}

#Preview {
    NavigationView {
        FundManualAmountView(lnPeer: LnPeer(nodeId: "test", host: "test.com", port: 9735))
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
    }
    .preferredColorScheme(.dark)
} 