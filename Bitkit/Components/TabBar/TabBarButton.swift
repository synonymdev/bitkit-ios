import SwiftUI

struct TabBarButton: View {
    enum Variant {
        case left
        case right
    }

    let title: String
    let icon: String
    let variant: Variant
    let action: () -> Void

    @State private var isPressed: Bool = false

    init(
        title: String,
        icon: String,
        variant: Variant = .left,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.variant = variant
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundColor(.textPrimary)

                BodySSBText(title, textColor: .textPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .padding(.leading, variant == .left ? 16 : 32)
            .padding(.trailing, variant == .right ? 16 : 32)
            .background(ButtonGradient(isPressed: isPressed))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: variant == .right ? 0 : 64,
                    bottomLeadingRadius: variant == .right ? 0 : 64,
                    bottomTrailingRadius: variant == .left ? 0 : 64,
                    topTrailingRadius: variant == .left ? 0 : 64
                )
            )
            .shadow(color: shadowColor, radius: 0, x: 0, y: -1)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoAnimationButtonStyle())
        .pressEvents(
            onPress: {
                isPressed = true
            },
            onRelease: {
                isPressed = false
            }
        )
    }

    private var shadowColor: Color {
        return isPressed ? Color.white.opacity(0.4) : Color.white.opacity(0.25)
    }
}
