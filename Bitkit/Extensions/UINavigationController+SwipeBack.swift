import UIKit

/// Shared state for swipe-back gesture. Views can set this via the `.allowSwipeBack(_:)` modifier
/// to disable the gesture on screens that don't show a back button (e.g. SheetHeader without back).
enum SwipeBackState {
    /// When false, the interactive pop gesture is disabled. Set by views that hide the back button.
    static var allowSwipeBack: Bool = true
}

/// Re-enables the interactive swipe-back gesture when the navigation bar is hidden
/// (e.g. when using a custom NavigationBar with `.navigationBarHidden(true)`).
/// Without this, the system disables the gesture when the bar is hidden.
/// Use `.allowSwipeBack(false)` on views that don't show a back button to disable the gesture there.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Only allow swipe-back when not at root — avoids iOS 17+ freeze when re-pushing after swiping to root
        guard viewControllers.count > 1 else { return false }
        return SwipeBackState.allowSwipeBack
    }
}
