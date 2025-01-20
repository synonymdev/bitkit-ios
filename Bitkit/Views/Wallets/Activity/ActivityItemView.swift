//
//  ActivityItemView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import LDKNode
import SwiftUI

struct ActivityItemView: View {
    let item: Activity
    @EnvironmentObject var currency: CurrencyViewModel

    private var amountPrefix: String {
        switch item {
        case .lightning(let activity):
            return activity.txType == .sent ? "-" : "+"
        case .onchain(let activity):
            return activity.txType == .sent ? "-" : "+"
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                amountView
                Spacer()
                activityTypeIcon
            }
            .padding(.vertical)

            statusSection
                .padding(.vertical)

            Divider()

            timestampSection
                .padding(.vertical)

            Divider()

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var amountView: some View {
        switch item {
        case .lightning(let activity):
            BalanceHeaderView(sats: Int(activity.value), prefix: amountPrefix, showBitcoinSymbol: false)
        case .onchain(let activity):
            BalanceHeaderView(sats: Int(activity.value), prefix: amountPrefix, showBitcoinSymbol: false)
        }
    }

    @ViewBuilder
    private var activityTypeIcon: some View {
        switch item {
        case .lightning:
            Image(systemName: "bolt")
                .font(.title)
                .foregroundColor(.purpleAccent)
                .opacity(0.8)
        case .onchain:
            Image(systemName: "link")
                .font(.title)
                .foregroundColor(.orange)
                .opacity(0.8)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading) {
            Text("Status")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                switch item {
                case .lightning(let activity):
                    lightningStatusView(status: activity.status)
                case .onchain(let activity):
                    onchainStatusView(confirmed: activity.confirmed)
                }
            }
        }
    }

    @ViewBuilder
    private func lightningStatusView(status: PaymentState?) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundColor(.gray)
            Text("Pending")
                .foregroundColor(.gray)
        case .succeeded:
            Image(systemName: "checkmark")
                .foregroundColor(Color.greenAccent)
            Text("Successful")
                .foregroundColor(Color.greenAccent)
        case .failed:
            Image(systemName: "xmark")
                .foregroundColor(.red16)
            Text("Failed")
                .foregroundColor(.red16)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func onchainStatusView(confirmed: Bool?) -> some View {
        if confirmed == true {
            Image(systemName: "checkmark")
                .foregroundColor(Color.greenAccent)
            Text("Confirmed")
                .foregroundColor(Color.greenAccent)
        } else {
            Image(systemName: "clock")
                .foregroundColor(.gray)
            Text("Pending")
                .foregroundColor(.gray)
        }
    }

    @ViewBuilder
    private var timestampSection: some View {
        VStack(alignment: .leading) {
            Text("Date")
                .font(.caption)
                .foregroundColor(.secondary)

            switch item {
            case .lightning(let activity):
                Text(Date(timeIntervalSince1970: TimeInterval(activity.timestamp)).formatted())
                    .font(.caption)
                    .padding(.bottom, 2)
            case .onchain(let activity):
                Text(Date(timeIntervalSince1970: TimeInterval(activity.timestamp)).formatted())
                    .font(.caption)
                    .padding(.bottom, 2)
            }
        }
    }
}

struct ActivityItemView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Lightning Activity Preview
            ActivityItemView(item: .lightning(LightningActivity(
                id: "test-lightning-1",
                txType: .sent,
                status: .succeeded,
                value: 50000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment",
                timestamp: UInt64(Date().timeIntervalSince1970),
                preimage: nil,
                createdAt: nil,
                updatedAt: nil
            )))
            .environmentObject(CurrencyViewModel())
            .previewDisplayName("Lightning Payment")

            // Onchain Activity Preview
            ActivityItemView(item: .onchain(OnchainActivity(
                id: "test-onchain-1",
                txType: .received,
                txId: "abc123",
                value: 100000,
                fee: 500,
                feeRate: 8,
                address: "bc1...",
                confirmed: true,
                timestamp: UInt64(Date().timeIntervalSince1970),
                isBoosted: false,
                isTransfer: false,
                doesExist: true,
                confirmTimestamp: nil,
                channelId: nil,
                transferTxId: nil,
                createdAt: nil,
                updatedAt: nil
            )))
            .environmentObject(CurrencyViewModel())
            .previewDisplayName("Onchain Payment")
        }
    }
}
