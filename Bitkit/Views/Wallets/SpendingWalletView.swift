//
//  SpendingWalletView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/11.
//

import SwiftUI

struct SpendingWalletView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        VStack {
            VStack(alignment: .leading) {
                Text("SPENDING BALANCE")
                    .font(.caption2)
                Text("\(wallet.totalLightningSats)")
                    .font(.title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            ScrollView {
                ActivityLatest(type: .lightning)
            }
            .refreshable {
                do {
                    try await wallet.sync()
                } catch {
                    app.toast(error)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
    }
}

#Preview {
    SpendingWalletView()
}
