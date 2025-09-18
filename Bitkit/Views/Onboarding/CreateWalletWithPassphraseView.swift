import SwiftUI

struct CreateWalletWithPassphraseView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var bip39Passphrase: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var isValidPassphrase: Bool {
        !bip39Passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                NavigationBar(title: "", showMenuButton: false, onBack: {
                    dismiss()
                })

                Image("advanced-label")
                    .resizable()
                    .frame(width: 106, height: 42)
                    .padding(.trailing, -16)
                    .padding(.top, 5)
            }

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        OnboardingContent(
                            imageName: "padlock2",
                            title: t("onboarding__passphrase_header"),
                            text: t("onboarding__passphrase_text"),
                            accentColor: .brandAccent
                        )
                        .frame(maxHeight: .infinity)

                        TextField(t("onboarding__passphrase"), text: $bip39Passphrase)
                            .focused($isTextFieldFocused)
                            .padding(.bottom, 28)

                        CustomButton(title: t("onboarding__create_new_wallet"), isDisabled: !isValidPassphrase) {
                            createWallet()
                        }
                        .buttonBottomPadding(isFocused: isTextFieldFocused)
                    }
                    .frame(minHeight: geometry.size.height)
                    .padding(.horizontal, 16)
                    .bottomSafeAreaPadding()
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }

    private func createWallet() {
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

#Preview {
    CreateWalletWithPassphraseView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
