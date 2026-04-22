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
    @State private var errorIdentifier: String?

    let onCancel: (() -> Void)?
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
            errorIdentifier = nil
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

        let pinAttemptOutcome = settings.pinAttemptOutcomeAfterFailure()
        if case .exceededAttempts = pinAttemptOutcome {
            Task {
                await settings.wipeWalletAfterExceededPinAttempts(
                    app: app,
                    wallet: wallet,
                    session: session,
                    context: "AuthCheck"
                )
            }

            return
        }

        errorMessage = pinAttemptOutcome.errorMessage ?? ""
        errorIdentifier = pinAttemptOutcome.errorIdentifier
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
            if let onCancel {
                HStack(spacing: 0) {
                    Button(action: onCancel) {
                        Image("arrow-left")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.textPrimary)
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityIdentifier("NavigationBack")

                    Spacer()
                }
                .frame(height: 48)
                .padding(.horizontal, 16)
            } else {
                Spacer()
                    .frame(height: 48)
            }

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
                        .accessibilityIdentifier(errorIdentifier ?? "WrongPIN")
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
    AuthCheck(
        onCancel: nil,
        onPinVerified: {
            print("PIN verified!")
        }
    )
    .environmentObject(AppViewModel())
    .environmentObject(SettingsViewModel.shared)
    .environmentObject(SheetViewModel())
    .environmentObject(WalletViewModel())
    .environmentObject(SessionManager())
    .preferredColorScheme(.dark)
}
