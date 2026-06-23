import SwiftUI

/// Staggered hardware-device hero used by the hardware intro sheet: a Trezor bleeding off the
/// left and a blurred Ledger bleeding off the right. Ports bitkit-android's `HwDeviceIllustrations`.
struct HwDeviceIllustrations: View {
    /// Ratios of the 375pt-wide Figma frame. Each device is positioned by its exact top-leading
    /// x and rendered at its natural (non-square) aspect ratio so it bleeds off the correct edge.
    private enum Ratio {
        static let imageHeight: CGFloat = 256.0 / 375.0
        static let trezorWidth: CGFloat = 172.0 / 375.0
        static let ledgerWidth: CGFloat = 203.0 / 375.0
        static let ledgerX: CGFloat = 172.0 / 375.0
        static let stagger: CGFloat = 11.6 / 375.0
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let imageHeight = width * Ratio.imageHeight
            let staggerY = width * Ratio.stagger

            ZStack {
                Image("trezor")
                    .resizable()
                    .scaledToFit()
                    .frame(width: width * Ratio.trezorWidth, height: imageHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .offset(y: staggerY)

                Image("ledger")
                    .resizable()
                    .scaledToFit()
                    .frame(width: width * Ratio.ledgerWidth, height: imageHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .offset(x: width * Ratio.ledgerX, y: -staggerY)
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
