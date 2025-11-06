import SwiftUI

struct PinCheckView: View {
    let title: String
    let explanation: String
    let onCancel: () -> Void
    let onPinVerified: (String) -> Void

    @State private var pinInput: String = ""
    @State private var errorMessage: String = ""
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

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
            dismiss()
            onPinVerified(pin)
        } else {
            // PIN is incorrect
            handleIncorrectPin()
        }
    }

    private func handleIncorrectPin() {
        pinInput = ""
        Haptics.notify(.error)

        if settings.hasExceededPinAttempts() {
            // Exceeded maximum attempts - this should be handled by the app level
            let remainingAttempts = settings.getRemainingPinAttempts()
            errorMessage = t(
                "security__pin_exceeded_attempts",
                comment: "Too many incorrect attempts. Please try again later."
            )
            return
        }

        let remainingAttempts = settings.getRemainingPinAttempts()

        if remainingAttempts == 1 {
            // Last attempt warning
            errorMessage = t(
                "security__pin_last_attempt",
                comment: "Last attempt. Entering the wrong PIN again will reset your wallet."
            )
        } else {
            // Show remaining attempts
            errorMessage = t(
                "security__pin_attempts",
                comment: "%d attempts remaining. Forgot your PIN?",
                variables: ["attemptsRemaining": "\(remainingAttempts)"]
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: title, showMenuButton: false)
                .padding(.bottom, 16)

            BodyMText(explanation, textColor: .textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 40)

            if !errorMessage.isEmpty {
                CaptionText(errorMessage, textColor: .brandAccent)
                    .padding(.bottom, 16)
            }

            // PIN input component
            PinInput(pinInput: $pinInput, verticalSpace: true) { pin in
                handlePinChange(pin)
            }

            Spacer()
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .background(Color.black)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    onCancel()
                    dismiss()
                }) {
                    Image(systemName: "arrow.left")
                        .foregroundColor(.white)
                        .font(.system(size: 18, weight: .medium))
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PinCheckView(
            title: "Enter PIN",
            explanation: "Please enter your PIN to confirm this payment",
            onCancel: {
                print("Cancelled")
            },
            onPinVerified: { _ in
                print("PIN verified!")
            }
        )
        .environmentObject(SettingsViewModel.shared)
    }
    .preferredColorScheme(.dark)
}
