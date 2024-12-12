import SwiftUI

struct RestoreWalletView: View {
    @State private var bip39Mnemonic = ""
    @State private var bip39Passphrase: String? = nil
    
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    
    var body: some View {
        VStack {
            Text("Restore Wallet")
                .font(.largeTitle)
                .padding()
            
            Text("Enter your recovery phrase to restore your wallet")
                .multilineTextAlignment(.center)
                .padding()
            
            Form {
                Section("Recovery Phrase") {
                    TextField("BIP39 Mnemonic", text: $bip39Mnemonic)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                
                Section("Optional") {
                    TextField("BIP39 Passphrase", text: Binding(
                        get: { bip39Passphrase ?? "" },
                        set: { bip39Passphrase = $0.isEmpty ? nil : $0 }
                    ))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                }
            }
            
            Button(action: restoreWallet) {
                Text("Restore Wallet")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding()
            
            // TODO: Implement restore wallet UI
        }
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func restoreWallet() {
        do {
            wallet.nodeLifecycleState = .initializing
            _ = try StartupHandler.restoreWallet(mnemonic: bip39Mnemonic, bip39Passphrase: bip39Passphrase)
            try wallet.setWalletExistsState()
        } catch {
            app.toast(error)
        }
    }
}

#Preview {
    NavigationView {
        RestoreWalletView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
    }
} 