//
//  SettingsViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/19.
//

import SwiftUI

@MainActor
class SettingsViewModel: ObservableObject {
    // Security & Privacy Settings
    @AppStorage("swipeBalanceToHide") private var _swipeBalanceToHide: Bool = true

    var swipeBalanceToHide: Bool {
        get { _swipeBalanceToHide }
        set {
            _swipeBalanceToHide = newValue
            if !newValue {
                // If they disable the swipe to hide, we should keep the balance visible else they'll never see it
                hideBalance = false
            }
        }
    }

    @AppStorage("hideBalance") var hideBalance: Bool = false
    @AppStorage("hideBalanceOnOpen") var hideBalanceOnOpen: Bool = false
    @AppStorage("readClipboard") var readClipboard: Bool = false
    @AppStorage("warnWhenSendingOver100") var warnWhenSendingOver100: Bool = false
    @AppStorage("showRecentlyPaidContacts") var showRecentlyPaidContacts: Bool = true //TODO: probably not going to be in anytime soon
    @AppStorage("requirePinOnLaunch") var requirePinOnLaunch: Bool = false //TODO: Feature needed
    @AppStorage("requirePinWhenIdle") var requirePinWhenIdle: Bool = true //TODO: Feature needed
    @AppStorage("requirePinForPayments") var requirePinForPayments: Bool = false //TODO: Feature needed
    @AppStorage("useBiometrics") var useBiometrics: Bool = false //TODO: Checks in UX still need to be done

    // PIN Management
    @Published private(set) var pinEnabled: Bool = false
    @AppStorage("pinFailedAttempts") private var pinFailedAttempts: Int = 0

    private func updatePinEnabledState() {
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
        pinFailedAttempts = 0
        updatePinEnabledState()
        Logger.debug("PIN settings reset after security wipe", context: "SettingsViewModel")
    }

    func removePin(pin: String) throws {
        guard pinCheck(pin: pin) else {
            throw NSError(domain: "SettingsViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "PIN does not match"])
        }
        try Keychain.delete(key: .securityPin)

        // Reset all PIN-related settings when PIN is disabled
        requirePinOnLaunch = false
        requirePinWhenIdle = false
        requirePinForPayments = false
        useBiometrics = false

        updatePinEnabledState()
    }

    // Widget Settings
    @AppStorage("showWidgets") var showWidgets: Bool = true
    @AppStorage("showWidgetTitles") var showWidgetTitles: Bool = false

    init() {
        if hideBalanceOnOpen {
            hideBalance = true
        }

        updatePinEnabledState()
    }
}
