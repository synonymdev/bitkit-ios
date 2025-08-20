import Foundation
import SwiftUI

// MARK: - PIN Management

extension SettingsViewModel {
    func updatePinEnabledState() {
        let newState = checkPinExists()
        if pinEnabled != newState {
            pinEnabled = newState
            Logger.debug("PIN enabled state updated to \(newState)", context: "SettingsViewModel")
        }
    }

    private func checkPinExists() -> Bool {
        do {
            return try Keychain.exists(key: .securityPin)
        } catch {
            Logger.error("Failed to check if PIN exists in keychain: \(error)", context: "SettingsViewModel")
            return false
        }
    }

    func setPin(_ pin: String) throws {
        try Keychain.saveString(key: .securityPin, str: pin)
        updatePinEnabledState()
    }

    func pinCheck(pin: String) -> Bool {
        do {
            guard let storedPin = try Keychain.loadString(key: .securityPin) else {
                return false
            }

            let isCorrect = storedPin == pin

            if isCorrect {
                // Reset failed attempts on successful PIN entry
                pinFailedAttempts = 0
            } else {
                // Increment failed attempts
                pinFailedAttempts += 1
            }

            return isCorrect
        } catch {
            Logger.error("Failed to check PIN from keychain: \(error)", context: "SettingsViewModel")
            return false
        }
    }

    func getRemainingPinAttempts() -> Int {
        return max(0, Env.pinAttempts - pinFailedAttempts)
    }

    func hasExceededPinAttempts() -> Bool {
        return pinFailedAttempts >= Env.pinAttempts
    }

    func resetPinAttempts() {
        pinFailedAttempts = 0
    }

    func resetPinSettings() {
        pinEnabled = false
        pinFailedAttempts = 0
        requirePinOnLaunch = true
        requirePinWhenIdle = false
        requirePinForPayments = false
        useBiometrics = false
        Logger.debug("PIN settings reset after app wipe", context: "SettingsViewModel")
    }

    func removePin(pin: String, resetSettings: Bool = true) throws {
        guard pinCheck(pin: pin) else {
            throw NSError(domain: "SettingsViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "PIN does not match"])
        }

        try Keychain.delete(key: .securityPin)

        if resetSettings {
            // Reset all PIN-related settings when PIN is disabled
            requirePinOnLaunch = true
            requirePinWhenIdle = false
            requirePinForPayments = false
            useBiometrics = false
        }

        updatePinEnabledState()
    }
}
