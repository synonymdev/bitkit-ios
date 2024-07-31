//
//  WelcomeView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

import SwiftUI

struct WelcomeView: View {
    @StateObject var viewModel = ViewModel.shared
    @State var bip39Passphrase: String?
    
    var body: some View {
        VStack {
            Text("Welcome")
                .font(.largeTitle)
            
            Form {
                TextField("BIP39 Passphrase", text: Binding(
                    get: { bip39Passphrase ?? "" },
                    set: { bip39Passphrase = $0.isEmpty ? nil : $0 }
                ))
            }
            
            HStack {
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
                
//                Button("Restore Wallet") {
//                    //TODO
//                }
//                .padding()
            }
            .padding()
        }
    }
}

#Preview {
    WelcomeView()
}
