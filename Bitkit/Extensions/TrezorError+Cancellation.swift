import BitkitCore

extension Error {
    /// Whether this error is a Trezor on-device cancellation (user declined signing, or cancelled PIN
    /// / passphrase entry). Distinct from Swift `CancellationError` (the flow/task being dismissed).
    /// Callers treat it as a silent no-op so the user can retry on the same screen.
    func isTrezorUserCancellation() -> Bool {
        guard let trezorError = self as? TrezorError else { return false }
        switch trezorError {
        case .UserCancelled, .PinCancelled, .PassphraseCancelled:
            return true
        default:
            return false
        }
    }
}
