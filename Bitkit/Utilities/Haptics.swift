//
//  Haptics.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/09.
//

import UIKit

class Haptics {
    static func play(_ feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle, withDelay: Double = 0) {
        let i = UIImpactFeedbackGenerator(style: feedbackStyle)
        i.prepare()

        DispatchQueue.main.asyncAfter(deadline: .now() + withDelay) {
            i.impactOccurred()
        }
    }

    static func notify(_ feedbackType: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(feedbackType)
    }
}

// MARK: add aliases for common haptic feedback here
extension UIImpactFeedbackGenerator.FeedbackStyle {
    static var copiedToClipboard: UIImpactFeedbackGenerator.FeedbackStyle { .soft }
    static var pastedFromClipboard: UIImpactFeedbackGenerator.FeedbackStyle { .soft }
    static var scanSuccess: UIImpactFeedbackGenerator.FeedbackStyle { .heavy }
    static var openSheet: UIImpactFeedbackGenerator.FeedbackStyle { .medium }
}
