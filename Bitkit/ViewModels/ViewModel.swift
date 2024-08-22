//
//  ViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/31.
//

import SwiftUI

@MainActor
class ViewModel: ObservableObject {
    @Published var walletExists: Bool? = nil

    private init() {}
    public static var shared = ViewModel()

    func setWalletExistsState() {
        do {
            walletExists = try Keychain.exists(key: .bip39Mnemonic(index: 0))
        } catch {
            // TODO: show error
            Logger.error(error)
        }
    }
}
