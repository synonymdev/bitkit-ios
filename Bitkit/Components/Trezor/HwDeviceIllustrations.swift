import SwiftUI

/// Staggered hardware-device hero used by the hardware intro sheet: a Trezor bleeding off the
/// left and a blurred Ledger bleeding off the right. Ports bitkit-android's `HwDeviceIllustrations`.
struct HwDeviceIllustrations: View {
    private enum Ratio {
        static let imageSize: CGFloat = 256.0 / 375.0
        static let trezorBleed: CGFloat = 84.0 / 375.0
        static let ledgerBleed: CGFloat = 53.0 / 375.0
        static let stagger: CGFloat = 12.0 / 375.0
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let imageSize = width * Ratio.imageSize
            let staggerY = width * Ratio.stagger

            ZStack {
                Image("trezor")
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageSize, height: imageSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .offset(x: -width * Ratio.trezorBleed, y: staggerY)

                Image("ledger")
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageSize, height: imageSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .offset(x: width * Ratio.ledgerBleed, y: -staggerY)
                    .blur(radius: 16)
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
