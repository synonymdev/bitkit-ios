import SwiftUI

extension View {
    /// Applies the standard sheet gradient over the given base color. Default base is black;
    func sheetBackground(base: Color = .black) -> some View {
        modifier(SheetBackgroundModifier(base: base, applyGradient: true))
    }
}

struct SheetBackgroundModifier: ViewModifier {
    let base: Color
    let applyGradient: Bool

    func body(content: Content) -> some View {
        if applyGradient {
            content
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.012)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .background(base)
        } else {
            content.background(base)
        }
    }
}
