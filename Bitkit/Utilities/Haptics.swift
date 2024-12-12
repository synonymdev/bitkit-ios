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
        // Add debug print to check if function is called
        print("🚀 Attempting rocket haptics...")
        
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            print("❌ Device doesn't support haptics")
            completion?()
            return
        }

        do {
            // Create and retain engine reference
            engine = try CHHapticEngine()
            print("✅ Created haptic engine")
            
            engine?.resetHandler = { [weak engine] in
                print("⚠️ Restarting Haptic engine...")
                do {
                    try engine?.start()
                    print("✅ Engine restarted")
                } catch {
                    print("❌ Failed to restart engine: \(error)")
                }
            }
            
            engine?.stoppedHandler = { reason in
                print("⚠️ Haptic engine stopped: \(reason)")
                completion?()
            }
            
            try engine?.start()
            print("✅ Started haptic engine")
            
            var events = [CHHapticEvent]()
            
            // Increase initial intensity for more noticeable effect
            let initialIntensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
            let initialSharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
            events.append(CHHapticEvent(eventType: .hapticTransient, 
                                      parameters: [initialIntensity, initialSharpness], 
                                      relativeTime: 0))
            
            // Increase intensity and reduce steps for more noticeable effect
            let steps = 3
            for i in 1 ... steps {
                let progress = Double(i) / Double(steps)
                let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(progress) * 0.8)
                let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(progress))
                let event = CHHapticEvent(eventType: .hapticContinuous,
                                        parameters: [intensity, sharpness],
                                        relativeTime: duration * progress * 0.5, // Compress timing
                                        duration: 0.2)
                events.append(event)
            }

            // Make final burst more intense
            let finalIntensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
            let finalSharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
            events.append(CHHapticEvent(eventType: .hapticTransient,
                                      parameters: [finalIntensity, finalSharpness],
                                      relativeTime: duration * 0.7))

            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: 0)
            print("✅ Started haptic pattern")
            
            if let completion = completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    completion()
                }
            }
            
        } catch {
            print("❌ Haptic error: \(error)")
            completion?()
        }
    }

    static func test() {
        print("Testing basic haptics...")
        
        // Test UIImpactFeedbackGenerator
        play(.heavy)
        
        // Test UINotificationFeedbackGenerator
        notify(.success)
        
        // Test CoreHaptics
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            rocket(duration: 0.5) {
                print("Rocket haptics completed")
            }
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
