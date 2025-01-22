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
                secondLineColor: .brandAccent
            )

            // Action buttons
            HStack(spacing: 16) {
                CustomButton(title: t("new_wallet")) {
                    do {
                        wallet.nodeLifecycleState = .initializing
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
                        title: t("restore"),
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
