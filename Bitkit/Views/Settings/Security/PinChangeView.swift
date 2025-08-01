//
//  PinChangeView.swift
//  Bitkit
//
//  Created by Assistant on 2024/12/19.
//

import SwiftUI

/// View for changing the PIN or disabling it
struct PinChangeView: View {
    @State private var pinInput: String = ""
    @State private var currentPin: String = ""
    @State private var newPin: String = ""
    @State private var step: PinChangeStep = .verifyCurrentPin
    @State private var errorMessage: String = ""
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    enum PinChangeStep {
        case verifyCurrentPin
        case enterNewPin
        case confirmNewPin
        case success
    }

    // Computed properties for title and description
    var navTitle: String {
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
            handleCurrentPinVerification(pin)
        case .enterNewPin:
            handleNewPinEntry(pin)
        case .confirmNewPin:
            handleNewPinConfirmation(pin)
        case .success:
            // Should not reach here as PIN input is hidden in success state
            break
        }
    }

    private func handleCurrentPinVerification(_ pin: String) {
        if settings.pinCheck(pin: pin) {
            // Current PIN is correct - proceed to new PIN entry
            currentPin = pin
            step = .enterNewPin
            resetPinInput()
            Haptics.notify(.success)
        } else {
            handleIncorrectCurrentPin()
        }
    }

    private func handleNewPinEntry(_ pin: String) {
        // Store the new PIN and move to confirmation
        newPin = pin
        step = .confirmNewPin
        resetPinInput()
        Haptics.notify(.success)
    }

    private func handleNewPinConfirmation(_ pin: String) {
        if pin == newPin {
            // PINs match - update the PIN
            updatePin()
        } else {
            // PINs don't match - go back to enter new PIN
            handlePinMismatch()
        }
    }

    private func updatePin() {
        do {
            try settings.removePin(pin: currentPin, resetSettings: false)
            try settings.setPin(newPin)
            step = .success
            resetPinInput()
            Haptics.notify(.success)
        } catch {
            Logger.error("Failed to change PIN: \(error)", context: "PinChangeView")
            errorMessage = NSLocalizedString("security__cp_try_again", comment: "Try again, this is not the same PIN")
            pinInput = ""
            Haptics.notify(.error)
        }
    }

    private func handlePinMismatch() {
        errorMessage = NSLocalizedString("security__cp_try_again", comment: "Try again, this is not the same PIN")
        step = .enterNewPin
        newPin = ""
        resetPinInput()
        Haptics.notify(.error)
    }

    private func resetPinInput() {
        pinInput = ""
        errorMessage = ""
    }

    private func handleIncorrectCurrentPin() {
        pinInput = ""
        Haptics.notify(.error)

        if settings.hasExceededPinAttempts() {
            handleWalletWipe()
            return
        }

        updateErrorMessageForRemainingAttempts()
    }

    private func handleWalletWipe() {
        Task {
            do {
                try await wallet.wipeWallet()
                settings.resetPinSettings()

                // Show toast notification
                await MainActor.run {
                    app.toast(
                        type: .error,
                        title: NSLocalizedString("security__wiped_title", comment: ""),
                        description: NSLocalizedString("security__wiped_message", comment: ""),
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
    }

    private func updateErrorMessageForRemainingAttempts() {
        let remainingAttempts = settings.getRemainingPinAttempts()

        if remainingAttempts == 1 {
            // Last attempt warning
            errorMessage = NSLocalizedString(
                "security__pin_last_attempt",
                comment: "Last attempt. Entering the wrong PIN again will reset your wallet."
            )
        } else {
            // Show remaining attempts
            errorMessage = localizedString(
                "security__pin_attempts",
                comment: "%d attempts remaining. Forgot your PIN?",
                variables: ["attemptsRemaining": "\(remainingAttempts)"]
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

            if step == .success {
                successScreen
            } else {
                descriptionSection
                errorSection
                pinInputSection
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(step == .success)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }

    private var descriptionSection: some View {
        BodyMText(description)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 32)
            .padding(.bottom, 49)
    }

    private var successScreen: some View {
        VStack(spacing: 0) {
            BodyMText(localizedString("security__cp_changed_text"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 32)

            Spacer()

            Image("check")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 274, height: 274)

            Spacer()

            CustomButton(title: localizedString("common__ok")) {
                dismiss()
            }
        }
    }

    private var errorSection: some View {
        Group {
            if !errorMessage.isEmpty {
                BodySText(errorMessage, textColor: .brandAccent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .onTapGesture {
                        sheets.showSheet(.forgotPin)
                    }
            }
        }
    }

    private var pinInputSection: some View {
        PinInput(pinInput: $pinInput, verticalSpace: true) { pin in
            handlePinChange(pin)
        }
        .padding(.top, 16)
    }
}

#Preview {
    NavigationStack {
        PinChangeView()
    }
    .preferredColorScheme(.dark)
    .environmentObject(AppViewModel())
    .environmentObject(SettingsViewModel())
    .environmentObject(SheetViewModel())
    .environmentObject(WalletViewModel())
}
