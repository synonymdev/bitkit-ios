//
//  Haptics.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/09.
//

import CoreHaptics
import UIKit

class Haptics {
    private static var engine: CHHapticEngine?

    static func play(_ feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle, withDelay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + withDelay) {
            let i = UIImpactFeedbackGenerator(style: feedbackStyle)
            i.prepare()
            i.impactOccurred()
        }
    }

    static func notify(_ feedbackType: UINotificationFeedbackGenerator.FeedbackType, withDelay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + withDelay) {
            UINotificationFeedbackGenerator().notificationOccurred(feedbackType)
        }
    }

    static func rocket(duration: Double = 0.5, completion: (() -> Void)? = nil) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            Logger.error("Device doesn't support haptics")
            completion?()
            return
        }

        do {
            engine = try CHHapticEngine()
            
            engine?.resetHandler = { [weak engine] in
                Logger.warn("Restarting Haptic engine...")
                do {
                    try engine?.start()
                } catch {
                    Logger.error("Failed to restart engine: \(error)")
                }
            }
            
            engine?.stoppedHandler = { reason in
                Logger.warn("Haptic engine stopped: \(reason)")
                completion?()
            }
            
            try engine?.start()
            
            var events = [CHHapticEvent]()
            
            // Start soft (approaching)
            let approachIntensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.15)
            let approachSharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)
            events.append(CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [approachIntensity, approachSharpness],
                                      relativeTime: 0,
                                      duration: duration * 0.3))
            
            // Middle section split into three parts
            // First part of peak (building up)
            let peak1Intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.25)
            let peak1Sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
            events.append(CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [peak1Intensity, peak1Sharpness],
                                      relativeTime: duration * 0.3,
                                      duration: duration * 0.133))
            
            // Second part of peak (maximum)
            let peak2Intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35)
            let peak2Sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)
            events.append(CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [peak2Intensity, peak2Sharpness],
                                      relativeTime: duration * 0.433,
                                      duration: duration * 0.134))
            
            // Third part of peak (reducing)
            let peak3Intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.25)
            let peak3Sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
            events.append(CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [peak3Intensity, peak3Sharpness],
                                      relativeTime: duration * 0.567,
                                      duration: duration * 0.133))
            
            // Soft ending (flying away)
            let departIntensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.15)
            let departSharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)
            events.append(CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [departIntensity, departSharpness],
                                      relativeTime: duration * 0.7,
                                      duration: duration * 0.3))

            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: 0)
            
            if let completion = completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    completion()
                }
            }
            
        } catch {
            Logger.error("Haptic error: \(error)")
            completion?()
        }
    }
}

// MARK: add aliases for common haptic feedback here
extension UIImpactFeedbackGenerator.FeedbackStyle {
    static var copiedToClipboard: UIImpactFeedbackGenerator.FeedbackStyle { .soft }
    static var pastedFromClipboard: UIImpactFeedbackGenerator.FeedbackStyle { .medium }
    static var scanSuccess: UIImpactFeedbackGenerator.FeedbackStyle { .heavy }
    static var openSheet: UIImpactFeedbackGenerator.FeedbackStyle { .medium }
}
