import BitkitCore

extension Error {
    /// The `JadeError` this error is or wraps. `ServiceQueue` boxes core errors into an `AppError`
    /// before they reach the caller, so the preserved underlying error is unwrapped as well.
    var underlyingJadeError: JadeError? {
        if let jadeError = self as? JadeError {
            return jadeError
        }
        if let appError = self as? AppError, let underlyingError = appError.underlyingError {
            return underlyingError.underlyingJadeError
        }
        return nil
    }

    /// Whether the user declined the request on the Jade. Callers treat it as a silent no-op so the
    /// user can retry on the same screen.
    func isJadeUserCancellation() -> Bool {
        guard case .UserCancelled? = underlyingJadeError else { return false }
        return true
    }

    /// Whether the Jade cannot serve the request until the user acts on it: busy with another prompt,
    /// or locked.
    func isJadeDeviceBusy() -> Bool {
        guard let jadeError = underlyingJadeError else { return false }
        switch jadeError {
        case .DeviceBusy, .DeviceLocked:
            return true
        default:
            return false
        }
    }

    func isJadeFirmwareError() -> Bool {
        guard case .UnsupportedFirmware? = underlyingJadeError else { return false }
        return true
    }

    /// Whether the current Jade channel can no longer be used and must be re-established.
    func isJadeSessionFailure() -> Bool {
        guard let jadeError = underlyingJadeError else { return false }
        switch jadeError {
        case .TransportError, .DeviceDisconnected, .ConnectionError, .Timeout, .NotConnected, .NotInitialized, .IoError:
            return true
        default:
            return false
        }
    }
}
