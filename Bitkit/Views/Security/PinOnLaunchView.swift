import SwiftUI

struct PinOnLaunchView: View {
    @State private var pinInput: String = ""
    @State private var errorMessage: String = ""
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel
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
            handleIncorrectPin()
        }
    }

    private func handleIncorrectPin() {
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
                    Logger.error("Failed to wipe wallet after PIN attempts exceeded: \(error)", context: "PinOnLaunchView")
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

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo
            Image("logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 279, height: 82)
                .padding(.bottom, 47)

            // Title text
            BodyMText(
                NSLocalizedString("security__pin_enter", comment: ""),
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
        }
        .background(Color.black)
    }
}

#Preview {
    PinOnLaunchView {
        print("PIN verified!")
    }
    .environmentObject(SettingsViewModel())
    .environmentObject(WalletViewModel())
    .environmentObject(AppViewModel())
    .preferredColorScheme(.dark)
}
