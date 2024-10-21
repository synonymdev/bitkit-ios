//
//  ActivityItemView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import LDKNode
import SwiftUI

struct ActivityItemView: View {
    let item: PaymentDetails

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                if let amountSats = item.amountSats {
                    Text("\(item.direction == .outbound ? "-" : "+") \(amountSats)")
                        .font(.title)
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
                    Text("Confirmed")
                        .foregroundColor(.green)
                case .failed:
                    Image(systemName: "xmark")
                        .foregroundColor(.red)
                    Text("Failed")
                }
            }

            Divider()

            Text("Date")
            Text(Date(timeIntervalSince1970: TimeInterval(item.latestUpdateTimestamp)).formatted())
                .font(.caption)
                .padding(.bottom, 2)

            Divider()

            Spacer()
        }
        .padding()
    }
}

#Preview {
    ActivityItemView(item: PaymentDetails(id: PaymentId(), kind: .onchain, amountMsat: 1000, direction: .outbound, status: .pending, latestUpdateTimestamp: 0))
}
