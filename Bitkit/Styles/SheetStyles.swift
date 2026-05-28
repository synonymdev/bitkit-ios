import SwiftUI

extension View {
    /// Applies the standard sheet gradient over the given base color. Default base is black;
    /// the v61 widgets sheet uses gray7.
    func sheetBackground(base: Color = .black) -> some View {
        modifier(SheetBackgroundModifier(base: base, applyGradient: true))
    }
}

/// Sheet fill. When `applyGradient` is true a subtle white top-down gradient is layered over
/// the base color (the default chrome). The widgets sheet sets it false to match Figma's solid
/// gray7 modal (the gradient would otherwise lighten it).
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
