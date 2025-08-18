import SwiftUI

struct SecurityPin: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @Binding var navigationPath: [SecurityRoute]
    @State private var pinInput: String = ""
    @State private var errorMessage: String = ""
    @State private var pinToCheck: String? = nil

    private var navTitle: String {
        pinToCheck == nil
            ? localizedString("security__pin_choose_header")
            : localizedString("security__pin_retype_header")
    }

    private var text: String {
        pinToCheck == nil
            ? localizedString("security__pin_choose_text")
            : localizedString("security__pin_retype_text")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: navTitle)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                BodyMText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 32)

                Spacer()

                if !errorMessage.isEmpty {
                    BodySText(errorMessage, textColor: .brandAccent)
                        .padding(.bottom, 16)
                }
            }
            .padding(.horizontal, 32)

            VStack(spacing: 0) {
                PinInput(pinInput: $pinInput) { pin in
                    if pin.count == 4 {
                        handlePinComplete(pin)
                    } else if pin.count == 1 {
                        errorMessage = ""
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .sheetBackground()
    }

    private func handlePinComplete(_ pin: String) {
        if let pinToCheck {
            // This is the confirmation step
            if pin == pinToCheck {
                // PINs match, save via SettingsViewModel and check biometric enrollment
                do {
                    try settings.setPin(pin)

                    // Check if device supports and has biometrics enrolled
                    if Env.biometryType != .none {
                        navigationPath.append(.biometrics)
                    } else {
                        navigationPath.append(.noBiometrics)
                    }
                } catch {
                    Logger.error("Failed to save PIN: \(error)", context: "ChoosePinView")
                    errorMessage = "Failed to save PIN. Please try again."
                    pinInput = ""
                }
            } else {
                // PINs don't match, show error and reset
                errorMessage = NSLocalizedString("security__pin_not_match", comment: "")
                pinInput = ""
            }
        } else {
            // This is the initial PIN entry, set pinToCheck and reset input for confirmation
            pinToCheck = pin
            pinInput = ""
            errorMessage = ""
        }
    }
}

#Preview {
    SecurityPin(navigationPath: .constant([.pin]))
        .environmentObject(SettingsViewModel())
}
