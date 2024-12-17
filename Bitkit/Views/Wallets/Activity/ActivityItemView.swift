//
//  ActivityItemView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import LDKNode
import SwiftUI

// TODO: replace LDK node types
struct ActivityItemView: View {
    let item: PaymentDetails

    private var amountPrefix: String {
        item.direction == .outbound ? "-" : "+"
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                if let amountSats = item.amountSats {
                    BalanceHeaderView(sats: Int(amountSats), prefix: amountPrefix, showBitcoinSymbol: false)
                }

                Spacer()

                if item.kind == .onchain {
                    Image(systemName: "link")
                        .font(.title)
                        .foregroundColor(.orange)
                        .opacity(0.8)
                } else {
                    Image(systemName: "bolt")
                        .font(.title)
                        .foregroundColor(.purple)
                        .opacity(0.8)
                }
            }
            .padding(.vertical)

            VStack(alignment: .leading) {
                Text("Status")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    switch item.status {
                    case .pending:
                        Image(systemName: "clock")
                            .foregroundColor(.gray)
                        Text("Pending")
                            .foregroundColor(.gray)
                    case .succeeded:
                        Image(systemName: "checkmark")
                            .foregroundColor(.green)
                        Text("Successful")
                            .foregroundColor(.green)
                    case .failed:
                        Image(systemName: "xmark")
                            .foregroundColor(.red)
                        Text("Failed")
                    }
                }
            }
            .padding(.vertical)

            Divider()

            VStack(alignment: .leading) {
                Text("Date")
                Text(Date(timeIntervalSince1970: TimeInterval(item.latestUpdateTimestamp)).formatted())
                    .font(.caption)
                    .padding(.bottom, 2)
            }
            .padding(.vertical)

            Divider()

            Spacer()
        }
        .padding()
    }
}

#Preview {
    ActivityItemView(item: PaymentDetails(id: PaymentId(), kind: .onchain, amountMsat: 1000, direction: .outbound, status: .pending, latestUpdateTimestamp: 0))
}
