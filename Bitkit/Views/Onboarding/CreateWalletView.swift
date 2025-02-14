import SwiftUI

struct CreateWalletView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        VStack {
            OnboardingTab(
                imageName: "wallet",
                title: NSLocalizedString("onboarding__slide4_header", comment: ""),
                text: NSLocalizedString("onboarding__slide4_text", comment: ""),
                accentColor: .brandAccent
            )

            // Action buttons
            HStack(spacing: 16) {
                CustomButton(title: NSLocalizedString("onboarding__new_wallet", comment: "")) {
                    do {
                        wallet.nodeLifecycleState = .initializing
                        app.showAllEmptyStates(true)
                        _ = try StartupHandler.createNewWallet(bip39Passphrase: nil)
                        try wallet.setWalletExistsState()
                    } catch {
                        app.toast(error)
                    }
                }

                NavigationLink {
                    RestoreWalletView()
                } label: {
                    CustomButton(
                        title: NSLocalizedString("onboarding__restore", comment: ""),
                        variant: .secondary
                    )
                }
            }
        }
    }
}

#Preview {
    CreateWalletView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
