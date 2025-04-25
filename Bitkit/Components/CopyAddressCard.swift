//
//  CopyAddressCard.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import SwiftUI

struct CopyAddressPair {
    enum AddressType {
        case onchain
        case lightning
    }
    
    let title: String
    let address: String
    let type: AddressType
}

struct CopyAddressCard: View {
    let addresses: [CopyAddressPair]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(0..<addresses.count, id: \.self) { index in
                let pair = addresses[index]
                
                VStack(alignment: .leading) {
                    CaptionText(pair.title.uppercased())
                        .padding(.bottom)

                    // Ellipse the address if it's too long
                    BodySSBText((pair.address.count > 32 ? pair.address.prefix(27) + "..." : pair.address).uppercased())
                        .padding(.bottom)

                    HStack {
                        CustomButton(
                            title: NSLocalizedString("common__copy", comment: ""),
                            size: .small,
                            icon: Image(pair.type == .lightning ? "copy-purple" : "copy-brand")
                        ) {
                            UIPasteboard.general.string = pair.address
                            Haptics.play(.copiedToClipboard)
                        }

                        if #available(iOS 16.0, *) {
                            ShareLink(item: URL(string: pair.address)!) {
                                CustomButton(
                                    title: NSLocalizedString("common__share", comment: ""),
                                    size: .small,
                                    icon: Image(pair.type == .lightning ? "share-purple" : "share-brand")
                                )
                            }
                        } else {
                            // TODO: Add share sheet for iOS 15
                        }
                    }
                }
                
                if index < addresses.count - 1 {
                    VStack {}.frame(height: 12)
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
    CopyAddressCard(addresses: [
        CopyAddressPair(title: "On-chain Address", address: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", type: .onchain),
        CopyAddressPair(title: "Lightning Invoice", address: "lnbc1500n1p3hk3sppp5k54t9c4p4u4tdgj0y8tqjp3kzjak8jtr0fwvnl2dpl5pvrm9gxsdqqcqzpgxqyz5vqsp5", type: .lightning)
    ])
    .preferredColorScheme(.dark)
}
