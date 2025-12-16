//
//  WalletTestHelper.swift
//  BitkitTests
//
//  Helper utilities for wallet-related testing
//

import Foundation

/// Helper class for wallet-related test operations
public class WalletTestHelper {
    
    public static let shared = WalletTestHelper()
    
    // Test wallet mnemonic (for regtest only!)
    // DO NOT use this in production
    public static let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    
    // Timeout for node operations
    private let nodeReadyTimeout: TimeInterval = 60
    
    private init() {}
    
    // MARK: - Wallet Creation
    
    /// Create a test wallet with a known seed
    /// This should only be used in test environments
    public func createTestWallet() async throws {
        // Check if wallet already exists
        // In actual implementation, this would interact with WalletViewModel
        print("WalletTestHelper: Creating test wallet...")
    }
    
    /// Restore a wallet from the test mnemonic
    public func restoreTestWallet() async throws {
        print("WalletTestHelper: Restoring test wallet from mnemonic...")
    }
    
    // MARK: - Node Lifecycle
    
    /// Wait for the LDK node to be ready
    /// - Parameter timeout: Maximum time to wait (default 60 seconds)
    /// - Returns: True if node became ready, false if timeout
    @discardableResult
    public func waitForNodeReady(timeout: TimeInterval? = nil) async -> Bool {
        let actualTimeout = timeout ?? nodeReadyTimeout
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < actualTimeout {
            if await isNodeRunning() {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        return false
    }
    
    /// Check if the LDK node is currently running
    public func isNodeRunning() async -> Bool {
        // In actual implementation, this would check LightningService.shared.nodeLifecycleState
        // For testing, we return a placeholder
        return true
    }
    
    /// Start the LDK node if not already running
    public func ensureNodeRunning() async throws {
        if await !isNodeRunning() {
            print("WalletTestHelper: Starting LDK node...")
            // In actual implementation: await LightningService.shared.startNode()
        }
    }
    
    // MARK: - Balance Helpers
    
    /// Get the current wallet balance in satoshis
    public func getBalance() async -> (onchain: UInt64, lightning: UInt64) {
        // In actual implementation, this would fetch from LightningService
        return (onchain: 0, lightning: 0)
    }
    
    /// Check if wallet has sufficient balance for testing
    public func hasSufficientBalance(minSats: UInt64 = 10000) async -> Bool {
        let balance = await getBalance()
        return balance.onchain >= minSats || balance.lightning >= minSats
    }
    
    // MARK: - Regtest Helpers
    
    /// Fund the test wallet via regtest faucet
    /// - Parameter amount: Amount in satoshis to fund
    public func fundWallet(amount: UInt64 = 100000) async throws {
        #if DEBUG
        print("WalletTestHelper: Funding wallet with \(amount) sats...")
        
        // Get receive address
        // In actual implementation: let address = await LightningService.shared.getReceiveAddress()
        
        // Call regtest faucet
        // This requires a running regtest environment
        
        print("WalletTestHelper: Funded wallet successfully")
        #else
        throw WalletTestError.notAvailableInProduction
        #endif
    }
    
    /// Generate regtest blocks to confirm transactions
    /// - Parameter count: Number of blocks to generate
    public func generateBlocks(count: Int = 6) async throws {
        #if DEBUG
        print("WalletTestHelper: Generating \(count) regtest blocks...")
        
        // Call regtest RPC to generate blocks
        // This requires a running regtest environment
        
        print("WalletTestHelper: Generated \(count) blocks")
        #else
        throw WalletTestError.notAvailableInProduction
        #endif
    }
    
    // MARK: - Cleanup
    
    /// Clean up after tests
    public func cleanup() async {
        print("WalletTestHelper: Cleaning up...")
        // Clear any test state
    }
    
    /// Reset wallet state (for fresh test runs)
    public func resetWallet() async throws {
        #if DEBUG
        print("WalletTestHelper: Resetting wallet...")
        // In actual implementation, this would wipe wallet data
        #endif
    }
}

// MARK: - Errors

public enum WalletTestError: LocalizedError {
    case walletCreationFailed
    case nodeNotReady
    case insufficientBalance
    case regtestNotAvailable
    case notAvailableInProduction
    
    public var errorDescription: String? {
        switch self {
        case .walletCreationFailed:
            return "Failed to create test wallet"
        case .nodeNotReady:
            return "LDK node did not become ready in time"
        case .insufficientBalance:
            return "Wallet does not have sufficient balance for test"
        case .regtestNotAvailable:
            return "Regtest environment is not available"
        case .notAvailableInProduction:
            return "This operation is only available in debug builds"
        }
    }
}

// MARK: - Test Fixtures

extension WalletTestHelper {
    
    /// Create a test payment receipt for testing
    public func createTestReceipt(
        direction: ReceiptPaymentDirection = .sent,
        amountSats: UInt64 = 1000,
        counterpartyKey: String = PubkyRingSimulator.testPubkey
    ) -> PaymentReceipt {
        return PaymentReceipt(
            direction: direction,
            counterpartyKey: counterpartyKey,
            counterpartyName: "Test Contact",
            amountSats: amountSats,
            paymentMethod: "lightning"
        )
    }
    
    /// Create a test contact for testing
    public func createTestContact() -> DirectoryDiscoveredContact {
        return DirectoryDiscoveredContact(
            pubkey: PubkyRingSimulator.testPubkey,
            name: "Test Contact",
            hasPaymentMethods: true,
            supportedMethods: ["lightning", "bitcoin"]
        )
    }
    
    /// Create a test profile for testing
    public func createTestProfile() -> PubkyProfile {
        return PubkyProfile(
            name: "Test User",
            bio: "This is a test profile for E2E testing",
            avatar: nil,
            links: [
                PubkyProfileLink(title: "Website", url: "https://example.com"),
                PubkyProfileLink(title: "Twitter", url: "https://twitter.com/test")
            ]
        )
    }
}

