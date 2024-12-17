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
                titleFirstLine: "SECURE WITH",
                titleSecondLine: "PASSPHRASE",
                text: "You can add a secret passphrase to the 12-word recovery phrase. If you do, make sure you don't forget.",
                secondLineColor: .brand
            )
            .frame(maxHeight: .infinity)
    
            TextField("Passphrase", text: $bip39Passphrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(.bottom)
        
            Button {
                guard isValidPassphrase else {
                    Haptics.notify(.error)
                    return
                }
                
                do {
                    wallet.nodeLifecycleState = .initializing
                    _ = try StartupHandler.createNewWallet(bip39Passphrase: bip39Passphrase)
                    try wallet.setWalletExistsState()
                } catch {
                    Haptics.notify(.error)
                    app.toast(error)
                }
            } label: {
                Text("Create New Wallet")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(30)
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
    }
} 