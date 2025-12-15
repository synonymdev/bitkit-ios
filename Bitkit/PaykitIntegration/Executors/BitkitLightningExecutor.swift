// BitkitLightningExecutor.swift
// Bitkit iOS - Paykit Integration
//
// Implements LightningExecutorFFI to connect Bitkit's Lightning node to Paykit.

import Foundation
import LDKNode
import CryptoKit

// MARK: - BitkitLightningExecutor

/// Bitkit implementation of LightningExecutorFFI.
///
/// Bridges Bitkit's LightningService to Paykit's executor interface.
/// Handles async-to-sync bridging and payment completion polling.
public final class BitkitLightningExecutor {
    
    // MARK: - Properties
    
    private let lightningService: LightningService
    private let timeout: TimeInterval = 60.0
    private let pollingInterval: TimeInterval = 0.5
    
    // MARK: - Initialization
    
    public init(lightningService: LightningService = .shared) {
        self.lightningService = lightningService
    }
    
    // MARK: - LightningExecutorFFI Implementation
    
    /// Pay a BOLT11 invoice.
    ///
    /// Initiates payment and polls for completion to get preimage.
    ///
    /// - Parameters:
    ///   - invoice: BOLT11 invoice string
    ///   - amountMsat: Amount in millisatoshis (for zero-amount invoices)
    ///   - maxFeeMsat: Maximum fee willing to pay
    /// - Returns: Payment result with preimage proof
    public func payInvoice(
        invoice: String,
        amountMsat: UInt64?,
        maxFeeMsat: UInt64?
    ) throws -> LightningPaymentResult {
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
            throw PaykitError.timeout
        }
        
        guard case .success(let paymentHash) = paymentHashResult else {
            if case .failure(let error) = paymentHashResult {
                throw PaykitError.paymentFailed(error.localizedDescription)
            }
            throw PaykitError.unknown("No result returned")
        }
        
        // Poll for payment completion to get preimage
        let paymentResult = try pollForPaymentCompletion(paymentHash: paymentHash.description)
        return paymentResult
    }
    
    /// Poll for payment completion to extract preimage.
    private func pollForPaymentCompletion(paymentHash: String) throws -> LightningPaymentResult {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            if let payments = lightningService.payments {
                for payment in payments {
                    if payment.id.description == paymentHash {
                        switch payment.status {
                        case .succeeded:
                            // Extract payment details from LDKNode PaymentDetails
                            let preimage = payment.preimage?.description ?? ""
                            let amountMsat = payment.amountMsat ?? 0
                            let feeMsat = payment.feeMsat ?? 0
                            
                            return LightningPaymentResult(
                                preimage: preimage,
                                paymentHash: paymentHash,
                                amountMsat: amountMsat,
                                feeMsat: feeMsat,
                                hops: 0,
                                status: .succeeded
                            )
                        case .failed:
                            throw PaykitError.paymentFailed("Payment failed")
                        default:
                            break
                        }
                    }
                }
            }
            
            Thread.sleep(forTimeInterval: pollingInterval)
        }
        
        throw PaykitError.timeout
    }
    
    /// Decode a BOLT11 invoice.
    ///
    /// - Parameter invoice: BOLT11 invoice string
    /// - Returns: Decoded invoice details
    public func decodeInvoice(invoice: String) throws -> DecodedInvoice {
        do {
            let bolt11 = try Bolt11Invoice.fromStr(s: invoice)
            return DecodedInvoice(
                paymentHash: bolt11.paymentHash().description,
                amountMsat: bolt11.amountMilliSatoshis(),
                description: bolt11.description()?.intoInner().description,
                descriptionHash: nil,
                payee: bolt11.payeePubKey()?.description ?? "",
                expiry: bolt11.expiryTime(),
                timestamp: bolt11.timestamp(),
                expired: bolt11.isExpired()
            )
        } catch {
            throw PaykitError.paymentFailed("Failed to decode invoice: \(error.localizedDescription)")
        }
    }
    
    /// Estimate routing fee for an invoice.
    ///
    /// - Parameter invoice: BOLT11 invoice
    /// - Returns: Estimated fee in millisatoshis
    public func estimateFee(invoice: String) throws -> UInt64 {
        // Estimate 1% fee with 1000 msat base
        do {
            let bolt11 = try Bolt11Invoice.fromStr(s: invoice)
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
    ///
    /// - Parameter paymentHash: Payment hash (hex-encoded)
    /// - Returns: Payment result if found
    public func getPayment(paymentHash: String) throws -> LightningPaymentResult? {
        guard let payments = lightningService.payments else {
            return nil
        }
        
        for payment in payments {
            if payment.id.description == paymentHash {
                let status: LightningPaymentStatus = switch payment.status {
                case .succeeded: .succeeded
                case .failed: .failed
                default: .pending
                }
                
                let preimage = payment.preimage?.description ?? ""
                let amountMsat = payment.amountMsat ?? 0
                let feeMsat = payment.feeMsat ?? 0
                
                return LightningPaymentResult(
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
    ///
    /// - Parameters:
    ///   - preimage: Payment preimage (hex-encoded)
    ///   - paymentHash: Payment hash (hex-encoded)
    /// - Returns: true if preimage hashes to payment hash
    public func verifyPreimage(preimage: String, paymentHash: String) -> Bool {
        guard let preimageData = Data(hexString: preimage) else {
            return false
        }
        
        let hash = SHA256.hash(data: preimageData)
        let computedHash = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        return computedHash.lowercased() == paymentHash.lowercased()
    }
}

// MARK: - Lightning Payment Result

public struct LightningPaymentResult {
    public let preimage: String
    public let paymentHash: String
    public let amountMsat: UInt64
    public let feeMsat: UInt64
    public let hops: UInt32
    public let status: LightningPaymentStatus
}

public enum LightningPaymentStatus {
    case pending
    case succeeded
    case failed
}

// MARK: - Decoded Invoice

public struct DecodedInvoice {
    public let paymentHash: String
    public let amountMsat: UInt64?
    public let description: String?
    public let descriptionHash: String?
    public let payee: String
    public let expiry: UInt64
    public let timestamp: UInt64
    public let expired: Bool
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
