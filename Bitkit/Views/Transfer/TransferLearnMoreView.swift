//
//  TransferLearnMoreView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

struct TransferLearnMoreView: View {
    let order: IBtOrder

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayText(NSLocalizedString("lightning__liquidity__title", comment: ""), accentColor: .purpleAccent)
                .padding(.top, 16)

            ScrollView {
                BodyMText(NSLocalizedString("lightning__liquidity__text", comment: ""))
                    .padding(.vertical, 16)

                Spacer()
            }

            CustomButton(title: NSLocalizedString("common__understood", comment: "")) {
                presentationMode.wrappedValue.dismiss()
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("lightning__transfer__nav_title", comment: ""))
        .background(Color.black)
    }
}

#Preview {
    NavigationView {
        TransferLearnMoreView(order: IBtOrder.mock())
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
    }
    .preferredColorScheme(.dark)
}
