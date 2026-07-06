import SwiftUI

/// The Figma "Loading Animation" hardware ring: a dashed outer ring and inner ring counter-rotating
/// around a set of arrows.
struct HwSearchingAnimation: View {
    /// Diameter of the loading visual (outer dashed ring).
    private let canvasSize: CGFloat = 280

    /// Arrows width as a fraction of the loader — 256 in the 311-wide Figma HW ring.
    private let arrowsRatio: CGFloat = 256.0 / 311.0

    /// Inner dashed-ring width as a fraction of the loader — 207 in the 311-wide Figma HW ring.
    private let innerRingRatio: CGFloat = 207.0 / 311.0

    /// Seconds per full ring turn (both rings counter-rotate one turn every 2s).
    private let ringSpin: Double = 2

    /// Seconds per full arrows turn.
    private let arrowsSpin: Double = 4

    @State private var animate = false

    var body: some View {
        ZStack {
            Image("hw-searching-ring")
                .resizable()
                .scaledToFit()
                .frame(width: canvasSize, height: canvasSize)
                .rotationEffect(.degrees(animate ? -360 : 0))
                .animation(.linear(duration: ringSpin).repeatForever(autoreverses: false), value: animate)

            Image("hw-searching-ring-inner")
                .resizable()
                .scaledToFit()
                .frame(width: canvasSize * innerRingRatio, height: canvasSize * innerRingRatio)
                .rotationEffect(.degrees(animate ? 360 : 0))
                .animation(.linear(duration: ringSpin).repeatForever(autoreverses: false), value: animate)

            Image("hw-searching-arrows")
                .resizable()
                .scaledToFit()
                .frame(width: canvasSize * arrowsRatio, height: canvasSize * arrowsRatio)
                .rotationEffect(.degrees(animate ? -360 : 0))
                .animation(.linear(duration: arrowsSpin).repeatForever(autoreverses: false), value: animate)
        }
        .frame(width: canvasSize, height: canvasSize)
        .onAppear { animate = true }
    }
}

#Preview {
    HwSearchingAnimation()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
