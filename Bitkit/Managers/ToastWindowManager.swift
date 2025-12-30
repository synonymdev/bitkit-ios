import SwiftUI
import UIKit

@MainActor
class ToastWindowManager: ObservableObject {
    static let shared = ToastWindowManager()

    private var toastWindow: PassThroughWindow?
    private var toastHostingController: UIHostingController<ToastWindowView>?

    func updateToastFrame(globalFrame: CGRect) {
        guard let window = toastWindow else { return }
        // Convert from global (screen) coordinates to window coordinates
        let windowOrigin = window.convert(CGPoint.zero, to: nil)
        let convertedFrame = CGRect(
            origin: CGPoint(
                x: globalFrame.origin.x - windowOrigin.x,
                y: globalFrame.origin.y - windowOrigin.y
            ),
            size: globalFrame.size
        )
        window.toastFrame = convertedFrame
    }

    @Published var currentToast: Toast?
    private var autoHideTask: Task<Void, Never>?
    private var autoHideStartTime: Date?
    private var autoHideDuration: Double = 0

    private init() {
        // Set up the window when the app starts
        DispatchQueue.main.async {
            self.setupToastWindow()
        }
    }

    func showToast(_ toast: Toast) {
        // Ensure window is set up before showing toast
        ensureWindowExists()

        // If window still doesn't exist after trying to set it up, log and return
        guard let window = toastWindow else {
            Logger.error("ToastWindowManager: Cannot show toast - window not available")
            return
        }

        // Dismiss any existing toast first
        cancelAutoHide()
        window.hasToast = false
        window.toastFrame = .zero

        // Update window's toast state for hit testing
        window.hasToast = true

        // Show the toast with animation
        withAnimation(.easeInOut(duration: 0.4)) {
            currentToast = toast
        }

        // Auto-hide if needed
        if toast.autoHide {
            scheduleAutoHide(after: toast.visibilityTime)
        }
    }

    func hideToast() {
        cancelAutoHide()
        toastWindow?.hasToast = false
        withAnimation(.easeInOut(duration: 0.4)) {
            currentToast = nil
        }
        // Clear frame after animation completes to avoid race conditions during animation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(0.4 * 1_000_000_000))
            self?.toastWindow?.toastFrame = .zero
        }
    }

    func pauseAutoHide() {
        guard autoHideStartTime != nil else { return } // No active auto-hide to pause
        cancelAutoHide()

        // Calculate remaining time
        if let startTime = autoHideStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = max(0, autoHideDuration - elapsed)
            autoHideDuration = remaining
            autoHideStartTime = nil
        }
    }

    func resumeAutoHide() {
        guard let toast = currentToast, toast.autoHide, autoHideStartTime == nil else { return }
        // Use remaining time if available, otherwise use full duration
        let delay = autoHideDuration > 0 ? autoHideDuration : toast.visibilityTime
        scheduleAutoHide(after: delay)
    }

    private func scheduleAutoHide(after delay: Double) {
        cancelAutoHide()
        autoHideStartTime = Date()
        autoHideDuration = delay

        // Use Task instead of DispatchWorkItem for better SwiftUI integration
        autoHideTask = Task { @MainActor [weak self] in
            // Sleep for the delay duration
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            // Check if task was cancelled or toast no longer exists
            guard let self, !Task.isCancelled, currentToast != nil else { return }

            // Atomically update both hasToast and toastFrame
            toastWindow?.hasToast = false

            withAnimation(.easeInOut(duration: 0.4)) {
                self.currentToast = nil
            }

            // Clear frame after animation completes to avoid race conditions during animation
            try? await Task.sleep(nanoseconds: UInt64(0.4 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            toastWindow?.toastFrame = .zero

            autoHideStartTime = nil
            autoHideDuration = 0
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        autoHideStartTime = nil
        autoHideDuration = 0
    }

    private func ensureWindowExists() {
        // Check if window already exists and is still valid
        if let existingWindow = toastWindow,
           existingWindow.windowScene != nil,
           !existingWindow.isHidden
        {
            return
        }

        // Window doesn't exist or is invalid, try to set it up
        setupToastWindow()
    }

    private func setupToastWindow() {
        // Try to find an active window scene
        guard let windowScene = findActiveWindowScene() else {
            Logger.warn("ToastWindowManager: No active window scene available")
            return
        }

        // Clean up old window if it exists
        if let oldWindow = toastWindow {
            oldWindow.isHidden = true
            oldWindow.rootViewController = nil
        }

        let window = PassThroughWindow(windowScene: windowScene)
        window.windowLevel = UIWindow.Level.alert + 1 // Above alerts and sheets
        window.backgroundColor = .clear
        window.isHidden = false

        let toastView = ToastWindowView(toastManager: self)
        let hostingController = UIHostingController(rootView: toastView)
        hostingController.view.backgroundColor = .clear

        window.rootViewController = hostingController

        toastWindow = window
        toastHostingController = hostingController
    }

    private func findActiveWindowScene() -> UIWindowScene? {
        // Try to find an active window scene from connected scenes
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               windowScene.activationState == .foregroundActive || windowScene.activationState == .foregroundInactive
            {
                return windowScene
            }
        }

        // Fallback to any window scene if no active one found
        return UIApplication.shared.connectedScenes.first as? UIWindowScene
    }
}

// Custom window that only intercepts touches on interactive elements
class PassThroughWindow: UIWindow {
    var hasToast: Bool = false
    var toastFrame: CGRect = .zero

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)

        // If the hit view is the root view controller's view (the background)
        if hitView == rootViewController?.view {
            // If a toast is showing, check if touch is within the toast's frame
            if hasToast && !toastFrame.isEmpty && toastFrame.contains(point) {
                return rootViewController?.view
            }

            return nil
        }

        return hitView
    }
}

struct ToastWindowView: View {
    @ObservedObject var toastManager: ToastWindowManager

    var body: some View {
        ZStack {
            // Transparent background that won't intercept touches
            Color.clear
                .allowsHitTesting(false)

            if let toast = toastManager.currentToast {
                VStack {
                    ToastView(
                        toast: toast,
                        onDismiss: toastManager.hideToast,
                        onDragStart: toastManager.pauseAutoHide,
                        onDragEnd: toastManager.resumeAutoHide
                    )
                    .padding(.horizontal)
                    .allowsHitTesting(true) // Only the toast itself can be tapped
                    .overlay(
                        GeometryReader { toastGeometry in
                            Color.clear
                                .preference(
                                    key: ToastFramePreferenceKey.self,
                                    value: toastGeometry.frame(in: .global)
                                )
                        }
                    )

                    Spacer()
                        .allowsHitTesting(false) // Spacer doesn't intercept touches
                }
                .id(toast.id)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onPreferenceChange(ToastFramePreferenceKey.self) { frame in
            // Only update if frame is not empty (valid frame from GeometryReader)
            guard !frame.isEmpty else { return }
            toastManager.updateToastFrame(globalFrame: frame)
        }
        .animation(.easeInOut(duration: 0.4), value: toastManager.currentToast)
        .preferredColorScheme(.dark) // Force dark color scheme
    }
}

private struct ToastFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
