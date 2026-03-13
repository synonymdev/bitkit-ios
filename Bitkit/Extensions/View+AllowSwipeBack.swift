import SwiftUI

extension View {
    /// Controls whether the interactive swipe-back gesture is enabled on this screen.
    /// Use `.allowSwipeBack(false)` on screens that use a custom header without a back button
    /// (e.g. `SheetHeader` with default `showBackButton: false`) so users can't swipe to dismiss.
    /// Default is `true`; only apply this modifier when you want to disable the gesture.
    func allowSwipeBack(_ allowed: Bool) -> some View {
        modifier(AllowSwipeBackModifier(allowed: allowed))
    }
}

private struct AllowSwipeBackModifier: ViewModifier {
    let allowed: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { SwipeBackState.allowSwipeBack = allowed }
            .onDisappear { SwipeBackState.allowSwipeBack = true }
    }
}
