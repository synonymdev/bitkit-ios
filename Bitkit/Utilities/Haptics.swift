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
    private static var player: CHHapticPatternPlayer?
    private static var lastHapticTime: TimeInterval = 0
    private static let minimumHapticInterval: TimeInterval = 0.1 // 100ms

    private static func shouldAllowHaptic() -> Bool {
        let currentTime = Date().timeIntervalSince1970
        let timeSinceLastHaptic = currentTime - lastHapticTime
        if timeSinceLastHaptic >= minimumHapticInterval {
            lastHapticTime = currentTime
            return true
        }
        return false
    }

    static func play(_ feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle, withDelay: Double = 0) {
        guard shouldAllowHaptic() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + withDelay) {
            let i = UIImpactFeedbackGenerator(style: feedbackStyle)
            i.prepare()
            i.impactOccurred()
        }
    }

    static func notify(_ feedbackType: UINotificationFeedbackGenerator.FeedbackType, withDelay: Double = 0) {
        guard shouldAllowHaptic() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + withDelay) {
            UINotificationFeedbackGenerator().notificationOccurred(feedbackType)
        }
    }

    static func rocket(duration: Double = 0.5) {
        do {
            try startEngine()
            
            // Stop any existing haptic pattern
            try player?.stop(atTime: 0)
            
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
            player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: 0)
        } catch HapticsError.hapticNotSupported {
            return
        } catch {
            Logger.warn(error, context: "Haptics error")
        }
    }

    static func stopHaptics() {
        do {
            try player?.stop(atTime: 0)
            player = nil
        } catch {
            Logger.warn(error, context: "Failed to stop haptics")
        }
    }

    private static func startEngine() throws {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            throw HapticsError.hapticNotSupported
        }

        // Only create new engine if one doesn't exist
        if engine == nil {
            engine = try CHHapticEngine()

            engine?.resetHandler = { [weak engine] in
                do {
                    try engine?.start()
                } catch {
                    Logger.error("Failed to restart engine: \(error)")
                }
            }

            engine?.stoppedHandler = { reason in
                engine = nil
            }

            try engine?.start()
        }
    }
}

// MARK: add aliases for common haptic feedback here
extension UIImpactFeedbackGenerator.FeedbackStyle {
    static var copiedToClipboard: UIImpactFeedbackGenerator.FeedbackStyle { .soft }
    static var pastedFromClipboard: UIImpactFeedbackGenerator.FeedbackStyle { .medium }
    static var scanSuccess: UIImpactFeedbackGenerator.FeedbackStyle { .heavy }
    static var openSheet: UIImpactFeedbackGenerator.FeedbackStyle { .medium }
    static var buttonTap: UIImpactFeedbackGenerator.FeedbackStyle { .light }
}

private enum HapticsError: Error {
    case hapticNotSupported
}
