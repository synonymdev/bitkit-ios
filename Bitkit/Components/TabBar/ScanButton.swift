import SwiftUI

struct ScanButton: View {
    let action: () -> Void

    @State private var isPressed: Bool = false

    init(
        action: @escaping () -> Void
    ) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image("scan")
                .resizable()
                .frame(width: 32, height: 32)
                .frame(width: 64, height: 64)
                .background(Circle().fill(background))
                .foregroundColor(.gray1)
        }
        .shadow(color: Color.gray2, radius: 0, x: 0, y: -1)
        .shadow(color: Color.black.opacity(0.25), radius: 25, x: 0, y: 20)
        .overlay(
            Circle()
                .strokeBorder(Color.black, lineWidth: 2)
                .mask(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        )
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

    private var background: Color {
        return isPressed ? Color.gray6 : Color.gray7
    }
}
