//
//  AllActivityView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import LDKNode
import SwiftUI

struct ActivityRow: View {
    let item: Activity
    @EnvironmentObject var currency: CurrencyViewModel

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        switch item {
        case .lightning(let activity):
            return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(activity.timestamp)))
        case .onchain(let activity):
            return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(activity.timestamp)))
        }
    }

    private var amountPrefix: String {
        switch item {
        case .lightning(let activity):
            return activity.txType == .sent ? "-" : "+"
        case .onchain(let activity):
            return activity.txType == .sent ? "-" : "+"
        }
    }

    @ViewBuilder
    private var amountView: some View {
        switch item {
        case .lightning(let activity):
            if let converted = currency.convert(sats: UInt64(activity.value)) {
                AmountDisplayView(converted: converted, prefix: amountPrefix)
            }
        case .onchain(let activity):
            if let converted = currency.convert(sats: UInt64(activity.value)) {
                AmountDisplayView(converted: converted, prefix: amountPrefix)
            }
        }
    }

    var body: some View {
        HStack {
            icon
                .padding(.trailing, 4)

            VStack(alignment: .leading, spacing: 4) {
                switch item {
                case .lightning(let activity):
                    TransactionStatusText(txType: activity.txType, activity: item)
                case .onchain(let activity):
                    TransactionStatusText(txType: activity.txType, activity: item)
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

    @ViewBuilder
    var icon: some View {
        TransactionIcon(activity: item)
    }
}

// MARK: - Helper Views

private struct AmountDisplayView: View {
    let converted: ConvertedAmount
    let prefix: String
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if currency.primaryDisplay == .bitcoin {
                let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                HStack(spacing: 1) {
                    Text(prefix)
                        .foregroundColor(.primary.opacity(0.8))
                    Text(btcComponents.value)
                }

                Text("\(converted.symbol) \(converted.formatted)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 1) {
                    Text(prefix)
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

private struct TransactionStatusText: View {
    let txType: PaymentType
    let isLightning: Bool
    let status: PaymentState?
    let confirmed: Bool?

    init(txType: PaymentType, activity: Activity) {
        self.txType = txType
        switch activity {
        case .lightning(let ln):
            self.isLightning = true
            self.status = ln.status
            self.confirmed = nil
        case .onchain(let onchain):
            self.isLightning = false
            self.status = nil
            self.confirmed = onchain.confirmed
        }
    }

    var body: some View {
        if isLightning {
            lightningStatus
        } else {
            onchainStatus
        }
    }

    @ViewBuilder
    private var lightningStatus: some View {
        if txType == .sent {
            switch status {
            case .failed:
                Text("Sending Failed")
            case .pending:
                Text("Sending...")
            case .succeeded:
                Text("Sent")
            case .none:
                EmptyView()
            }
        } else {
            switch status {
            case .failed:
                Text("Receive Failed")
            case .pending:
                Text("Receiving...")
            case .succeeded:
                Text("Received")
            case .none:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var onchainStatus: some View {
        if txType == .sent {
            if confirmed == true {
                Text("Sent")
            } else {
                Text("Sending...")
            }
        } else {
            if confirmed == true {
                Text("Received")
            } else {
                Text("Receiving...")
            }
        }
    }
}

private struct TransactionIcon: View {
    let isLightning: Bool
    let status: PaymentState?
    let confirmed: Bool?
    let txType: PaymentType

    init(activity: Activity) {
        switch activity {
        case .lightning(let ln):
            self.isLightning = true
            self.status = ln.status
            self.confirmed = nil
            self.txType = ln.txType
        case .onchain(let onchain):
            self.isLightning = false
            self.status = nil
            self.confirmed = onchain.confirmed
            self.txType = onchain.txType
        }
    }

    var body: some View {
        if isLightning {
            if status == .failed {
                Image(systemName: "xmark")
                    .foregroundColor(.red)
            } else {
                let systemName = txType == .sent ? "arrow.up" : "arrow.down"
                Image(systemName: systemName)
                    .foregroundColor(.purple)
            }
        } else {
            let systemName = txType == .sent ? "arrow.up" : "arrow.down"
            Image(systemName: systemName)
                .foregroundColor(confirmed == true ? .orange : .orange.opacity(0.5))
        }
    }
}

struct ActivityLatest: View {
    let viewType: LatestActivityViewType

    enum LatestActivityViewType {
        case all
        case lightning
        case onchain
    }

    @EnvironmentObject private var activity: ActivityListViewModel

    var body: some View {
        switch viewType {
        case .all:
            return list(activity.latestActivities)
        case .lightning:
            return list(activity.lightningActivities)
        case .onchain:
            return list(activity.onchainActivities)
        }
    }

    @ViewBuilder
    func list(_ items: [Activity]?) -> some View {
        if let items {
            LazyVStack {
                ForEach(items, id: \.self) { item in
                    NavigationLink(destination: ActivityItemView(item: item)) { 
                        ActivityRow(item: item)
                    }

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
    @EnvironmentObject private var activity: ActivityListViewModel

    var body: some View {
        ScrollView {
            if let items = activity.allActivities {
                LazyVStack {
                    ForEach(items, id: \.self) { item in
                        NavigationLink(destination: ActivityItemView(item: item)) {
                            ActivityRow(item: item)

                            if item != items.last {
                                Divider()
                            }
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
