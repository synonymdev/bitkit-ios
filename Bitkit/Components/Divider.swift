import SwiftUI

enum DividerType {
    case horizontal
    case vertical
}

struct CustomDivider: View {
    let color: Color
    let type: DividerType

    init(color: Color = .white.opacity(0.1), type: DividerType = .horizontal) {
        self.color = color
        self.type = type
    }

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: type == .horizontal ? nil : 1, height: type == .horizontal ? 1 : nil)
    }
}
