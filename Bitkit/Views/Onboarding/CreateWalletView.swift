import SwiftUI

struct CreateWalletView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    private let t = useTranslation(.onboarding)
    
    var body: some View {
        VStack {
            OnboardingTab(
                imageName: "wallet",
                title: t.parts("slide4_header"),
                text: t.parts("slide4_text"),
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
                    Text(t("new_wallet"))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(30)
                }
                
                NavigationLink {
                    RestoreWalletView()
                } label: {
                    Text(t("restore"))
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