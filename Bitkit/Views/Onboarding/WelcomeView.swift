//
//  WelcomeView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

import SwiftUI

struct RestoreView: View {
    @StateObject var viewModel = ViewModel.shared
    
    @State var bip39Mnemonic = "play toss explain entire until buddy sign promote prepare artist crystal auction"
    @State var bip39Passphrase: String? = nil
    
    var body: some View {
        VStack {
            Text("Restore Wallet")
                .font(.largeTitle)
            
            Form() {
                TextField("BIP39 Mnemonic", text: $bip39Mnemonic)
                
                TextField("BIP39 Passphrase", text: Binding(
                    get: { bip39Passphrase ?? "" },
                    set: { bip39Passphrase = $0.isEmpty ? nil : $0 }
                ))
            }
            
            HStack {
                Button("Restore Wallet") {
                    do {
                        _ = try StartupHandler.restoreWallet(mnemonic: bip39Mnemonic, bip39Passphrase: bip39Passphrase)
                        //TODO: handle full sync here before revealing the UI so balances are pre populated
                        viewModel.setWalletExistsState()
                    } catch {
                        //TODO: show a error to user
                        Logger.error(error)
                    }
                }
                .padding()
            }
            .padding()
        }
    }
}

struct WelcomeView: View {
    @StateObject var viewModel = ViewModel.shared
    @State var bip39Passphrase: String?
    
    @State var showRestore = false
    
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
                        _ = try StartupHandler.createNewWallet(bip39Passphrase: bip39Passphrase)
                        viewModel.setWalletExistsState()
                    } catch {
                        //TODO: show a error to user
                        Logger.error(error)
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
        }
    }
}

#Preview {
    WelcomeView()
}
