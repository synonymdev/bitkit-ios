import SwiftUI

/// Staggered hardware-device hero used by the hardware intro sheet: a Trezor on the left and a
/// blurred Ledger bleeding off the right. Ports bitkit-android's `HwDeviceIllustrations`.
struct HwDeviceIllustrations: View {
    /// All measurements are expressed as fractions of the Figma design frame's width, so the hero
    /// scales proportionally to whatever width it's given. Each device is rendered at its natural
    /// (non-square) aspect ratio; the Trezor's left bleed is baked into the exported asset, while
    /// the Ledger is offset to bleed off the right edge.
    private enum Layout {
        static let referenceWidth: CGFloat = 375

        static let proportionalHeight: CGFloat = 256 / referenceWidth
        static let trezorProportionalWidth: CGFloat = 172 / referenceWidth
        static let ledgerProportionalWidth: CGFloat = 203 / referenceWidth
        static let ledgerProportionalX: CGFloat = 172 / referenceWidth
        static let proportionalStagger: CGFloat = 11.6 / referenceWidth
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let imageHeight = width * Layout.proportionalHeight
            let staggerY = width * Layout.proportionalStagger

            ZStack {
                Image("trezor-cropped")
                    .resizable()
                    .scaledToFit()
                    .frame(width: width * Layout.trezorProportionalWidth, height: imageHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .offset(y: staggerY)

                Image("ledger")
                    .resizable()
                    .scaledToFit()
                    .frame(width: width * Layout.ledgerProportionalWidth, height: imageHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .offset(x: width * Layout.ledgerProportionalX, y: -staggerY)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    HwDeviceIllustrations()
        .frame(height: 300)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
