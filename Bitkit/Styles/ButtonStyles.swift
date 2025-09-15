import SwiftUI

struct NoAnimationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct ButtonGradient: View {
    let isPressed: Bool

    init(isPressed: Bool = false) {
        self.isPressed = isPressed
    }

    var body: some View {
        let colors: [Color] = isPressed ?
            [Color(hex: 0x3A3A3A), Color(hex: 0x2A2A2A)] :
            [Color(hex: 0x2A2A2A), Color(hex: 0x1C1C1C)]

        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}
