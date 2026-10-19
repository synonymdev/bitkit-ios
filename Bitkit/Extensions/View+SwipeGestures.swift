import SwiftUI

// Swipe-to-go-back (nav stack) and horizontal swipes between `SegmentedControl` tabs.

extension View {
    /// Controls whether the interactive swipe-back gesture is enabled on this screen.
    /// Use `.allowSwipeBack(false)` on screens that use a custom header without a back button
    /// (e.g. `SheetHeader` with default `showBackButton: false`) so users can't swipe to dismiss.
    /// Default is `true`; only apply this modifier when you want to disable the gesture.
    func allowSwipeBack(_ allowed: Bool) -> some View {
        modifier(AllowSwipeBackModifier(allowed: allowed))
    }

    // MARK: Segmented tab swipes

    /// Swipe left/right to move between adjacent tabs (same order as `T.allCases` / `SegmentedControl`).
    /// Pass `tabs` when the control shows only some cases, in its display order.
    /// Pass `simultaneous` inside a sheet, so a vertical drag still reaches the sheet's swipe-to-dismiss.
    @ViewBuilder
    func swipeSegmentedTabs<T: Hashable & CaseIterable>(
        selection: Binding<T>,
        tabs visibleTabs: [T]? = nil,
        minimumDragDistance: CGFloat = 20,
        swipeThreshold: CGFloat = 50,
        animation: Animation = .easeInOut(duration: 0.2),
        simultaneous: Bool = false
    ) -> some View {
        let drag = DragGesture(minimumDistance: minimumDragDistance, coordinateSpace: .local)
            .onEnded { value in
                let horizontalAmount = value.translation.width
                let verticalAmount = value.translation.height
                guard abs(horizontalAmount) > abs(verticalAmount) else { return }

                let tabs = visibleTabs ?? Array(T.allCases)
                guard let currentIndex = tabs.firstIndex(of: selection.wrappedValue) else { return }

                if horizontalAmount < -swipeThreshold, currentIndex < tabs.count - 1 {
                    withAnimation(animation) {
                        selection.wrappedValue = tabs[currentIndex + 1]
                    }
                } else if horizontalAmount > swipeThreshold, currentIndex > 0 {
                    withAnimation(animation) {
                        selection.wrappedValue = tabs[currentIndex - 1]
                    }
                }
            }
        if simultaneous {
            simultaneousGesture(drag)
        } else {
            highPriorityGesture(drag)
        }
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
