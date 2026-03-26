import SwiftUI

private enum Step: Hashable {
    case verifyCurrentPin
    case enterNewPin
    case confirmNewPin
}

struct SecurityChangePin: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var wallet: WalletViewModel

    @Binding var navigationPath: [SecurityRoute]

    @State private var pinInput: String = ""
    @State private var currentPin: String = ""
    @State private var newPin: String = ""
    @State private var errorMessage: String = ""
    @State private var errorIdentifier: String?
    @State private var step: Step = .verifyCurrentPin

    private var navTitle: String {
        switch step {
        case .verifyCurrentPin: t("security__cp_title")
        case .enterNewPin: t("security__cp_setnew_title")
        case .confirmNewPin: t("security__cp_retype_title")
        }
    }

    private var text: String {
        switch step {
        case .verifyCurrentPin: t("security__cp_text")
        case .enterNewPin: t("security__cp_setnew_text")
        case .confirmNewPin: t("security__cp_retype_text")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: navTitle)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                BodyMText(text, accentFont: Fonts.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 32)

                Spacer()

                if !errorMessage.isEmpty {
                    BodySText(errorMessage, textColor: .brandAccent)
                        .padding(.bottom, 16)
                        .accessibilityIdentifier(errorIdentifier ?? "WrongPIN")
                }
            }
            .padding(.horizontal, 32)

            PinInput(pinInput: $pinInput) { pin in
                if pin.count == 4 {
                    handlePinComplete(pin)
                } else if pin.count == 1 {
                    errorMessage = ""
                    errorIdentifier = nil
                }
            }
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .sheetBackground()
    }

    private func handlePinComplete(_ pin: String) {
        switch step {
        case .verifyCurrentPin:
            handleVerifyCurrentPin(pin)
        case .enterNewPin:
            handleEnterNewPin(pin)
        case .confirmNewPin:
            handleConfirmNewPin(pin)
        }
    }

    private func handleVerifyCurrentPin(_ pin: String) {
        if settings.pinCheck(pin: pin) {
            currentPin = pin
            step = .enterNewPin
            resetPinInput()
            Haptics.notify(.success)
        } else {
            handleIncorrectCurrentPin()
        }
    }

    private func handleEnterNewPin(_ pin: String) {
        newPin = pin
        step = .confirmNewPin
        resetPinInput()
        Haptics.notify(.success)
    }

    private func handleConfirmNewPin(_ pin: String) {
        guard pin == newPin else {
            errorMessage = t("security__cp_try_again")
            errorIdentifier = "WrongPIN"
            pinInput = ""
            return
        }

        // PINs match - update PIN
        do {
            try settings.removePin(pin: currentPin, resetSettings: false)
            try settings.setPin(newPin)
            pinInput = ""
            errorMessage = ""
            errorIdentifier = nil
            navigationPath.append(.changePinSuccess)
        } catch {
            Logger.error("Failed to change PIN: \(error)", context: "SecurityChangePin")
            errorMessage = t("security__cp_try_again")
            errorIdentifier = "WrongPIN"
            pinInput = ""
        }
    }

    private func handleIncorrectCurrentPin() {
        pinInput = ""

        if settings.hasExceededPinAttempts() {
            handleWalletWipe()
            return
        }

        let remainingAttempts = settings.getRemainingPinAttempts()
        if remainingAttempts == 1 {
            errorMessage = t(
                "security__pin_last_attempt",
                comment: "Last attempt. Entering the wrong PIN again will reset your wallet."
            )
            errorIdentifier = "LastAttempt"
        } else {
            errorMessage = t(
                "security__pin_attempts",
                comment: "%d attempts remaining. Forgot your PIN?",
                variables: ["attemptsRemaining": "\(remainingAttempts)"]
            )
            errorIdentifier = "AttemptsRemaining"
        }

        Haptics.notify(.error)
    }

    private func handleWalletWipe() {
        Task {
            do {
                try await AppReset.wipe(
                    app: app,
                    wallet: wallet,
                    session: session,
                    toastType: .warning
                )
                sheets.hideSheet()
            } catch {
                Logger.error("Failed to wipe wallet after PIN attempts exceeded: \(error)", context: "SecurityChangePin")
                app.toast(error)
            }
        }
    }

    private func resetPinInput() {
        pinInput = ""
        errorMessage = ""
        errorIdentifier = nil
    }
}
