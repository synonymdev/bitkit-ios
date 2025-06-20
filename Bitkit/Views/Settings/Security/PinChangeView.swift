//
//  PinChangeView.swift
//  Bitkit
//
//  Created by Assistant on 2024/12/19.
//

import SwiftUI

//Used for changing the PIN or disabling it

struct PinChangeView: View {
    @State private var pinInput: String = ""
    @State private var currentPin: String = ""
    @State private var newPin: String = ""
    @State private var step: PinChangeStep = .verifyCurrentPin
    @State private var errorMessage: String = ""
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel

    enum PinChangeStep {
        case verifyCurrentPin
        case enterNewPin
        case confirmNewPin
        case success
    }

    // Computed properties for title and description
    var title: String {
        switch step {
        case .verifyCurrentPin:
            return NSLocalizedString("security__cp_title", comment: "Change PIN")
        case .enterNewPin:
            return NSLocalizedString("security__cp_setnew_title", comment: "Set new PIN title")
        case .confirmNewPin:
            return NSLocalizedString("security__cp_retype_title", comment: "Retype New PIN")
        case .success:
            return NSLocalizedString("security__cp_changed_title", comment: "PIN changed title")
        }
    }

    var description: String {
        switch step {
        case .verifyCurrentPin:
            return NSLocalizedString("security__cp_text", comment: "Change PIN description")
        case .enterNewPin:
            return NSLocalizedString("security__cp_setnew_text", comment: "Set new PIN description")
        case .confirmNewPin:
            return NSLocalizedString("security__cp_retype_text", comment: "Retype PIN description")
        case .success:
            return NSLocalizedString("security__cp_changed_text", comment: "PIN changed description")
        }
    }

    private func handlePinComplete(_ pin: String) {
        switch step {
        case .verifyCurrentPin:
            // Verify the current PIN
            if settings.pinCheck(pin: pin) {
                currentPin = pin
                step = .enterNewPin
                pinInput = ""
                errorMessage = ""
                Haptics.notify(.success)
            } else {
                handleIncorrectCurrentPin()
            }

        case .enterNewPin:
            // Store the new PIN and move to confirmation
            newPin = pin
            step = .confirmNewPin
            pinInput = ""
            errorMessage = ""
            Haptics.notify(.success)

        case .confirmNewPin:
            // Confirm the new PIN
            if pin == newPin {
                // PINs match, update the PIN
                do {
                    try settings.removePin(pin: currentPin)
                    try settings.setPin(newPin)
                    step = .success
                    errorMessage = ""
                    Haptics.notify(.success)
                } catch {
                    Logger.error("Failed to change PIN: \(error)", context: "PinChangeView")
                    errorMessage = NSLocalizedString("security__cp_try_again", comment: "Try again, this is not the same PIN")
                    pinInput = ""
                    Haptics.notify(.error)
                }
            } else {
                // PINs don't match, go back to enter new PIN
                errorMessage = NSLocalizedString("security__cp_try_again", comment: "Try again, this is not the same PIN")
                step = .enterNewPin
                newPin = ""
                pinInput = ""
                Haptics.notify(.error)
            }

        case .success:
            // Should not reach here as PIN input is hidden in success state
            break
        }
    }

    private func handleIncorrectCurrentPin() {
        pinInput = ""
        Haptics.notify(.error)

        if settings.hasExceededPinAttempts() {
            // Exceeded maximum attempts - wipe wallet
            Task {
                do {
                    try await wallet.wipeLightningWallet(includeKeychain: true)
                    settings.resetPinSettings()

                    // Show toast notification
                    await MainActor.run {
                        app.toast(
                            type: .error,
                            title: NSLocalizedString("security__wiped_title", comment: ""),
                            description: NSLocalizedString(
                                "security__wiped_message", comment: ""),
                            autoHide: false
                        )
                    }
                } catch {
                    Logger.error("Failed to wipe wallet after PIN attempts exceeded: \(error)", context: "PinChangeView")
                    await MainActor.run {
                        app.toast(error)
                    }
                }
            }
            return
        }

        let remainingAttempts = settings.getRemainingPinAttempts()

        if remainingAttempts == 1 {
            // Last attempt warning
            errorMessage = NSLocalizedString(
                "security__pin_last_attempt", comment: "Last attempt. Entering the wrong PIN again will reset your wallet.")
        } else {
            // Show remaining attempts
            errorMessage = localizedString(
                "security__pin_attempts", comment: "%d attempts remaining. Forgot your PIN?", variables: ["attemptsRemaining": "\(remainingAttempts)"]
            )
        }
    }

    private func handlePinChange(_ pin: String) {
        if pin.count == 4 {
            handlePinComplete(pin)
        } else if pin.count == 1 {
            // Clear error message when user starts typing
            errorMessage = ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            BodyMText(description, textColor: .textSecondary)
                .multilineTextAlignment(step == .success ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: step == .success ? .center : .leading)
                .padding(.horizontal, 16)
                .padding(.top, 32)
                .padding(.bottom, 49)

            if step == .success {
                // Success illustration
                Image("check")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 274, height: 274)
                    .padding(.top, 32)
            } else {
                // Error message
                if !errorMessage.isEmpty {
                    CaptionText(errorMessage, textColor: .brandAccent)
                        .padding(.bottom, 8)
                }

                // PIN input component - only show when not in success state
                PinInput(pinInput: $pinInput, verticalSpace: true) { pin in
                    handlePinChange(pin)
                }
            }

            if step == .success {
                Spacer()
                CustomButton(
                    title: NSLocalizedString("common__ok", comment: "OK button")
                ) {
                    dismiss()
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if step != .success {
                    Button(NSLocalizedString("common__cancel", comment: "Cancel button")) {
                        dismiss()
                    }
                    .foregroundColor(.textPrimary)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PinChangeView()
    }
    .preferredColorScheme(.dark)
    .environmentObject(SettingsViewModel())
    .environmentObject(WalletViewModel())
    .environmentObject(AppViewModel())
}
