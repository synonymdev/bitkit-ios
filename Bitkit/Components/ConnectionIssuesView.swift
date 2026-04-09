import SwiftUI

/// A full-screen overlay displayed when the device loses internet connectivity.
/// Shows a phone illustration with animated dashed gradient rings and a loading spinner.
struct ConnectionIssuesView: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: title, showBackButton: false)

            Spacer().frame(height: 24)

            ZStack(alignment: .center) {
                DashedRingsLayer(radii: [200])

                Image("phone")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 311)

                DashedRingsLayer(radii: [150, 100, 50])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DisplayText(
                t("other__connection_issues_title"),
                accentColor: .yellowAccent
            )

            Spacer().frame(height: 8)

            BodyMText(
                t("other__connection_issues_explain"),
                textColor: .white64
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer().frame(height: 24)

            ActivityIndicator()
                .frame(maxWidth: .infinity)

            Spacer().frame(height: 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("ConnectionIssuesView")
    }
}

// MARK: - Dashed Gradient Rings

private struct DashedRingsLayer: View {
    let radii: [CGFloat]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.25, y: size.height * 0.40)

            for radius in radii {
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                var path = Path()
                path.addEllipse(in: rect)

                let gradient = Gradient(colors: [.black, .yellowAccent])
                let startPoint = CGPoint(x: rect.minX, y: rect.minY)
                let endPoint = CGPoint(x: rect.maxX, y: rect.maxY)

                context.stroke(
                    path,
                    with: .linearGradient(gradient, startPoint: startPoint, endPoint: endPoint),
                    style: StrokeStyle(lineWidth: 1, dash: [8, 6])
                )
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - View Modifier

extension View {
    /// Overlays a `ConnectionIssuesView` when the device is offline.
    /// The underlying content remains mounted so navigation state and inputs are preserved.
    func connectionIssuesOverlay(title: String, isOffline: Bool) -> some View {
        ZStack {
            self

            if isOffline {
                ConnectionIssuesView(title: title)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isOffline)
    }
}

// MARK: - Preview

#Preview {
    ConnectionIssuesView(title: "Send Bitcoin")
        .preferredColorScheme(.dark)
}
