import LocalAuthentication
import SwiftUI

enum AuthCheckBiometricAttemptKind: Equatable {
    case automatic
    case manual
}

enum AuthCheckBiometricPolicy {
    static func shouldStart(
        scenePhase: ScenePhase,
        isEnabled: Bool,
        hasActiveAttempt: Bool,
        attemptKind: AuthCheckBiometricAttemptKind,
        hasAutomaticallyAttempted: Bool
    ) -> Bool {
        scenePhase == .active &&
            isEnabled &&
            !hasActiveAttempt &&
            (attemptKind == .manual || !hasAutomaticallyAttempted)
    }

    static func shouldCancel(scenePhase: ScenePhase) -> Bool {
        scenePhase == .background
    }
}

private struct AuthCheckBiometricAttempt {
    let context: LAContext
}

struct AuthCheck: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var session: SessionManager

    @State private var pinInput: String = ""
    @State private var errorMessage: String = ""
    @State private var shouldShowBiometricRetry = false
    @State private var errorIdentifier: String?
    @State private var biometricAttempt: AuthCheckBiometricAttempt?
    @State private var hasAutomaticallyAttemptedBiometrics = false

    let onCancel: (() -> Void)?
    let onPinVerified: () -> Void

    private var biometryTypeName: String {
        BiometricAuth.biometryTypeName
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

    private func handleBiometricAuthentication(attemptKind: AuthCheckBiometricAttemptKind = .manual) {
        guard AuthCheckBiometricPolicy.shouldStart(
            scenePhase: scenePhase,
            isEnabled: settings.useBiometrics,
            hasActiveAttempt: biometricAttempt != nil,
            attemptKind: attemptKind,
            hasAutomaticallyAttempted: hasAutomaticallyAttemptedBiometrics
        ) else { return }

        if attemptKind == .automatic {
            hasAutomaticallyAttemptedBiometrics = true
        }

        let context = LAContext()
        var error: NSError?

        // Check if biometric authentication is available
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            if attemptKind == .automatic {
                hasAutomaticallyAttemptedBiometrics = false
            }
            shouldShowBiometricRetry = true
            Logger.error("Biometric authentication not available: \(error?.localizedDescription ?? "Unknown error")", context: "AuthCheck")
            return
        }

        // Request biometric authentication
        let reason = t("security__bio_confirm", variables: ["biometricsName": biometryTypeName])
        context.localizedCancelTitle = t("security__use_pin")
        biometricAttempt = AuthCheckBiometricAttempt(context: context)

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authenticationError in
            DispatchQueue.main.async {
                guard biometricAttempt?.context === context else { return }
                biometricAttempt = nil

                if success {
                    Haptics.notify(.success)
                    onPinVerified()
                } else {
                    handleBiometricFailure(authenticationError)
                }
            }
        }
    }

    private func handleBiometricFailure(_ error: Error?) {
        shouldShowBiometricRetry = true
        guard let error else { return }

        switch (error as NSError).code {
        case LAError.userCancel.rawValue, LAError.userFallback.rawValue:
            return
        default:
            Logger.error("Biometric authentication failed: \(error.localizedDescription)", context: "AuthCheck")
            Haptics.notify(.error)
        }
    }

    private func cancelBiometricAuthentication() {
        let attempt = biometricAttempt
        biometricAttempt = nil
        attempt?.context.invalidate()
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

            VStack(alignment: .center, spacing: 12) {
                if settings.useBiometrics && shouldShowBiometricRetry {
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
            .padding(.top, 12)

            PinInput(pinInput: $pinInput) { pin in
                handlePinChange(pin)
            }
            .padding(.top, 16)
        }
        .background(Color.black)
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            if newPhase == .active {
                handleBiometricAuthentication(attemptKind: .automatic)
            } else if AuthCheckBiometricPolicy.shouldCancel(scenePhase: newPhase) {
                hasAutomaticallyAttemptedBiometrics = false
                cancelBiometricAuthentication()
            }
        }
        .onDisappear(perform: cancelBiometricAuthentication)
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
