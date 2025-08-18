import LocalAuthentication
import SwiftUI

struct SecurityBiometrics: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @Binding var navigationPath: [SecurityRoute]

    @State private var useBiometrics = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var navigateToNoBiometricsSupport = false
    @State private var navigateToSuccess = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: biometryTypeName)

            VStack(spacing: 0) {
                BodyMText(t("security__bio_ask", variables: ["biometricsName": biometryTypeName]))

                Spacer()

                Image(Env.biometryType == .touchID ? "touch-id" : "face-id")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 133, height: 133)

                Spacer()

                HStack(alignment: .center, spacing: 0) {
                    BodyMSBText(t("security__bio_use", variables: ["biometricsName": biometryTypeName]))

                    Spacer()

                    Toggle("", isOn: $useBiometrics)
                        .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                        .labelsHidden()
                }
                .padding(.bottom, 32)

                CustomButton(title: t("common__continue")) {
                    if useBiometrics {
                        requestBiometricPermission()
                    } else {
                        navigationPath.append(.success)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .alert(
            t("security__bio_error_title"),
            isPresented: $showingError
        ) {
            Button(t("common__ok")) {
                useBiometrics = false
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
        let reason = t("security__bio_confirm", variables: ["biometricsName": biometryTypeName])

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authenticationError in
            DispatchQueue.main.async {
                if success {
                    settings.useBiometrics = useBiometrics
                    navigationPath.append(.success)
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
        guard let error else { return }

        let nsError = error as NSError

        switch nsError.code {
        case LAError.biometryNotAvailable.rawValue:
            errorMessage = t("security__bio_not_available")
            // Navigate directly to NoBiometricsSupport for this case
            navigateToNoBiometricsSupport = true
            return
        case LAError.biometryNotEnrolled.rawValue:
            errorMessage = t("security__bio_not_available")
            // Navigate directly to NoBiometricsSupport for this case
            navigateToNoBiometricsSupport = true
            return
        case LAError.userCancel.rawValue, LAError.userFallback.rawValue:
            // User cancelled - don't show error, just turn off toggle
            return
        default:
            errorMessage = t(
                "security__bio_error_message",
                variables: ["type": biometryTypeName]
            )
        }

        showingError = true
        Logger.error("Biometric authentication error: \(error)", context: "SetupBiometricsView")
    }
}

#Preview {
    SecurityBiometrics(navigationPath: .constant([.biometrics]))
        .environmentObject(SettingsViewModel())
}
