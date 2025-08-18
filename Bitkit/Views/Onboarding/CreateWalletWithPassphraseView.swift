import SwiftUI

struct CreateWalletWithPassphraseView: View {
    @State private var bip39Passphrase: String = ""
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var isValidPassphrase: Bool {
        !bip39Passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()

                Image("advanced-label")
                    .resizable()
                    .frame(width: 106, height: 42)
                    .padding(.trailing, -32)
            }

            OnboardingContent(
                imageName: "padlock2",
                title: t("onboarding__passphrase_header"),
                text: t("onboarding__passphrase_text"),
                accentColor: .brandAccent
            )
            .frame(maxHeight: .infinity)

            TextField(
                t("onboarding__passphrase"),
                text: $bip39Passphrase
            )
            .padding(.bottom, 28)

            CustomButton(
                title: t("onboarding__create_new_wallet"),
                isDisabled: !isValidPassphrase
            ) {
                do {
                    wallet.nodeLifecycleState = .initializing
                    app.showAllEmptyStates(true)
                    _ = try StartupHandler.createNewWallet(bip39Passphrase: bip39Passphrase)
                    try wallet.setWalletExistsState()
                } catch {
                    Haptics.notify(.error)
                    app.toast(error)
                }
            }
        }
        .padding(.horizontal, 32)
        .bottomSafeAreaPadding()
        .gesture(
            DragGesture()
                .onChanged { _ in
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
        )
    }
}

#Preview {
    CreateWalletWithPassphraseView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
