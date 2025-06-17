import SwiftUI

struct PinOnLaunchView: View {
    @State private var pinInput: String = ""
    @State private var errorMessage: String = ""
    @EnvironmentObject private var settings: SettingsViewModel
    let onPinVerified: () -> Void

    private func handlePinChange(_ pin: String) {
        if pin.count == 4 {
            handlePinComplete(pin)
        } else if pin.count == 1 {
            // Clear error message when user starts typing
            errorMessage = ""
        }
    }

    private func handlePinComplete(_ pin: String) {
        if settings.pinCheck(pin: pin) {
            // PIN is correct
            Haptics.notify(.success)
            onPinVerified()
        } else {
            // PIN is incorrect
            errorMessage = NSLocalizedString("security__cp_try_again", comment: "Try again, this is not the same PIN")
            pinInput = ""
            Haptics.notify(.error)
        }
    }

    var body: some View {
        ZStack {
            // Dark background
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                Image("logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 60)
                    .padding(.bottom, 80)

                // Title text
                BodyMText(
                    NSLocalizedString("security__pin_enter", comment: "Please enter your PIN code"),
                    textColor: .textPrimary,
                    textAlignment: .center
                )
                .padding(.bottom, 40)

                // Error message
                if !errorMessage.isEmpty {
                    CaptionText(errorMessage, textColor: .brandAccent)
                        .padding(.bottom, 16)
                }

                // PIN input component
                PinInput(pinInput: $pinInput) { pin in
                    handlePinChange(pin)
                }
                .padding(.bottom, 100)

                Spacer()
            }
            .padding(.horizontal, 32)
        }
    }
}

#Preview {
    PinOnLaunchView {
        print("PIN verified!")
    }
    .environmentObject(SettingsViewModel())
    .preferredColorScheme(.dark)
}
