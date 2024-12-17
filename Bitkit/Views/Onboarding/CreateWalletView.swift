import SwiftUI

struct CreateWalletView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    
    var body: some View {
        VStack {
            OnboardingTab(
                imageName: "wallet",
                titleFirstLine: "YOUR KEYS,",
                titleSecondLine: "YOUR COINS",
                text: "Let's create your wallet. Please be aware that Bitkit is mobile software. Don't store all your money in Bitkit.",
                secondLineColor: .brand
            )
            
            // Action buttons
            HStack(spacing: 16) {
                Button(action: {
                    do {
                        wallet.nodeLifecycleState = .initializing
                        _ = try StartupHandler.createNewWallet(bip39Passphrase: nil)
                        try wallet.setWalletExistsState()
                    } catch {
                        app.toast(error)
                    }
                }) {
                    Text("New Wallet")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(30)
                }
                
                NavigationLink {
                    RestoreWalletView()
                } label: {
                    Text("Restore")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .foregroundColor(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 30)
                                .stroke(Color.gray, lineWidth: 1)
                        )
                        .cornerRadius(30)
                }
            }
        }
    }
}

#Preview {
    CreateWalletView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
}