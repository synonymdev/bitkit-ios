// PaykitLogger.swift
// Bitkit iOS - Paykit Integration
//
// Structured logging utility for Paykit integration operations.
// Phase 6: Production Hardening

import Foundation
import os.log

// MARK: - PaykitLogger

/// Structured logger for Paykit integration operations.
///
/// Provides consistent logging across all Paykit components with:
/// - Log level filtering
/// - Performance metrics
/// - Error context tracking
/// - Privacy-safe logging
public final class PaykitLogger {
    
    // MARK: - Singleton
    
    public static let shared = PaykitLogger()
    
    private init() {}
    
    // MARK: - Properties
    
    private let subsystem = "to.bitkit.paykit"
    private let log = OSLog(subsystem: "to.bitkit.paykit", category: "general")
    
    // MARK: - Logging Methods
    
    /// Log a debug message.
    public func debug(
        _ message: String,
        category: String = "general",
        context: [String: Any]? = nil
    ) {
        log(message, level: .debug, category: category, context: context)
    }
    
    /// Log an info message.
    public func info(
        _ message: String,
        category: String = "general",
        context: [String: Any]? = nil
    ) {
        log(message, level: .info, category: category, context: context)
    }
    
    /// Log a warning message.
    public func warning(
        _ message: String,
        category: String = "general",
        context: [String: Any]? = nil
    ) {
        log(message, level: .warning, category: category, context: context)
    }
    
    /// Log an error message.
    public func error(
        _ message: String,
        category: String = "general",
        error: Error? = nil,
        context: [String: Any]? = nil
    ) {
        var fullContext = context ?? [:]
        if let error = error {
            fullContext["error"] = error.localizedDescription
            fullContext["error_type"] = String(describing: type(of: error))
        }
        
        log(message, level: .error, category: category, context: fullContext)
        
        // Report to error monitoring
        if let error = error {
            PaykitConfigManager.shared.reportError(error, context: fullContext)
        }
    }
    
    /// Log a payment flow event.
    public func logPaymentFlow(
        event: String,
        paymentMethod: String,
        amount: UInt64? = nil,
        duration: TimeInterval? = nil
    ) {
        guard PaykitConfigManager.shared.logPaymentDetails else {
            info("Payment flow: \(event)", category: "payment")
            return
        }
        
        var context: [String: Any] = ["payment_method": paymentMethod]
        if let amount = amount {
            context["amount_msat"] = amount
        }
        if let duration = duration {
            context["duration_ms"] = duration * 1000
        }
        
        info("Payment flow: \(event)", category: "payment", context: context)
    }
    
    /// Log a performance metric.
    public func logPerformance(
        operation: String,
        duration: TimeInterval,
        success: Bool,
        context: [String: Any]? = nil
    ) {
        var fullContext = context ?? [:]
        fullContext["operation"] = operation
        fullContext["duration_ms"] = duration * 1000
        fullContext["success"] = success
        
        let level: PaykitLogLevel = success ? .info : .warning
        log("Performance: \(operation) (\(Int(duration * 1000))ms)", level: level, category: "performance", context: fullContext)
    }
    
    // MARK: - Private Helpers
    
    private func log(
        _ message: String,
        level: PaykitLogLevel,
        category: String,
        context: [String: Any]?
    ) {
        guard level.rawValue >= PaykitConfigManager.shared.logLevel.rawValue else {
            return
        }
        
        let contextString = context.map { ctx in
            let pairs = ctx.map { "\($0)=\($1)" }.joined(separator: ", ")
            return " [\(pairs)]"
        } ?? ""
        
        let fullMessage = "[\(level.prefix)] \(message)\(contextString)"
        
        let osLogType: OSLogType = switch level {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        case .none: .default
        }
        
        os_log("%{public}@", log: OSLog(subsystem: subsystem, category: category), type: osLogType, fullMessage)
    }
}

// MARK: - PaykitLogLevel Extension

private extension PaykitLogLevel {
    var prefix: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .none: return ""
        }
    }
}

// MARK: - Convenience Logging Functions

/// Log a debug message to Paykit logger.
public func paykitDebug(_ message: String, category: String = "general", context: [String: Any]? = nil) {
    PaykitLogger.shared.debug(message, category: category, context: context)
}

/// Log an info message to Paykit logger.
public func paykitInfo(_ message: String, category: String = "general", context: [String: Any]? = nil) {
    PaykitLogger.shared.info(message, category: category, context: context)
}

/// Log a warning message to Paykit logger.
public func paykitWarning(_ message: String, category: String = "general", context: [String: Any]? = nil) {
    PaykitLogger.shared.warning(message, category: category, context: context)
}

/// Log an error message to Paykit logger.
public func paykitError(_ message: String, category: String = "general", error: Error? = nil, context: [String: Any]? = nil) {
    PaykitLogger.shared.error(message, category: category, error: error, context: context)
}
