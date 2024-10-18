//
//  AllActivityView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import LDKNode
import SwiftUI

struct ActivityRow: View {
    let item: PaymentDetails

    var body: some View {
        HStack {
            Image(systemName: item.kind == .onchain ? "link" : "bolt")
            Image(systemName: item.direction == .outbound ? "arrow.up" : "arrow.down")

            Spacer()
            if let amountSats = item.amountSats {
                Text("\(amountSats)")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }
}

enum ActivityType {
    case all
    case lightning
    case onchain
}

struct ActivityLatest: View {
    let type: ActivityType

    @EnvironmentObject private var wallet: WalletViewModel

    var body: some View {
        switch type {
        case .all:
            return list(wallet.latestActivityItems)
        case .lightning:
            return list(wallet.latestLightningActivityItems)
        case .onchain:
            return list(wallet.latestOnchainActivityItems)
        }
    }

    @ViewBuilder
    func list(_ items: [PaymentDetails]?) -> some View {
        if let items {
            LazyVStack {
                ForEach(items, id: \.self) { item in
                    ActivityRow(item: item)
                }

                if items.count == 0 {
                    Text("No activity")
                        .padding()
                } else {
                    NavigationLink(destination: AllActivityView()) {
                        Text("Show All Activity")
                            .padding()
                    }
                }
            }
        } else {
            EmptyView()
        }
    }
}

struct AllActivityView: View {
    @EnvironmentObject private var wallet: WalletViewModel

    var body: some View {
        ScrollView {
            if let items = wallet.activityItems {
                LazyVStack {
                    ForEach(items, id: \.self) { item in
                        ActivityRow(item: item)
                    }

                    VStack {}.frame(height: 120)
                }
            } else {
                Text("No activity")
                    .padding()
            }
        }
        .navigationTitle("All Activity")
    }
}

#Preview {
    AllActivityView()
        .environmentObject(WalletViewModel())
}
