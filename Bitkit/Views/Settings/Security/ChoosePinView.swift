import SwiftUI

struct ChoosePinView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @State private var pinInput: String = ""
    @State private var errorMessage: String = ""
    @State private var navigateToSetupBiometrics: Bool = false
    @State private var pinToCheck: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                BodyMText(
                    pinToCheck == nil
                        ? NSLocalizedString("security__pin_choose_text", comment: "")
                        : NSLocalizedString("security__pin_retype_text", comment: ""),
                    textAlignment: .left
                )
            }
            .padding(.top, 32)
            .padding(.bottom, 48)

            Spacer()

            // Error message
            if !errorMessage.isEmpty {
                CaptionText(errorMessage, textColor: .brandAccent)
                    .padding(.bottom, 16)
            }

            PinInput(pinInput: $pinInput) { pin in
                if pin.count == 4 {
                    handlePinComplete(pin)
                } else if pin.count == 1 {
                    errorMessage = ""
                }
            }
            .padding(.top, 32)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheetBackground()
        .navigationTitle(
            pinToCheck == nil
                ? NSLocalizedString("security__pin_choose_header", comment: "")
                : NSLocalizedString("security__pin_retype_header", comment: "")
        )
        .navigationDestination(isPresented: $navigateToSetupBiometrics) {
            SetupBiometricsView()
        }
    }

    private func handlePinComplete(_ pin: String) {
        if let pinToCheck = pinToCheck {
            // This is the confirmation step
            if pin == pinToCheck {
                // PINs match, save via SettingsViewModel and navigate to biometrics setup
                do {
                    try settings.setPin(pin)
                    navigateToSetupBiometrics = true
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
            self.pinToCheck = pin
            pinInput = ""
            errorMessage = ""
        }
    }
}

#Preview {
    ChoosePinView()
        .environmentObject(AppViewModel())
        .environmentObject(SettingsViewModel())
}
