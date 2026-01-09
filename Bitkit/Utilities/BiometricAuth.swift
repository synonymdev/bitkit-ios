import LocalAuthentication

/// Result of a biometric authentication attempt
enum BiometricAuthResult {
    case success
    case cancelled
    case failed(message: String)
}

/// Utility for biometric authentication (Face ID / Touch ID)
enum BiometricAuth {
    /// The display name for the current biometry type
    static var biometryTypeName: String {
        switch Env.biometryType {
        case .touchID:
            return t("security__bio_touch_id")
        case .faceID:
            return t("security__bio_face_id")
        default:
            return t("security__bio_face_id")
        }
    }

    /// Whether biometric authentication is available on this device
    static var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Authenticate using biometrics (Face ID or Touch ID)
    /// - Returns: Result indicating success, cancellation, or failure with error message
    @MainActor
    static func authenticate() async -> BiometricAuthResult {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            var error: NSError?

            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                let message = errorMessage(for: error)
                if let message {
                    continuation.resume(returning: .failed(message: message))
                } else {
                    continuation.resume(returning: .cancelled)
                }
                return
            }

            let reason = t("security__bio_confirm", variables: ["biometricsName": biometryTypeName])

            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authError in
                DispatchQueue.main.async {
                    if success {
                        Logger.debug("Biometric authentication successful", context: "BiometricAuth")
                        continuation.resume(returning: .success)
                    } else if let authError {
                        let message = errorMessage(for: authError)
                        if let message {
                            continuation.resume(returning: .failed(message: message))
                        } else {
                            continuation.resume(returning: .cancelled)
                        }
                    } else {
                        continuation.resume(returning: .cancelled)
                    }
                }
            }
        }
    }

    /// Convert LAError to user-facing error message
    /// Returns nil for user-initiated cancellations (no error to show)
    private static func errorMessage(for error: Error?) -> String? {
        guard let error else { return nil }

        let nsError = error as NSError

        switch nsError.code {
        case LAError.biometryNotAvailable.rawValue, LAError.biometryNotEnrolled.rawValue:
            return t("security__bio_not_available")
        case LAError.userCancel.rawValue, LAError.userFallback.rawValue:
            return nil
        default:
            return t("security__bio_error_message", variables: ["type": biometryTypeName])
        }
    }
}
