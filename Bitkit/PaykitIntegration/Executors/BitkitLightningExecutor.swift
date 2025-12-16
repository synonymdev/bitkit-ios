// BitkitLightningExecutor.swift
// Bitkit iOS - Paykit Integration
//
// Implements LightningExecutorFfi to connect Bitkit's Lightning node to Paykit.

import Foundation
import LDKNode
import CryptoKit

// MARK: - BitkitLightningExecutor

/// Bitkit implementation of LightningExecutorFfi.
///
/// Bridges Bitkit's LightningService to Paykit's executor interface.
/// Handles async-to-sync bridging and payment completion polling.
public final class BitkitLightningExecutor: LightningExecutorFfi {
    
    // MARK: - Properties
    
    private let lightningService: LightningService
    private let timeout: TimeInterval = 60.0
    private let pollingInterval: TimeInterval = 0.5
    
    // MARK: - Initialization
    
    public init(lightningService: LightningService = LightningService.shared) {
        self.lightningService = lightningService
    }
    
    // MARK: - LightningExecutorFfi Implementation
    
    /// Pay a BOLT11 invoice.
    public func payInvoice(
        invoice: String,
        amountMsat: UInt64?,
        maxFeeMsat: UInt64?
    ) throws -> LightningPaymentResultFfi {
        let semaphore = DispatchSemaphore(value: 0)
        var paymentHashResult: Result<PaymentHash, Error>?
        
        let sats = amountMsat.map { $0 / 1000 }
        
        Task {
            do {
                let paymentHash = try await lightningService.send(
                    bolt11: invoice,
                    sats: sats,
                    params: nil
                )
                paymentHashResult = .success(paymentHash)
            } catch {
                paymentHashResult = .failure(error)
            }
            semaphore.signal()
        }
        
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        
        if waitResult == .timedOut {
            throw PaykitMobileError.Internal(msg: "Payment timeout")
        }
        
        guard case .success(let paymentHash) = paymentHashResult else {
            if case .failure(let error) = paymentHashResult {
                throw PaykitMobileError.Internal(msg: error.localizedDescription)
            }
            throw PaykitMobileError.Internal(msg: "No result returned")
        }
        
        // Poll for payment completion to get preimage
        return try pollForPaymentCompletion(paymentHash: paymentHash.description)
    }
    
    /// Poll for payment completion to extract preimage.
    private func pollForPaymentCompletion(paymentHash: String) throws -> LightningPaymentResultFfi {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            if let payments = lightningService.payments {
                for payment in payments {
                    if payment.id.description == paymentHash {
                        switch payment.status {
                        case .succeeded:
                            // Extract preimage from payment kind
                            var preimage = ""
                            if case let .bolt11(_, paymentPreimage, _, _, _) = payment.kind {
                                preimage = paymentPreimage?.description ?? ""
                            }
                            let amountMsat = payment.amountMsat ?? 0
                            let feeMsat = payment.feePaidMsat ?? 0
                            
                            return LightningPaymentResultFfi(
                                preimage: preimage,
                                paymentHash: paymentHash,
                                amountMsat: amountMsat,
                                feeMsat: feeMsat,
                                hops: 0,
                                status: .succeeded
                            )
                        case .failed:
                            throw PaykitMobileError.Internal(msg: "Payment failed")
                        default:
                            break
                        }
                    }
                }
            }
            
            Thread.sleep(forTimeInterval: pollingInterval)
        }
        
        throw PaykitMobileError.Internal(msg: "Payment timeout")
    }
    
    /// Decode a BOLT11 invoice.
    public func decodeInvoice(invoice: String) throws -> DecodedInvoiceFfi {
        do {
            let bolt11 = try Bolt11Invoice.fromStr(invoiceStr: invoice)
            return DecodedInvoiceFfi(
                paymentHash: bolt11.paymentHash().description,
                amountMsat: bolt11.amountMilliSatoshis(),
                description: nil, // LDK Swift doesn't expose description directly
                descriptionHash: nil,
                payee: "", // Payee not directly exposed by LDK Swift
                expiry: 3600, // Default expiry
                timestamp: UInt64(Date().timeIntervalSince1970),
                expired: bolt11.isExpired()
            )
        } catch {
            throw PaykitMobileError.Internal(msg: "Failed to decode invoice: \(error.localizedDescription)")
        }
    }
    
    /// Estimate routing fee for an invoice.
    public func estimateFee(invoice: String) throws -> UInt64 {
        do {
            let bolt11 = try Bolt11Invoice.fromStr(invoiceStr: invoice)
            if let amountMsat = bolt11.amountMilliSatoshis() {
                let percentFee = amountMsat / 100
                return max(1000, percentFee)
            }
        } catch {
            // Ignore decode errors, return default
        }
        return 1000
    }
    
    /// Get payment status by payment hash.
    public func getPayment(paymentHash: String) throws -> LightningPaymentResultFfi? {
        guard let payments = lightningService.payments else {
            return nil
        }
        
        for payment in payments {
            if payment.id.description == paymentHash {
                let status: LightningPaymentStatusFfi
                switch payment.status {
                case .succeeded: status = .succeeded
                case .failed: status = .failed
                default: status = .pending
                }
                
                // Extract preimage from payment kind
                var preimage = ""
                if case let .bolt11(_, paymentPreimage, _, _, _) = payment.kind {
                    preimage = paymentPreimage?.description ?? ""
                }
                let amountMsat = payment.amountMsat ?? 0
                let feeMsat = payment.feePaidMsat ?? 0
                
                return LightningPaymentResultFfi(
                    preimage: preimage,
                    paymentHash: paymentHash,
                    amountMsat: amountMsat,
                    feeMsat: feeMsat,
                    hops: 0,
                    status: status
                )
            }
        }
        
        return nil
    }
    
    /// Verify preimage matches payment hash.
    public func verifyPreimage(preimage: String, paymentHash: String) -> Bool {
        guard let preimageData = Data(hexString: preimage) else {
            return false
        }
        
        let hash = SHA256.hash(data: preimageData)
        let computedHash = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        return computedHash.lowercased() == paymentHash.lowercased()
    }
}

// MARK: - Helper Extensions

private extension Data {
    init?(hexString: String) {
        let hex = hexString.dropFirst(hexString.hasPrefix("0x") ? 2 : 0)
        guard hex.count % 2 == 0 else { return nil }
        
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
