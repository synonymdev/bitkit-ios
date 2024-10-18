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
        NavigationLink(destination: ActivityItemView(item: item)) {
            HStack {
                icon
                    .padding(.trailing, 4)

                if item.direction == .outbound {
                    switch item.status {
                    case .failed:
                        Text("Sending Failed")
                    case .pending:
                        Text("Sending...")
                    case .succeeded:
                        Text("Sent")
                    }
                } else {
                    switch item.status {
                    case .failed:
                        Text("Receive Failed")
                    case .pending:
                        Text("Receiving...")
                    case .succeeded:
                        Text("Received")
                    }
                }

                Spacer()
                if let amountSats = item.amountSats {
                    Text("\(amountSats)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    var icon: some View {
        if item.status == .failed {
            Image(systemName: "xmark")
                .foregroundColor(.red)
        } else {
            let systemName = item.direction == .outbound ? "arrow.up" : "arrow.down"

            if item.kind == .onchain {
                Image(systemName: systemName)
                    .foregroundColor(.orange)
            } else {
                Image(systemName: systemName)
                    .foregroundColor(.purple)
            }
        }
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

                    if item != items.last {
                        Divider()
                    }
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

                        if item != items.last {
                            Divider()
                        }
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
