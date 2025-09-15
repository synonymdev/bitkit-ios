import SwiftUI

struct RectangleButton: View {
    let icon: String
    let iconColor: Color
    let title: String
    let action: () async -> Void
    let trailingContent: AnyView?
    let isDisabled: Bool
    let testID: String

    @State private var isPressed = false

    init(
        icon: String,
        iconColor: Color = .purpleAccent,
        title: String,
        trailingContent: (any View)? = nil,
        isDisabled: Bool = false,
        testID: String,
        action: @escaping () async -> Void
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.trailingContent = trailingContent.map { AnyView($0) }
        self.isDisabled = isDisabled
        self.testID = testID
        self.action = action
    }

    var body: some View {
        Button {
            guard !isDisabled else { return }

            Haptics.play(.medium)

            Task { @MainActor in
                await action()
            }
        } label: {
            HStack(spacing: 16) {
                CircularIcon(icon: icon, iconColor: iconColor, backgroundColor: .black, size: 40)

                BodyMSBText(title)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let trailingContent {
                    trailingContent
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .padding(.horizontal, 16)
            .background(backgroundColor)
            .cornerRadius(16)
            .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .accessibilityIdentifier(testID)
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

    private var backgroundColor: Color {
        return isPressed ? .gray5 : .gray6
    }
}
