import BitkitCore

private let firmwareErrorCode = 99

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

    /// Whether this error is a locked/busy Trezor (typed `TrezorError.DeviceBusy` since bitkit-core 0.3.9).
    func isTrezorDeviceBusy() -> Bool {
        if let trezorError = self as? TrezorError {
            if case .DeviceBusy = trezorError {
                return true
            }
            return false
        }

        if let appError = self as? AppError, let underlyingError = appError.underlyingError {
            return underlyingError.isTrezorDeviceBusy()
        }

        return false
    }

    func isTrezorFirmwareError() -> Bool {
        if let appError = self as? AppError {
            let message = appError.debugMessage ?? appError.message
            if message.contains("Device error (code \(firmwareErrorCode))") && message.contains("Firmware error") {
                return true
            }
            if let underlyingError = appError.underlyingError {
                return underlyingError.isTrezorFirmwareError()
            }
            return false
        }

        let message = localizedDescription
        return message.contains("Device error (code \(firmwareErrorCode))") && message.contains("Firmware error")
    }
}
