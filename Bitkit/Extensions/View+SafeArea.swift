import SwiftUI
import UIKit

private var hasHomeIndicator: Bool {
    windowSafeAreaInsets.bottom > 0
}

/// Key window's safe area insets, or `.zero` if no window is available.
var windowSafeAreaInsets: UIEdgeInsets {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first
    else {
        return .zero
    }
    return window.safeAreaInsets
}

// For phones without a home indicator, we add padding to the bottom of the view
struct BottomSafeAreaPadding: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.bottom, hasHomeIndicator ? 0 : 16)
    }
}

extension View {
    func bottomSafeAreaPadding() -> some View {
        modifier(BottomSafeAreaPadding())
    }

    func buttonBottomPadding(isFocused: Bool = false) -> some View {
        padding(.bottom, isFocused && hasHomeIndicator ? 16 : 0)
    }
}

extension UIScreen {
    var isSmall: Bool {
        return UIScreen.screenHeight < 800
    }
}
