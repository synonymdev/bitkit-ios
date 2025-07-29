import SwiftUI
import UIKit

// For phones without a home indicator, we add padding to the bottom of the view
struct BottomSafeAreaPadding: ViewModifier {
    var hasHomeIndicator: Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = windowScene.windows.first
        else {
            return false
        }
        return window.safeAreaInsets.bottom > 0
    }

    func body(content: Content) -> some View {
        content
            .padding(.bottom, hasHomeIndicator ? 0 : 16)
    }
}

extension View {
    func bottomSafeAreaPadding() -> some View {
        modifier(BottomSafeAreaPadding())
    }
}

extension UIScreen {
    var isSmall: Bool {
        return UIScreen.screenHeight < 800
    }
}
