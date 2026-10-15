import SwiftUI

struct SheetBackgroundPreferenceKey: PreferenceKey {
    static let defaultValue: Color? = nil

    static func reduce(value: inout Color?, nextValue: () -> Color?) {
        value = nextValue() ?? value
    }
}

struct SheetDragIndicatorInsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

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
        content
            .background {
                LinearGradient(
                    gradient: Gradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.012)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(applyGradient ? 1 : 0)
            }
            .background(base)
    }
}
