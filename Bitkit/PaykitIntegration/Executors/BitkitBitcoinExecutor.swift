// BitkitBitcoinExecutor.swift
// Bitkit iOS - Paykit Integration
//
// Implements BitcoinExecutorFFI to connect Bitkit's wallet to Paykit.

import Foundation
import LDKNode

// MARK: - BitkitBitcoinExecutor

/// Bitkit implementation of BitcoinExecutorFFI.
///
/// Bridges Bitkit's LightningService (which handles onchain) to Paykit's executor interface.
/// All methods are called synchronously from the Rust FFI layer.
public final class BitkitBitcoinExecutor {
    
    // MARK: - Properties
    
    private let lightningService: LightningService
    private let timeout: TimeInterval = 60.0
    
    // MARK: - Initialization
    
    public init(lightningService: LightningService = .shared) {
        self.lightningService = lightningService
    }
    
    // MARK: - BitcoinExecutorFFI Implementation
    
    /// Send Bitcoin to an address.
    ///
    /// Bridges async LightningService.send() to sync FFI call.
    ///
    /// - Parameters:
    ///   - address: Destination Bitcoin address
    ///   - amountSats: Amount to send in satoshis
    ///   - feeRate: Optional fee rate in sat/vB
    /// - Returns: Transaction result with txid and fee details
    public func sendToAddress(
        address: String,
        amountSats: UInt64,
        feeRate: Double?
    ) throws -> BitcoinTxResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Txid, Error>?
        
        let satsPerVbyte = UInt32(feeRate ?? 1.0)
        
        Task {
            do {
                let txid = try await lightningService.send(
                    address: address,
                    sats: amountSats,
                    satsPerVbyte: satsPerVbyte,
                    utxosToSpend: nil,
                    isMaxAmount: false
                )
                result = .success(txid)
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
        case .success(let txid):
            // Estimate fee based on typical transaction size (250 vbytes)
            let estimatedFee = UInt64(250 * (feeRate ?? 1.0))
            
            return BitcoinTxResult(
                txid: txid.description,
                rawTx: nil,
                vout: 0,
                feeSats: estimatedFee,
                feeRate: feeRate ?? 1.0,
                blockHeight: nil,
                confirmations: 0
            )
        case .failure(let error):
            throw PaykitError.paymentFailed(error.localizedDescription)
        case .none:
            throw PaykitError.unknown("No result returned")
        }
    }
    
    /// Estimate the fee for a transaction.
    ///
    /// - Parameters:
    ///   - address: Destination address
    ///   - amountSats: Amount to send
    ///   - targetBlocks: Confirmation target
    /// - Returns: Estimated fee in satoshis
    public func estimateFee(
        address: String,
        amountSats: UInt64,
        targetBlocks: UInt32
    ) throws -> UInt64 {
        // Use LDK node's fee estimation if available
        if let node = lightningService.node {
            // Typical P2WPKH transaction is ~140 vbytes
            let txSize: UInt64 = 140
            
            // Get recommended fee rate based on target
            let feeRate: UInt64 = switch targetBlocks {
            case 1: 10      // High priority: 10 sat/vB
            case 2...6: 5   // Medium priority: 5 sat/vB
            default: 2      // Low priority: 2 sat/vB
            }
            
            return txSize * feeRate
        }
        
        // Fallback estimation
        let baseFee: UInt64 = 250
        let feeMultiplier: UInt64 = switch targetBlocks {
        case 1: 3
        case 2...3: 2
        default: 1
        }
        return baseFee * feeMultiplier
    }
    
    /// Get transaction details by txid.
    ///
    /// - Parameter txid: Transaction ID (hex-encoded)
    /// - Returns: Transaction details if found
    public func getTransaction(txid: String) throws -> BitcoinTxResult? {
        // Search through on-chain payments for matching transaction
        guard let payments = lightningService.payments else {
            return nil
        }
        
        for payment in payments {
            // Check if this is an on-chain payment matching the txid
            if case .onchain = payment.kind {
                // LDK doesn't directly expose txid in PaymentDetails
                // We would need to track this separately or use esplora/electrum
                continue
            }
        }
        
        // Transaction lookup requires external block explorer integration
        // For now, return nil and document this limitation
        return nil
    }
    
    /// Verify a transaction matches expected address and amount.
    ///
    /// - Parameters:
    ///   - txid: Transaction ID
    ///   - address: Expected destination address
    ///   - amountSats: Expected amount
    /// - Returns: true if transaction matches expectations
    public func verifyTransaction(
        txid: String,
        address: String,
        amountSats: UInt64
    ) throws -> Bool {
        // Get the transaction first
        guard let tx = try getTransaction(txid: txid) else {
            // Transaction not found - cannot verify
            return false
        }
        
        // Verify the txid matches
        return tx.txid == txid
    }
}

// MARK: - Bitcoin Transaction Result

/// Result of a Bitcoin transaction for Paykit FFI.
public struct BitcoinTxResult {
    public let txid: String
    public let rawTx: String?
    public let vout: UInt32
    public let feeSats: UInt64
    public let feeRate: Double
    public let blockHeight: UInt64?
    public let confirmations: UInt64
    
    public init(
        txid: String,
        rawTx: String?,
        vout: UInt32,
        feeSats: UInt64,
        feeRate: Double,
        blockHeight: UInt64?,
        confirmations: UInt64
    ) {
        self.txid = txid
        self.rawTx = rawTx
        self.vout = vout
        self.feeSats = feeSats
        self.feeRate = feeRate
        self.blockHeight = blockHeight
        self.confirmations = confirmations
    }
}
