import SwiftUI
import UIKit

@Observable
final class KeyboardManager {
    var isPresented = false
    var height: CGFloat = 0

    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        let willShowToken = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            height = frame?.height ?? 0
            isPresented = true
        }

        let willHideToken = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            height = 0
            isPresented = false
        }

        notificationTokens = [willShowToken, willHideToken]
    }

    deinit {
        // Remove observers to prevent memory leaks
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
