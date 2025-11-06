import LocalAuthentication
import SwiftUI

struct AuthCheck: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var session: SessionManager

    @State private var pinInput: String = ""
    @State private var errorMessage: String = ""
    @State private var biometricFailedOnce = false

    let onPinVerified: () -> Void

    private var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID:
            return t("security__bio_touch_id")
        case .faceID:
            return t("security__bio_face_id")
        default:
            return t("security__bio_face_id") // Default to Face ID
        }
    }

    private var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

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
            Task {
                do {
                    try await AppReset.wipe(
                        app: app,
                        wallet: wallet,
                        session: session,
                        toastType: .warning
                    )
                } catch {
                    Logger.error("Failed to wipe wallet after PIN attempts exceeded: \(error)", context: "AuthCheck")
                    app.toast(error)
                }
            }

            return
        }

        let remainingAttempts = settings.getRemainingPinAttempts()

        if remainingAttempts == 1 {
            // Last attempt warning
            errorMessage = t(
                "security__pin_last_attempt", comment: "Last attempt. Entering the wrong PIN again will reset your wallet."
            )
        } else {
            // Show remaining attempts
            errorMessage = t(
                "security__pin_attempts", comment: "%d attempts remaining. Forgot your PIN?", variables: ["attemptsRemaining": "\(remainingAttempts)"]
            )
        }
    }

    private func handleBiometricAuthentication() {
        let context = LAContext()
        var error: NSError?

        // Check if biometric authentication is available
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            Logger.error("Biometric authentication not available: \(error?.localizedDescription ?? "Unknown error")", context: "AuthCheck")
            return
        }

        // Request biometric authentication
        let reason = t("security__bio_confirm", variables: ["biometricsName": biometryTypeName])

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authenticationError in
            DispatchQueue.main.async {
                if success {
                    Haptics.notify(.success)
                    onPinVerified()
                } else {
                    if let error = authenticationError {
                        Logger.error("Biometric authentication failed: \(error.localizedDescription)", context: "AuthCheck")
                    }
                    Haptics.notify(.error)
                    biometricFailedOnce = true
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 279, height: 82)
                .padding(.bottom, 47)

            BodyMSBText(t("security__pin_enter"))

            VStack(alignment: .center, spacing: 0) {
                Spacer()

                // Biometric button (if enabled and available, and failed once)
                if settings.useBiometrics && isBiometricAvailable && biometricFailedOnce {
                    CustomButton(
                        title: t("security__pin_use_biometrics", variables: ["biometricsName": biometryTypeName]),
                        size: .small,
                        icon: Image(Env.biometryType == .touchID ? "touch-id" : "face-id")
                            .resizable()
                            .frame(width: 16, height: 16)
                    ) {
                        handleBiometricAuthentication()
                    }
                }

                if !errorMessage.isEmpty {
                    BodySText(errorMessage, textColor: .brandAccent)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .onTapGesture {
                            sheets.showSheet(.forgotPin)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .padding(.top, 12)

            PinInput(pinInput: $pinInput) { pin in
                handlePinChange(pin)
            }
            .padding(.top, 16)
        }
        .background(Color.black)
        .onAppear {
            // Automatically request biometric authentication if enabled and available
            if settings.useBiometrics && isBiometricAvailable {
                handleBiometricAuthentication()
            }
        }
    }
}

#Preview {
    AuthCheck {
        print("PIN verified!")
    }
    .environmentObject(SettingsViewModel.shared)
    .environmentObject(WalletViewModel())
    .environmentObject(AppViewModel())
    .preferredColorScheme(.dark)
}
