import SwiftUI

struct CreateWalletWithPassphraseView: View {
    @State private var bip39Passphrase: String = ""
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var isValidPassphrase: Bool {
        !bip39Passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var content: some View {
        VStack {
            OnboardingTab(
                imageName: "padlock2",
                title: NSLocalizedString("onboarding__passphrase_header", comment: ""),
                text: NSLocalizedString("onboarding__passphrase_text", comment: ""),
                accentColor: .brandAccent
            )
            .frame(maxHeight: .infinity)

            TextField(NSLocalizedString("onboarding__passphrase", comment: ""), text: $bip39Passphrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(.bottom)

            CustomButton(
                title: NSLocalizedString("onboarding__create_new_wallet", comment: ""),
                isDisabled: !isValidPassphrase
            ) {
                do {
                    wallet.nodeLifecycleState = .initializing
                    app.showEmptyState = true
                    _ = try StartupHandler.createNewWallet(bip39Passphrase: bip39Passphrase)
                    try wallet.setWalletExistsState()
                } catch {
                    Haptics.notify(.error)
                    app.toast(error)
                }
            }
        }
        .padding(.horizontal, 32)
        .gesture(
            DragGesture()
                .onChanged { _ in
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil,
                                                    from: nil,
                                                    for: nil)
                }
        )
    }

    var body: some View {
        content
    }
}

#Preview {
    NavigationView {
        CreateWalletWithPassphraseView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
