import BitkitCore
import SwiftUI

enum ActivityBannerType {
    case spending
    case savings
}

struct ActivityBanner: View {
    let type: ActivityBannerType
    let remainingDuration: String?

    @State private var innerShadowOpacity: Double = 0.32
    @State private var dropShadowOpacity: Double = 1.0
    @State private var radialGradientOpacity: Double = 0.4
    @State private var borderOpacity: Double = 0.32

    init(type: ActivityBannerType, remainingDuration: String? = nil) {
        self.type = type
        self.remainingDuration = remainingDuration
    }

    private var accentColor: Color {
        type == .spending ? .purpleAccent : .brandAccent
    }

    private var bannerText: String {
        if let duration = remainingDuration {
            return tTodo("TRANSFER READY IN \(duration)")
        } else {
            return tTodo("TRANSFER IN PROGRESS")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image("transfer")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundColor(accentColor)

            Text(bannerText)
                .font(Fonts.black(size: 20))
                .foregroundColor(.textPrimary)
                .kerning(0)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 72)
        .padding(.horizontal, 16)
        .background(
            ZStack {
                // Inner shadow
                RoundedRectangle(cornerRadius: 16)
                    .fill(.shadow(.inner(color: accentColor.opacity(innerShadowOpacity), radius: 40)))
                    .foregroundColor(.black)

                // Linear gradient background
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [accentColor.opacity(0.24), accentColor.opacity(0)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Radial gradient in top left corner
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: accentColor.opacity(radialGradientOpacity), location: 0.0),
                        .init(color: accentColor.opacity(0.0), location: 1.0),
                    ]),
                    center: UnitPoint(x: 0, y: 0),
                    startRadius: 0,
                    endRadius: 160
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(accentColor.opacity(borderOpacity), lineWidth: 1)
        )
        .shadow(color: accentColor.opacity(dropShadowOpacity), radius: 12)
        .task {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                innerShadowOpacity = 0.64
                dropShadowOpacity = 0.0
                radialGradientOpacity = 0.0
                borderOpacity = 1.0
            }
        }
    }
}
