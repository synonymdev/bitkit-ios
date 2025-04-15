import SwiftUI
import UIKit

struct BottomSafeAreaPadding: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.bottom, UIDevice.current.hasHomeIndicator ? 0 : 16)
    }
}

extension View {
    func bottomSafeAreaPadding() -> some View {
        modifier(BottomSafeAreaPadding())
    }
}

extension UIDevice {
    var hasHomeIndicator: Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = windowScene.windows.first
        else {
            return false
        }
        return window.safeAreaInsets.bottom > 0
    }
}
