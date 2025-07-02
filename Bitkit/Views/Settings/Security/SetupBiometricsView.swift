import LocalAuthentication
import SwiftUI

struct SetupBiometricsView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel

    @State private var useBiometrics = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var navigateToNoBiometricsSupport = false
    @State private var navigateToSuccess = false

    private var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID:
            return NSLocalizedString("security__bio_touch_id", comment: "")
        case .faceID:
            return NSLocalizedString("security__bio_face_id", comment: "")
        default:
            return NSLocalizedString("security__bio_face_id", comment: "") // Default to Face ID
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                BodyMText(
                    localizedString(
                        "security__bio_ask", comment: "",
                        variables: ["biometricsName": biometryTypeName]
                    )
                )
                .padding(.horizontal, 32)
            }
            .padding(.top, 32)
            .padding(.bottom, 48)

            Spacer()

            Image(Env.biometryType == .touchID ? "touch-id" : "face-id")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 133, height: 133)

            Spacer()

            // Biometrics toggle
            VStack(spacing: 24) {
                VStack {
                    HStack {
                        BodyMSBText(
                            localizedString(
                                "security__bio_use", comment: "",
                                variables: ["biometricsName": biometryTypeName]
                            ),
                            textColor: .textPrimary
                        )

                        Spacer()

                        Toggle("", isOn: $useBiometrics)
                            .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                            .labelsHidden()
                    }
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 16)
                .padding(.horizontal, 32)
                .onChange(of: useBiometrics) { newValue in
                    if newValue {
                        requestBiometricPermission()
                    }
                }

                CustomButton(
                    title: NSLocalizedString("common__continue", comment: ""),
                    isDisabled: false
                ) {
                    // Save the biometric setting
                    settings.useBiometrics = useBiometrics

                    if !useBiometrics {
                        // Navigate to NoBiometricsSupport view
                        navigateToNoBiometricsSupport = true
                    } else {
                        // Navigate to success view
                        navigateToSuccess = true
                    }
                }
                .padding(.horizontal, 32)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheetBackground()
        .navigationTitle(NSLocalizedString(biometryTypeName, comment: ""))
        .navigationDestination(isPresented: $navigateToNoBiometricsSupport) {
            NoBiometricsSupport()
        }
        .navigationDestination(isPresented: $navigateToSuccess) {
            SecuritySetupSuccess()
        }
        .alert(
            NSLocalizedString("security__bio_error_title", comment: ""),
            isPresented: $showingError
        ) {
            Button(NSLocalizedString("common__ok", comment: "")) {
                useBiometrics = false
                // Navigate to NoBiometricsSupport view when there's an error
                navigateToNoBiometricsSupport = true
            }
        } message: {
            Text(errorMessage)
        }
    }

    private func requestBiometricPermission() {
        let context = LAContext()
        var error: NSError?

        // Check if biometric authentication is available
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            handleBiometricError(error)
            return
        }

        // Request biometric authentication
        let reason = localizedString(
            "security__bio_confirm", comment: "",
            variables: ["biometricsName": biometryTypeName]
        )

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authenticationError in
            DispatchQueue.main.async {
                if success {
                    // Authentication successful - keep the toggle on
                    Logger.debug("Biometric authentication successful", context: "SetupBiometricsView")
                } else {
                    // Authentication failed - turn off the toggle and show error
                    useBiometrics = false
                    if let error = authenticationError {
                        handleBiometricError(error)
                    }
                }
            }
        }
    }

    private func handleBiometricError(_ error: Error?) {
        guard let error = error else { return }

        let nsError = error as NSError

        switch nsError.code {
        case LAError.biometryNotAvailable.rawValue:
            errorMessage = NSLocalizedString("security__bio_not_available", comment: "")
            // Navigate directly to NoBiometricsSupport for this case
            navigateToNoBiometricsSupport = true
            return
        case LAError.biometryNotEnrolled.rawValue:
            errorMessage = NSLocalizedString("security__bio_not_available", comment: "")
            // Navigate directly to NoBiometricsSupport for this case
            navigateToNoBiometricsSupport = true
            return
        case LAError.userCancel.rawValue, LAError.userFallback.rawValue:
            // User cancelled - don't show error, just turn off toggle
            return
        default:
            errorMessage = localizedString(
                "security__bio_error_message", comment: "",
                variables: ["type": biometryTypeName]
            )
        }

        showingError = true
        Logger.error("Biometric authentication error: \(error)", context: "SetupBiometricsView")
    }
}

#Preview {
    SetupBiometricsView()
        .environmentObject(AppViewModel())
        .environmentObject(SettingsViewModel())
}
