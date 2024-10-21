//
//  CopyAddressCard.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import SwiftUI

struct CopyAddressCard: View {
    let title: String
    let address: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.title2)
                .padding(.bottom)

            // Ellipse the address if it's too long
            Text(address.count > 40 ? address.prefix(35) + "..." : address)
                .font(.caption)
                .padding(.bottom)

            HStack {
                Button("Copy") {
                    UIPasteboard.general.string = address
                    Haptics.play(.copiedToClipboard)
                }
                .padding(.horizontal)

                if #available(iOS 16.0, *) {
                    ShareLink(item: URL(string: address)!) {
                        Text("Share")
                    }
                    .padding(.horizontal)
                } else {
                    // TODO: Add share sheet for iOS 15
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.gray.opacity(0.25))
        .cornerRadius(10)
    }
}

#Preview {
    CopyAddressCard(title: "On-chain Address", address: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")
}
