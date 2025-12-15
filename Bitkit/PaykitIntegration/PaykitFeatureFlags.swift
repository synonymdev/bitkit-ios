// PaykitFeatureFlags.swift
// Bitkit iOS - Paykit Integration
//
// Feature flags for controlling Paykit integration rollout.

import Foundation

// MARK: - PaykitFeatureFlags

/// Feature flags for Paykit integration.
///
/// Use these flags to control the rollout of Paykit features
/// and enable quick rollback if issues arise.
public enum PaykitFeatureFlags {
    
    // MARK: - Storage Keys
    
    private static let enabledKey = "paykit_enabled"
    private static let lightningEnabledKey = "paykit_lightning_enabled"
    private static let onchainEnabledKey = "paykit_onchain_enabled"
    private static let receiptStorageEnabledKey = "paykit_receipt_storage_enabled"
    
    // MARK: - Main Feature Flag
    
    /// Whether Paykit integration is enabled.
    /// Set to false to completely disable Paykit.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    
    /// Whether Lightning payments via Paykit are enabled.
    public static var isLightningEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: lightningEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: lightningEnabledKey) }
    }
    
    /// Whether on-chain payments via Paykit are enabled.
    public static var isOnchainEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: onchainEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: onchainEnabledKey) }
    }
    
    /// Whether receipt storage is enabled.
    public static var isReceiptStorageEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: receiptStorageEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: receiptStorageEnabledKey) }
    }
    
    // MARK: - Remote Config
    
    /// Update flags from remote config.
    /// Call this during app startup to sync with server-side configuration.
    ///
    /// - Parameter config: Dictionary from remote config service
    public static func updateFromRemoteConfig(_ config: [String: Any]) {
        if let enabled = config["paykit_enabled"] as? Bool {
            isEnabled = enabled
        }
        if let lightningEnabled = config["paykit_lightning_enabled"] as? Bool {
            isLightningEnabled = lightningEnabled
        }
        if let onchainEnabled = config["paykit_onchain_enabled"] as? Bool {
            isOnchainEnabled = onchainEnabled
        }
        if let receiptEnabled = config["paykit_receipt_storage_enabled"] as? Bool {
            isReceiptStorageEnabled = receiptEnabled
        }
    }
    
    // MARK: - Defaults
    
    /// Set default values for all flags.
    /// Call this once during first app launch.
    public static func setDefaults() {
        let defaults: [String: Any] = [
            enabledKey: false, // Disabled by default until ready for rollout
            lightningEnabledKey: true,
            onchainEnabledKey: true,
            receiptStorageEnabledKey: true
        ]
        UserDefaults.standard.register(defaults: defaults)
    }
    
    // MARK: - Rollback
    
    /// Emergency rollback - disable all Paykit features.
    /// Call this if critical issues are detected.
    public static func emergencyRollback() {
        isEnabled = false
        Logger.warn("Paykit emergency rollback triggered", context: "PaykitFeatureFlags")
        
        // Reset manager state
        PaykitManager.shared.reset()
    }
}

// MARK: - PaykitConfigManager

/// Manages Paykit configuration for production deployment.
public final class PaykitConfigManager {
    
    public static let shared = PaykitConfigManager()
    
    private init() {}
    
    // MARK: - Environment
    
    /// Current environment configuration.
    public var environment: PaykitEnvironment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }
    
    // MARK: - Logging
    
    /// Log level for Paykit operations.
    public var logLevel: PaykitLogLevel = .info
    
    /// Whether to log payment details (disable in production for privacy).
    public var logPaymentDetails: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
    // MARK: - Timeouts
    
    /// Default payment timeout in seconds.
    public var defaultPaymentTimeout: TimeInterval = 60.0
    
    /// Lightning payment polling interval in seconds.
    public var lightningPollingInterval: TimeInterval = 0.5
    
    // MARK: - Retry Configuration
    
    /// Maximum number of retry attempts for failed payments.
    public var maxRetryAttempts: Int = 3
    
    /// Base delay between retries in seconds.
    public var retryBaseDelay: TimeInterval = 1.0
    
    // MARK: - Monitoring
    
    /// Error reporting callback.
    /// Set this to integrate with your error monitoring service.
    public var errorReporter: ((Error, [String: Any]?) -> Void)?
    
    /// Report an error to the configured monitoring service.
    public func reportError(_ error: Error, context: [String: Any]? = nil) {
        errorReporter?(error, context)
    }
}

// MARK: - Supporting Types

public enum PaykitEnvironment {
    case development
    case staging
    case production
}

public enum PaykitLogLevel: Int {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case none = 4
}
