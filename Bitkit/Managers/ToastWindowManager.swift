import SwiftUI
import UIKit

@MainActor
class ToastWindowManager: ObservableObject {
    static let shared = ToastWindowManager()

    private var toastWindow: PassThroughWindow?
    private var toastHostingController: UIHostingController<ToastWindowView>?

    @Published var currentToast: Toast?

    private init() {
        // Set up the window when the app starts
        DispatchQueue.main.async {
            self.setupToastWindow()
        }
    }

    func showToast(_ toast: Toast) {
        // Dismiss any existing toast first
        hideToast()

        // Show the toast with animation
        withAnimation(.easeInOut(duration: 0.4)) {
            currentToast = toast
        }

        // Auto-hide if needed
        if toast.autoHide {
            DispatchQueue.main.asyncAfter(deadline: .now() + toast.visibilityTime) {
                withAnimation(.easeInOut(duration: 0.4)) {
                    self.currentToast = nil
                }
            }
        }
    }

    func hideToast() {
        withAnimation(.easeInOut(duration: 0.4)) {
            currentToast = nil
        }
    }

    private func setupToastWindow() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return
        }

        let window = PassThroughWindow(windowScene: windowScene)
        window.windowLevel = UIWindow.Level.alert + 1 // Above alerts and sheets
        window.backgroundColor = .clear
        window.isHidden = false

        let toastView = ToastWindowView(toastManager: self)
        let hostingController = UIHostingController(rootView: toastView)
        hostingController.view.backgroundColor = .clear

        window.rootViewController = hostingController

        self.toastWindow = window
        self.toastHostingController = hostingController
    }
}

// Custom window that only intercepts touches on interactive elements
class PassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)

        // If the hit view is the root view controller's view (the background),
        // return nil to pass the touch through to the underlying window
        if hitView == rootViewController?.view {
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
                    ToastView(toast: toast, onDismiss: toastManager.hideToast)
                        .padding(.horizontal)
                        .allowsHitTesting(true) // Only the toast itself can be tapped
                    Spacer()
                        .allowsHitTesting(false) // Spacer doesn't intercept touches
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: toastManager.currentToast)
        .preferredColorScheme(.dark) // Force dark color scheme
    }
}
