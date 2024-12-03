//
//  WelcomeView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

import SwiftUI

struct RestoreView: View {
    @State var bip39Mnemonic = Env.isDebug ? "flash fish real cool soon awkward helmet call deposit destroy dice glad merry tape task mercy sadness sample cost royal acoustic neither egg leg" : ""
    @State var bip39Passphrase: String? = nil
    
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    
    var body: some View {
        VStack {
            Text("Restore Wallet")
                .font(.largeTitle)
            
            Form {
                TextField("BIP39 Mnemonic", text: $bip39Mnemonic)
                
                TextField("BIP39 Passphrase", text: Binding(
                    get: { bip39Passphrase ?? "" },
                    set: { bip39Passphrase = $0.isEmpty ? nil : $0 }
                ))
            }
            
            HStack {
                Button("Restore Wallet") {
                    do {
                        wallet.nodeLifecycleState = .initializing
                        _ = try StartupHandler.restoreWallet(mnemonic: bip39Mnemonic, bip39Passphrase: bip39Passphrase)
                        try wallet.setWalletExistsState()
                    } catch {
                        app.toast(error)
                    }
                }
                .padding()
            }
            .padding()
        }
    }
}

struct WelcomeView: View {
    @State var bip39Passphrase: String?
    @State var showRestore = false
    
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    
    var body: some View {
        VStack {
            Text("Welcome")
                .font(.largeTitle)
            
            Form {
                Section("Optional passphrase") {
                    TextField("BIP39 Passphrase", text: Binding(
                        get: { bip39Passphrase ?? "" },
                        set: { bip39Passphrase = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
            
            VStack {
                Button("Create Wallet") {
                    do {
                        wallet.nodeLifecycleState = .initializing
                        _ = try StartupHandler.createNewWallet(bip39Passphrase: bip39Passphrase)
                        try wallet.setWalletExistsState()
                    } catch {
                        app.toast(error)
                    }
                }
                .padding()
                
                Button("Restore Wallet") {
                    showRestore = true
                }
                .padding()
            }
            .padding()
        }
        .sheet(isPresented: $showRestore) {
            RestoreView()
                .interactiveDismissDisabled()
        }
    }
}

#Preview {
    WelcomeView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
}
