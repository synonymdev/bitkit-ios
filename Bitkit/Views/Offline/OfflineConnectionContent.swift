import SwiftUI

/// Shared offline content used by both full-screen and sheet variants.
struct OfflineConnectionContent: View {
    private var outerRingRadii: [CGFloat] {
        UIScreen.main.isSmall ? [150] : [200]
    }

    private var innerRingRadii: [CGFloat] {
        UIScreen.main.isSmall ? [100, 50] : [150, 100, 50]
    }

    private var maxRingRadius: CGFloat {
        max(outerRingRadii.max() ?? 0, innerRingRadii.max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack(alignment: .bottom) {
                let ringCanvasHeight = DashedRingsLayer.fittingHeight(maxRadius: maxRingRadius)

                DashedRingsLayer(radii: outerRingRadii)
                    .frame(maxWidth: .infinity)
                    .frame(height: ringCanvasHeight)

                Image("phone")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxHeight: 311)

                DashedRingsLayer(radii: innerRingRadii)
                    .frame(maxWidth: .infinity)
                    .frame(height: ringCanvasHeight)
            }

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("wallet__send_sync_long_title"), accentColor: .yellowAccent)
                    .padding(.top, 32)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                BodyMText(t("wallet__send_sync_long_description"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 32)
            .layoutPriority(1)

            ActivityIndicator(size: 24)
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
        }
    }
}

// MARK: - Dashed Gradient Rings

struct DashedRingsLayer: View {
    let radii: [CGFloat]

    /// Vertical position of ring center in canvas (0 = top). Tuned for bottom-aligned `Image("phone")` with `maxHeight` 311.
    private static let ringCenterYFraction: CGFloat = 0.56

    /// Canvas height so rings are not clipped for `center` at (0.22×width, `ringCenterYFraction`×height).
    static func fittingHeight(maxRadius: CGFloat) -> CGFloat {
        let cy = ringCenterYFraction
        return max(
            maxRadius / cy,
            maxRadius / (1.0 - cy)
        ) + 16
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.22, y: size.height * Self.ringCenterYFraction)

            for radius in radii {
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                var path = Path()
                path.addEllipse(in: rect)

                let gradient = Gradient(stops: [
                    .init(color: Color(white: 0), location: 0),
                    .init(color: Color(white: 0), location: 0.13),
                    .init(color: .yellowAccent, location: 1),
                ])
                let startPoint = CGPoint(x: rect.minX, y: rect.minY)
                let endPoint = CGPoint(x: rect.maxX, y: rect.maxY)

                context.stroke(
                    path,
                    with: .linearGradient(gradient, startPoint: startPoint, endPoint: endPoint),
                    style: StrokeStyle(lineWidth: 1, dash: [8, 8])
                )
            }
        }
        .allowsHitTesting(false)
    }
}
