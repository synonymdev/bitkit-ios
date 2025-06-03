import SwiftUI

struct CircularIcon: View {
    let content: AnyView
    let backgroundColor: Color
    let size: CGFloat

    // Initializer for string icons
    init(icon: String, iconColor: Color, backgroundColor: Color, size: CGFloat = 32) {
        self.content = AnyView(
            Image(icon)
                .resizable()
                .scaledToFit()
                .foregroundColor(iconColor)
                .frame(width: size * 0.5, height: size * 0.5)
        )
        self.backgroundColor = backgroundColor
        self.size = size
    }

    // Initializer for view icons (direct View parameter)
    init<Icon: View>(icon: Icon, backgroundColor: Color, size: CGFloat = 32) {
        self.content = AnyView(icon)
        self.backgroundColor = backgroundColor
        self.size = size
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(backgroundColor)
                    .frame(width: size, height: size)
            )
    }
}
