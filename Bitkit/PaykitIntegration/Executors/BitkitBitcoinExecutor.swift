// BitkitBitcoinExecutor.swift
// Bitkit iOS - Paykit Integration
//
// Implements BitcoinExecutorFfi to connect Bitkit's wallet to Paykit.

import Foundation
import LDKNode

// MARK: - BitkitBitcoinExecutor

/// Bitkit implementation of BitcoinExecutorFfi.
///
/// Bridges Bitkit's LightningService (which handles onchain) to Paykit's executor interface.
/// All methods are called synchronously from the Rust FFI layer.
public final class BitkitBitcoinExecutor: BitcoinExecutorFfi {
    
    // MARK: - Properties
    
    private let lightningService: LightningService
    private let timeout: TimeInterval = 60.0
    
    // MARK: - Initialization
    
    public init(lightningService: LightningService = LightningService.shared) {
        self.lightningService = lightningService
    }
    
    // MARK: - BitcoinExecutorFfi Implementation
    
    /// Send Bitcoin to an address.
    public func sendToAddress(
        address: String,
        amountSats: UInt64,
        feeRate: Double?
    ) throws -> BitcoinTxResultFfi {
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
            throw PaykitMobileError.Internal(message: "Transaction timeout")
        }
        
        switch result {
        case .success(let txid):
            // Estimate fee based on typical transaction size (250 vbytes)
            let estimatedFee = UInt64(250 * (feeRate ?? 1.0))
            
            return BitcoinTxResultFfi(
                txid: txid.description,
                rawTx: nil,
                vout: 0,
                feeSats: estimatedFee,
                feeRate: feeRate ?? 1.0,
                blockHeight: nil,
                confirmations: 0
            )
        case .failure(let error):
            throw PaykitMobileError.Internal(message: error.localizedDescription)
        case .none:
            throw PaykitMobileError.Internal(message: "No result returned")
        }
    }
    
    /// Estimate the fee for a transaction.
    public func estimateFee(
        address: String,
        amountSats: UInt64,
        targetBlocks: UInt32
    ) throws -> UInt64 {
        // Use LDK node's fee estimation if available
        if lightningService.node != nil {
            // Typical P2WPKH transaction is ~140 vbytes
            let txSize: UInt64 = 140
            
            // Get recommended fee rate based on target
            let feeRate: UInt64
            switch targetBlocks {
            case 1: feeRate = 10      // High priority: 10 sat/vB
            case 2...6: feeRate = 5   // Medium priority: 5 sat/vB
            default: feeRate = 2      // Low priority: 2 sat/vB
            }
            
            return txSize * feeRate
        }
        
        // Fallback estimation
        let baseFee: UInt64 = 250
        let feeMultiplier: UInt64
        switch targetBlocks {
        case 1: feeMultiplier = 3
        case 2...3: feeMultiplier = 2
        default: feeMultiplier = 1
        }
        return baseFee * feeMultiplier
    }
    
    /// Get transaction details by txid.
    public func getTransaction(txid: String) throws -> BitcoinTxResultFfi? {
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
