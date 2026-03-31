import Foundation
import SwiftUI

// MARK: - PIN Management

enum PinAttemptOutcome {
    case exceededAttempts
    case lastAttempt
    case attemptsRemaining(Int)

    var errorIdentifier: String? {
        switch self {
        case .exceededAttempts:
            return nil
        case .lastAttempt:
            return "LastAttempt"
        case .attemptsRemaining:
            return "AttemptsRemaining"
        }
    }

    var errorMessage: String? {
        switch self {
        case .exceededAttempts:
            return nil
        case .lastAttempt:
            return t("security__pin_last_attempt")
        case let .attemptsRemaining(remainingAttempts):
            return t("security__pin_attempts", variables: ["attemptsRemaining": "\(remainingAttempts)"])
        }
    }
}

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

    func pinAttemptOutcomeAfterFailure() -> PinAttemptOutcome {
        if hasExceededPinAttempts() {
            return .exceededAttempts
        }

        let remainingAttempts = getRemainingPinAttempts()
        return remainingAttempts == 1 ? .lastAttempt : .attemptsRemaining(remainingAttempts)
    }

    func wipeWalletAfterExceededPinAttempts(
        app: AppViewModel,
        wallet: WalletViewModel,
        session: SessionManager,
        sheets: SheetViewModel? = nil,
        context: String
    ) async {
        do {
            try await AppReset.wipe(
                app: app,
                wallet: wallet,
                session: session,
                toastType: .warning
            )
            sheets?.hideSheet()
        } catch {
            Logger.error("Failed to wipe wallet after PIN attempts exceeded: \(error)", context: context)
            app.toast(error)
        }
    }

    @MainActor
    func resetPinSettings() {
        pinEnabled = false
        pinFailedAttempts = 0
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
            requirePinForPayments = false
            useBiometrics = false
        }

        updatePinEnabledState()
    }

    func changePin(currentPin: String, newPin: String) throws {
        guard pinCheck(pin: currentPin) else {
            throw NSError(domain: "SettingsViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "PIN does not match"])
        }

        try Keychain.updateString(key: .securityPin, str: newPin)
        updatePinEnabledState()
    }
}
