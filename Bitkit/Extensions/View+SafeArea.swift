import SwiftUI
import UIKit

// MARK: - Layout constants (header, tab bar, spacing) used for content margins across wallet/home screens

enum ScreenLayout {
    static let headerHeight: CGFloat = 48
    static let headerSpacing: CGFloat = 16
    static let tabBarHeight: CGFloat = 64
    static let bottomSpacing: CGFloat = 32

    /// Safe area top + header + spacing (e.g. HomeScreen, HomeWalletView, HomeWidgetsView)
    static var topPaddingWithSafeArea: CGFloat {
        windowSafeAreaInsets.top + headerHeight + headerSpacing
    }

    /// Header + spacing only, when view is already inside safe area (e.g. SavingsWalletScreen, SpendingWalletScreen)
    static var topPaddingWithoutSafeArea: CGFloat {
        headerHeight + headerSpacing
    }

    /// Safe area bottom + tab bar + spacing
    static var bottomPaddingWithSafeArea: CGFloat {
        windowSafeAreaInsets.bottom + tabBarHeight + bottomSpacing
    }
}

private var hasBottomSafeArea: Bool {
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

/// For phones without a home indicator, we add padding to the bottom of the view
struct BottomSafeAreaPadding: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.bottom, hasBottomSafeArea ? 0 : 16)
    }
}

extension View {
    func bottomSafeAreaPadding() -> some View {
        modifier(BottomSafeAreaPadding())
    }

    func buttonBottomPadding(isFocused: Bool = false) -> some View {
        padding(.bottom, isFocused && hasBottomSafeArea ? 16 : 0)
    }
}

extension UIScreen {
    var isSmall: Bool {
        return UIScreen.screenHeight < 800
    }
}
