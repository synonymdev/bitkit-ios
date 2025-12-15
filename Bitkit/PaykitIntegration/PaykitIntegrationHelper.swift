// PaykitIntegrationHelper.swift
// Bitkit iOS - Paykit Integration
//
// Helper functions for integrating Paykit with Bitkit's existing services.

import Foundation
import LDKNode

// MARK: - PaykitIntegrationHelper

/// Helper class for setting up and managing Paykit integration.
///
/// Provides convenience methods for common integration tasks.
public enum PaykitIntegrationHelper {
    
    // MARK: - Setup
    
    /// Set up Paykit with Bitkit's wallet and Lightning node.
    ///
    /// Call this during app startup after the wallet is ready.
    ///
    /// - Throws: PaykitError if setup fails
    public static func setup() throws {
        let manager = PaykitManager.shared
        
        try manager.initialize()
        try manager.registerExecutors()
        
        Logger.info("Paykit integration setup complete", context: "PaykitIntegrationHelper")
    }
    
    /// Set up Paykit asynchronously.
    ///
    /// - Returns: True if setup succeeded
    public static func setupAsync() async -> Bool {
        do {
            try setup()
            return true
        } catch {
            Logger.error("Paykit setup failed: \(error)", context: "PaykitIntegrationHelper")
            return false
        }
    }
    
    // MARK: - Status
    
    /// Check if Paykit is ready for use.
    public static var isReady: Bool {
        let manager = PaykitManager.shared
        return manager.isInitialized && manager.hasExecutors
    }
    
    /// Get the current network configuration.
    public static var networkInfo: (bitcoin: BitcoinNetworkConfig, lightning: LightningNetworkConfig) {
        let manager = PaykitManager.shared
        return (manager.bitcoinNetwork, manager.lightningNetwork)
    }
    
    // MARK: - Payment Execution
    
    /// Execute a Lightning payment via Paykit.
    ///
    /// - Parameters:
    ///   - invoice: BOLT11 invoice
    ///   - amountSats: Amount in satoshis (for zero-amount invoices)
    /// - Returns: Payment result
    public static func payLightning(
        invoice: String,
        amountSats: UInt64?
    ) async throws -> LightningPaymentResultFfi {
        guard isReady else {
            throw PaykitError.notInitialized
        }
        
        let executor = BitkitLightningExecutor()
        let amountMsat = amountSats.map { $0 * 1000 }
        
        return try executor.payInvoice(
            invoice: invoice,
            amountMsat: amountMsat,
            maxFeeMsat: nil
        )
    }
    
    /// Execute an onchain payment via Paykit.
    ///
    /// - Parameters:
    ///   - address: Bitcoin address
    ///   - amountSats: Amount in satoshis
    ///   - feeRate: Fee rate in sat/vB
    /// - Returns: Transaction result
    public static func payOnchain(
        address: String,
        amountSats: UInt64,
        feeRate: Double?
    ) async throws -> BitcoinTxResultFfi {
        guard isReady else {
            throw PaykitError.notInitialized
        }
        
        let executor = BitkitBitcoinExecutor()
        
        return try executor.sendToAddress(
            address: address,
            amountSats: amountSats,
            feeRate: feeRate
        )
    }
    
    // MARK: - Cleanup
    
    /// Reset Paykit integration state.
    ///
    /// Call this during logout or wallet reset.
    public static func reset() {
        PaykitManager.shared.reset()
        Logger.info("Paykit integration reset", context: "PaykitIntegrationHelper")
    }
}

// MARK: - Async Bridge Utilities

/// Utilities for bridging async/await to sync FFI calls.
public enum AsyncBridge {
    
    /// Execute an async operation synchronously with timeout.
    ///
    /// - Parameters:
    ///   - timeout: Maximum time to wait
    ///   - operation: Async operation to execute
    /// - Returns: Result of the operation
    public static func runSync<T>(
        timeout: TimeInterval = 60.0,
        operation: @escaping () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        
        Task {
            do {
                let value = try await operation()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        
        if waitResult == .timedOut {
            throw PaykitError.timeout
        }
        
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw PaykitError.unknown("No result returned")
        }
    }
}
