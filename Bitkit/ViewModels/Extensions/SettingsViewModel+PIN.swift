import Foundation
import SwiftUI

// MARK: - PIN Management

extension PinResult {
    /// What a PIN pad shows for an entry that did not unlock it.
    var errorMessage: String? {
        switch self {
        case .correct, .lockedOut:
            return nil
        case let .incorrect(remaining) where remaining == 1:
            return t("security__pin_last_attempt")
        case let .incorrect(remaining):
            return t("security__pin_attempts", variables: ["attemptsRemaining": "\(remaining)"])
        case .unavailable:
            return t("security__pin_unavailable")
        }
    }

    var errorIdentifier: String? {
        switch self {
        case let .incorrect(remaining):
            return remaining == 1 ? "LastAttempt" : "AttemptsRemaining"
        case .correct, .lockedOut, .unavailable:
            return nil
        }
    }
}

extension SettingsViewModel {
    func updatePinEnabledState() {
        let newState = Self.isPinRequired { try Keychain.exists(key: .securityPin) }
        if pinEnabled != newState {
            pinEnabled = newState
            Logger.debug("PIN enabled state updated to \(newState)", context: "SettingsViewModel")
        }
    }

    /// A PIN whose presence cannot be read counts as set, so a keychain error locks the app instead of opening it.
    static func isPinRequired(pinExists: () throws -> Bool) -> Bool {
        do {
            return try pinExists()
        } catch {
            Logger.error("Failed to check if PIN exists in keychain: \(error)", context: "SettingsViewModel")
            return true
        }
    }

    func setPin(_ pin: String) throws {
        // A new PIN starts with every attempt, whatever a removed one left behind, and is not saved until it does
        try KeychainPinLockoutStore().saveFailedAttempts(0)
        try Keychain.saveString(key: .securityPin, str: pin)
        updatePinEnabledState()
    }

    private func clearPinAttempts() {
        do {
            try KeychainPinLockoutStore().saveFailedAttempts(0)
        } catch {
            Logger.warn("Failed to clear the PIN attempt counter: \(error)", context: "SettingsViewModel")
        }
    }

    func verifyPin(_ pin: String) -> PinResult {
        PinVerifier.shared.verify(pin)
    }

    /// Leaves the PIN and its attempt counter alone: a restore must not lift a lockout or open a wallet whose PIN is set.
    @MainActor
    func resetPinSettings() {
        requirePinForPayments = false
        useBiometrics = false
        updatePinEnabledState()
        Logger.debug("PIN settings reset after app wipe", context: "SettingsViewModel")
    }

    func removePin(pin: String, resetSettings: Bool = true) throws {
        guard verifyPin(pin) == .correct else {
            throw NSError(domain: "SettingsViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "PIN does not match"])
        }

        try Keychain.delete(key: .securityPin)
        clearPinAttempts()

        if resetSettings {
            // Reset all PIN-related settings when PIN is disabled
            requirePinForPayments = false
            useBiometrics = false
        }

        updatePinEnabledState()
    }

    func changePin(currentPin: String, newPin: String) throws {
        guard verifyPin(currentPin) == .correct else {
            throw NSError(domain: "SettingsViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "PIN does not match"])
        }

        try Keychain.updateString(key: .securityPin, str: newPin)
        updatePinEnabledState()
    }
}
