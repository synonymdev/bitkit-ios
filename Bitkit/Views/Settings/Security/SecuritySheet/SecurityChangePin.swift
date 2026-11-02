import SwiftUI

private enum Step: Hashable {
    case verifyCurrentPin
    case enterNewPin
    case confirmNewPin
}

struct SecurityChangePin: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel

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
                        .onTapGesture {
                            sheets.showSheet(.forgotPin)
                        }
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
        let result = settings.verifyPin(pin)
        if result == .correct {
            currentPin = pin
            step = .enterNewPin
            resetPinInput()
            Haptics.notify(.success)
        } else {
            handleIncorrectCurrentPin(result)
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
            try settings.changePin(currentPin: currentPin, newPin: newPin)
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

    private func handleIncorrectCurrentPin(_ result: PinResult) {
        pinInput = ""

        // A lockout raises the wipe gate in place of this screen.
        guard result != .lockedOut else { return }

        errorMessage = result.errorMessage ?? ""
        errorIdentifier = result.errorIdentifier

        Haptics.notify(.error)
    }

    private func resetPinInput() {
        pinInput = ""
        errorMessage = ""
        errorIdentifier = nil
    }
}
