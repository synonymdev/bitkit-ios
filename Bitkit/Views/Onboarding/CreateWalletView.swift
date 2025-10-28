import SwiftUI

struct CreateWalletView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        VStack {
            VStack(spacing: 0) {
                Spacer()

                Image("wallet")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 311, maxHeight: 311)
                    .frame(maxWidth: .infinity, alignment: .center)

                VStack(spacing: 14) {
                    DisplayText(t("onboarding__slide4_header"), accentColor: .brandAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    BodyMText(t("onboarding__slide4_text"), accentFont: Fonts.bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Spacer(minLength: 32)

            HStack(spacing: 16) {
                CustomButton(title: t("onboarding__new_wallet")) {
                    do {
                        wallet.nodeLifecycleState = .initializing
                        app.showAllEmptyStates(true)
                        _ = try StartupHandler.createNewWallet(bip39Passphrase: nil)
                        try wallet.setWalletExistsState()
                    } catch {
                        app.toast(error)
                    }
                }
                .accessibilityIdentifier("NewWallet")

                CustomButton(
                    title: t("onboarding__restore"),
                    variant: .secondary,
                    destination: MultipleWalletsView()
                )
                .accessibilityIdentifier("RestoreWallet")
            }
        }
        .padding(.horizontal, 32)
    }
}

#Preview {
    CreateWalletView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
