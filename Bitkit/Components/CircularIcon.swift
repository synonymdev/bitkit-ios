import SwiftUI

struct CircularIcon: View {
    let icon: Image
    let iconColor: Color
    let backgroundColor: Color
    let size: CGFloat

    init(icon: String, iconColor: Color, backgroundColor: Color, size: CGFloat = 32) {
        self.icon = Image(icon).resizable()
        self.iconColor = iconColor
        self.backgroundColor = backgroundColor
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
            icon
                .foregroundColor(iconColor)
                .frame(width: size * 0.5, height: size * 0.5)
        }
        .frame(width: size, height: size)
    }
}
