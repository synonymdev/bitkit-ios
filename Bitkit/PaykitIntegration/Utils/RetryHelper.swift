//
//  RetryHelper.swift
//  Bitkit
//
//  Utility for retrying operations with exponential backoff
//

import Foundation

/// Simple retry function for async operations
public func tryNTimes<T>(
    toTry operation: () async throws -> T,
    times: Int = 3,
    interval: TimeInterval = 1.0
) async throws -> T {
    var lastError: Error?
    
    for attempt in 1...times {
        do {
            return try await operation()
        } catch {
            lastError = error
            if attempt < times {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
    
    throw lastError ?? NSError(domain: "tryNTimes", code: -1, userInfo: nil)
}

/// Helper for retrying async operations with exponential backoff
public struct RetryHelper {
    
    /// Retry configuration
    public struct Config {
        let maxAttempts: Int
        let initialDelay: TimeInterval
        let maxDelay: TimeInterval
        let multiplier: Double
        
        public static let `default` = Config(
            maxAttempts: 3,
            initialDelay: 1.0,
            maxDelay: 10.0,
            multiplier: 2.0
        )
        
        public static let aggressive = Config(
            maxAttempts: 5,
            initialDelay: 0.5,
            maxDelay: 30.0,
            multiplier: 2.0
        )
    }
    
    /// Retry an async operation with exponential backoff
    ///
    /// - Parameters:
    ///   - config: Retry configuration
    ///   - shouldRetry: Closure to determine if error is retryable
    ///   - operation: The async operation to retry
    /// - Returns: Result of the operation
    /// - Throws: The last error if all retries fail
    public static func retry<T>(
        config: Config = .default,
        shouldRetry: @escaping (Error) -> Bool = { _ in true },
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var delay = config.initialDelay
        
        for attempt in 1...config.maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                
                // Check if we should retry
                guard attempt < config.maxAttempts && shouldRetry(error) else {
                    throw error
                }
                
                Logger.warn(
                    "Operation failed (attempt \(attempt)/\(config.maxAttempts)), retrying in \(delay)s: \(error)",
                    context: "RetryHelper"
                )
                
                // Wait before retry
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
                // Increase delay for next attempt (exponential backoff)
                delay = min(delay * config.multiplier, config.maxDelay)
            }
        }
        
        throw lastError ?? NSError(
            domain: "RetryHelper",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "All retry attempts failed"]
        )
    }
    
    /// Check if an error is retryable (network errors, timeouts, etc.)
    public static func isRetryable(_ error: Error) -> Bool {
        // Network errors
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        
        // Pubky SDK errors - only network errors are retryable
        if let sdkError = error as? PubkySDKError {
            switch sdkError {
            case .networkError:
                return true
            case .notInitialized, .authenticationFailed, .sessionNotFound, .storageError, .invalidInput:
                return false
            }
        }
        
        return false
    }
}

/// User-friendly error messages
public extension Error {
    
    /// Get a user-friendly error message
    var userFriendlyMessage: String {
        // URL errors
        if let urlError = self as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Request timed out. Please try again."
            case .cannotFindHost, .cannotConnectToHost:
                return "Cannot connect to server. Please check your internet connection."
            case .networkConnectionLost:
                return "Network connection lost. Please try again."
            case .notConnectedToInternet:
                return "No internet connection. Please connect and try again."
            default:
                return "Network error occurred. Please try again."
            }
        }
        
        // Pubky SDK errors
        if let sdkError = self as? PubkySDKError {
            return sdkError.userFriendlyMessage
        }
        
        // Pubky Ring errors
        if let ringError = self as? PubkyRingError {
            switch ringError {
            case .appNotInstalled:
                return "Pubky-ring app is not installed. Please install it to use this feature."
            case .timeout:
                return "Request timed out. Please try again."
            case .cancelled:
                return "Request was cancelled."
            case .invalidCallback, .invalidUrl, .missingParameters:
                return "Received invalid response. Please try again."
            case .failedToOpenApp:
                return "Failed to open Pubky-ring app. Please try again."
            case .crossDeviceFailed(let msg):
                return "Cross-device authentication failed: \(msg)"
            }
        }
        
        // Generic fallback
        return localizedDescription
    }
}

