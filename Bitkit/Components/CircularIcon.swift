import SwiftUI

struct CircularIcon: View {
    let icon: Image
    let iconColor: Color
    let backgroundColor: Color

    init(icon: String, iconColor: Color, backgroundColor: Color) {
        self.icon = Image(icon).resizable()
        self.iconColor = iconColor
        self.backgroundColor = backgroundColor
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
            icon
                .foregroundColor(iconColor)
                .frame(width: 16, height: 16)
        }
        .frame(width: 32, height: 32)
    }
}
