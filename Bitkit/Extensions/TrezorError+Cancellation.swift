import BitkitCore

extension Error {
    /// Whether this error is a Trezor on-device cancellation (user declined signing, or cancelled PIN
    /// / passphrase entry). Distinct from Swift `CancellationError` (the flow/task being dismissed).
    /// Callers treat it as a silent no-op so the user can retry on the same screen.
    func isTrezorUserCancellation() -> Bool {
        if let trezorError = self as? TrezorError {
            switch trezorError {
            case .UserCancelled, .PinCancelled, .PassphraseCancelled:
                return true
            default:
                return false
            }
        }

        // `ServiceQueue` boxes core errors into a generic `AppError` before they reach the caller, so
        // unwrap and re-check the preserved underlying error.
        if let appError = self as? AppError, let underlyingError = appError.underlyingError {
            return underlyingError.isTrezorUserCancellation()
        }

        return false
    }
}
