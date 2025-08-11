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
    @State private var showTooltipForIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(0 ..< addresses.count, id: \.self) { index in
                let pair = addresses[index]

                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        CaptionMText(pair.title)
                            .padding(.bottom, 12)

                        BodySSBText(pair.address)
                            .lineLimit(2)
                            .padding(.bottom, 12)

                        HStack(spacing: 8) {
                            CustomButton(
                                title: localizedString("common__copy"),
                                size: .small,
                                icon: Image("copy").foregroundColor(pair.type == .lightning ? .purpleAccent : .brandAccent),
                                shouldExpand: true
                            ) {
                                onCopy(address: pair.address, index: index)
                            }

                            ShareLink(item: URL(string: pair.address)!) {
                                CustomButton(
                                    title: localizedString("common__share"),
                                    size: .small,
                                    icon: Image("share").foregroundColor(pair.type == .lightning ? .purpleAccent : .brandAccent),
                                    shouldExpand: true
                                )
                            }
                        }
                    }

                    // Absolutely positioned tooltip below the address text
                    if showTooltipForIndex == index {
                        VStack {
                            Spacer()
                                .frame(height: 60) // Position below address text

                            Tooltip(text: localizedString("wallet__receive_copied"))
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(32)
        .background(Color.white06)
        .cornerRadius(8)
    }

    private func onCopy(address: String, index: Int) {
        UIPasteboard.general.string = address
        Haptics.play(.copiedToClipboard)

        // Show tooltip for this specific address
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showTooltipForIndex = index
        }

        // Hide tooltip after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                showTooltipForIndex = nil
            }
        }
    }
}

#Preview {
    CopyAddressCard(addresses: [
        CopyAddressPair(title: "On-chain Address", address: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", type: .onchain),
        CopyAddressPair(
            title: "Lightning Invoice", address: "lnbc1500n1p3hk3sppp5k54t9c4p4u4tdgj0y8tqjp3kzjak8jtr0fwvnl2dpl5pvrm9gxsdqqcqzpgxqyz5vqsp5",
            type: .lightning),
    ])
    .preferredColorScheme(.dark)
}
