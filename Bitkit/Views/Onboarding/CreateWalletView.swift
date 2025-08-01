import SwiftUI

struct CreateWalletView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

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
                    DisplayText(NSLocalizedString("onboarding__slide4_header", comment: ""), accentColor: .brandAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    BodyMText(NSLocalizedString("onboarding__slide4_text", comment: ""), accentFont: Fonts.bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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

                CustomButton(
                    title: NSLocalizedString("onboarding__restore", comment: ""),
                    variant: .secondary,
                    destination: MultipleWalletsView()
                )
            }
            .padding(.top, 32)
            // TODO: check why secondary button is cut off
            .padding(.bottom, 1)
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    CreateWalletView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
