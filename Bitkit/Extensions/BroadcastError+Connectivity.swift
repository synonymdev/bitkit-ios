import BitkitCore
import Foundation

extension Error {
    func isBroadcastConnectivityFailure() -> Bool {
        if let broadcastError = self as? BroadcastError {
            if case .ElectrumError = broadcastError {
                return true
            }
            return false
        }

        if let appError = self as? AppError, let underlyingError = appError.underlyingError {
            return underlyingError.isBroadcastConnectivityFailure()
        }

        return false
    }
}
