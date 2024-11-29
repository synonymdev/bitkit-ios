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
    @EnvironmentObject var currency: CurrencyViewModel

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: item.creationTime)
    }

    private var amountPrefix: String {
        item.direction == .outbound ? "-" : "+"
    }

    @ViewBuilder
    private var amountView: some View {
        if let amountSats = item.amountSats,
           let converted = currency.convert(sats: amountSats)
        {
            VStack(alignment: .trailing, spacing: 2) {
                if currency.primaryDisplay == .bitcoin {
                    let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                    HStack(spacing: 1) {
                        Text(amountPrefix)
                            .foregroundColor(.primary.opacity(0.8))
                        Text(btcComponents.value)
                    }

                    Text("\(converted.symbol) \(converted.formatted)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 1) {
                        Text(amountPrefix)
                            .foregroundColor(.primary.opacity(0.8))
                        Text("\(converted.symbol) \(converted.formatted)")
                    }

                    let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                    Text(btcComponents.value)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    var body: some View {
        NavigationLink(destination: ActivityItemView(item: item)) {
            HStack {
                icon
                    .padding(.trailing, 4)

                VStack(alignment: .leading, spacing: 4) {
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

                    Text(formattedTime)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
                amountView
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
