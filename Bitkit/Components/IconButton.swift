import SwiftUI

private struct IconButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed in
                isPressed = pressed
            }
    }
}

struct IconButton<Icon: View>: View {
    let icon: Icon
    let size: CGFloat
    let action: () -> Void

    @State private var isPressed = false

    init(icon: Icon, size: CGFloat = 48, action: @escaping () -> Void) {
        self.icon = icon
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon
        }
        .frame(width: size, height: size)
        .background(isPressed ? Color.white32 : Color.white16)
        .cornerRadius(size / 2)
        .contentShape(Rectangle())
        .buttonStyle(
            IconButtonStyle(isPressed: $isPressed)
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                Haptics.play(.buttonTap)
            }
        )
    }
}
