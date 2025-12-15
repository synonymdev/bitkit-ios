// PaykitPaymentService.swift
// Bitkit iOS - Paykit Integration
//
// High-level payment service for executing payments via Paykit.
// Provides user-friendly API for payment flows.

import Foundation
import LDKNode

// MARK: - PaykitPaymentService

/// Service for executing payments through Paykit.
///
/// Provides high-level methods for:
/// - Payment discovery (finding recipient payment methods)
/// - Payment execution (Lightning and onchain)
/// - Receipt generation and storage
/// - Payment status tracking
///
/// Usage:
/// ```swift
/// let service = PaykitPaymentService.shared
/// let result = try await service.pay(to: "lnbc...", amount: 10000)
/// ```
public final class PaykitPaymentService {
    
    // MARK: - Singleton
    
    public static let shared = PaykitPaymentService()
    
    // MARK: - Properties
    
    private let manager = PaykitManager.shared
    private let receiptStore = PaykitReceiptStore()
    
    /// Payment timeout in seconds
    public var paymentTimeout: TimeInterval = 60.0
    
    /// Whether to automatically store receipts
    public var autoStoreReceipts: Bool = true
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Payment Discovery
    
    /// Discover available payment methods for a recipient.
    ///
    /// - Parameter recipient: Address, invoice, or Paykit URI
    /// - Returns: Available payment methods
    public func discoverPaymentMethods(for recipient: String) async throws -> [PaymentMethod] {
        // Detect payment type from string
        let paymentType = detectPaymentType(recipient)
        
        switch paymentType {
        case .lightning:
            return [.lightning(invoice: recipient)]
        case .onchain:
            return [.onchain(address: recipient)]
        case .paykit:
            // Query Paykit directory for recipient's payment methods
            let directoryService = DirectoryService.shared
            let pubkey = extractPubkeyFromUri(recipient)
            return try await directoryService.discoverPaymentMethods(for: pubkey)
        case .unknown:
            throw PaykitPaymentError.invalidRecipient(recipient)
        }
    }
    
    /// Detect payment type from a string.
    private func detectPaymentType(_ input: String) -> DetectedPaymentType {
        let lowercased = input.lowercased()
        
        if lowercased.hasPrefix("lnbc") || lowercased.hasPrefix("lntb") || lowercased.hasPrefix("lnbcrt") {
            return .lightning
        } else if lowercased.hasPrefix("bc1") || lowercased.hasPrefix("tb1") || lowercased.hasPrefix("bcrt1") {
            return .onchain
        } else if lowercased.hasPrefix("1") || lowercased.hasPrefix("3") || lowercased.hasPrefix("m") || lowercased.hasPrefix("n") || lowercased.hasPrefix("2") {
            return .onchain
        } else if lowercased.hasPrefix("paykit:") || lowercased.hasPrefix("pip:") {
            return .paykit
        }
        
        return .unknown
    }
    
    // MARK: - Payment Execution
    
    /// Execute a payment to a recipient.
    ///
    /// Automatically detects payment type and routes accordingly.
    ///
    /// - Parameters:
    ///   - recipient: Address, invoice, or Paykit URI
    ///   - amountSats: Amount in satoshis (required for onchain, optional for invoices)
    ///   - feeRate: Fee rate for onchain payments (sat/vB)
    /// - Returns: Payment result with receipt
    public func pay(
        to recipient: String,
        amountSats: UInt64? = nil,
        feeRate: Double? = nil
    ) async throws -> PaykitPaymentResult {
        guard PaykitIntegrationHelper.isReady else {
            throw PaykitPaymentError.notInitialized
        }
        
        let paymentType = detectPaymentType(recipient)
        
        switch paymentType {
        case .lightning:
            return try await payLightning(invoice: recipient, amountSats: amountSats)
        case .onchain:
            guard let amount = amountSats else {
                throw PaykitPaymentError.amountRequired
            }
            return try await payOnchain(address: recipient, amountSats: amount, feeRate: feeRate)
        case .paykit:
            return try await payPaykitUri(uri: recipient, amountSats: amountSats)
        case .unknown:
            throw PaykitPaymentError.invalidRecipient(recipient)
        }
    }
    
    /// Execute a Lightning payment.
    ///
    /// - Parameters:
    ///   - invoice: BOLT11 invoice
    ///   - amountSats: Amount for zero-amount invoices
    /// - Returns: Payment result
    public func payLightning(
        invoice: String,
        amountSats: UInt64? = nil
    ) async throws -> PaykitPaymentResult {
        Logger.info("Executing Lightning payment", context: "PaykitPaymentService")
        
        let startTime = Date()
        
        do {
            let lightningResult = try await PaykitIntegrationHelper.payLightning(
                invoice: invoice,
                amountSats: amountSats
            )
            
            let receipt = PaykitReceipt(
                id: UUID().uuidString,
                type: .lightning,
                recipient: invoice,
                amountSats: amountSats ?? 0,
                feeSats: lightningResult.feeMsat / 1000,
                paymentHash: lightningResult.paymentHash,
                preimage: lightningResult.preimage,
                txid: nil,
                timestamp: Date(),
                status: .succeeded
            )
            
            if autoStoreReceipts {
                receiptStore.store(receipt)
            }
            
            let duration = Date().timeIntervalSince(startTime)
            Logger.info("Lightning payment succeeded in \(String(format: "%.2f", duration))s", context: "PaykitPaymentService")
            
            return PaykitPaymentResult(
                success: true,
                receipt: receipt,
                error: nil
            )
        } catch {
            Logger.error("Lightning payment failed: \(error)", context: "PaykitPaymentService")
            
            let receipt = PaykitReceipt(
                id: UUID().uuidString,
                type: .lightning,
                recipient: invoice,
                amountSats: amountSats ?? 0,
                feeSats: 0,
                paymentHash: nil,
                preimage: nil,
                txid: nil,
                timestamp: Date(),
                status: .failed
            )
            
            if autoStoreReceipts {
                receiptStore.store(receipt)
            }
            
            return PaykitPaymentResult(
                success: false,
                receipt: receipt,
                error: mapError(error)
            )
        }
    }
    
    /// Execute an onchain payment.
    ///
    /// - Parameters:
    ///   - address: Bitcoin address
    ///   - amountSats: Amount in satoshis
    ///   - feeRate: Fee rate in sat/vB
    /// - Returns: Payment result
    public func payOnchain(
        address: String,
        amountSats: UInt64,
        feeRate: Double? = nil
    ) async throws -> PaykitPaymentResult {
        Logger.info("Executing onchain payment", context: "PaykitPaymentService")
        
        let startTime = Date()
        
        do {
            let txResult = try await PaykitIntegrationHelper.payOnchain(
                address: address,
                amountSats: amountSats,
                feeRate: feeRate
            )
            
            let receipt = PaykitReceipt(
                id: UUID().uuidString,
                type: .onchain,
                recipient: address,
                amountSats: amountSats,
                feeSats: txResult.feeSats,
                paymentHash: nil,
                preimage: nil,
                txid: txResult.txid,
                timestamp: Date(),
                status: .pending // Onchain starts as pending until confirmed
            )
            
            if autoStoreReceipts {
                receiptStore.store(receipt)
            }
            
            let duration = Date().timeIntervalSince(startTime)
            Logger.info("Onchain payment broadcast in \(String(format: "%.2f", duration))s, txid: \(txResult.txid)", context: "PaykitPaymentService")
            
            return PaykitPaymentResult(
                success: true,
                receipt: receipt,
                error: nil
            )
        } catch {
            Logger.error("Onchain payment failed: \(error)", context: "PaykitPaymentService")
            
            let receipt = PaykitReceipt(
                id: UUID().uuidString,
                type: .onchain,
                recipient: address,
                amountSats: amountSats,
                feeSats: 0,
                paymentHash: nil,
                preimage: nil,
                txid: nil,
                timestamp: Date(),
                status: .failed
            )
            
            if autoStoreReceipts {
                receiptStore.store(receipt)
            }
            
            return PaykitPaymentResult(
                success: false,
                receipt: receipt,
                error: mapError(error)
            )
        }
    }
    
    /// Execute a Paykit URI payment.
    ///
    /// - Parameters:
    ///   - uri: The Paykit URI (e.g., "paykit:pubkey" or "pip:pubkey")
    ///   - amountSats: Amount in satoshis
    /// - Returns: Payment result
    private func payPaykitUri(uri: String, amountSats: UInt64?) async throws -> PaykitPaymentResult {
        Logger.info("Executing Paykit URI payment: \(uri)", context: "PaykitPaymentService")
        
        let pubkey = extractPubkeyFromUri(uri)
        let directoryService = DirectoryService.shared
        
        // Discover payment methods for the recipient
        let methods = try await directoryService.discoverPaymentMethods(for: pubkey)
        guard let firstMethod = methods.first else {
            throw PaykitPaymentError.invalidRecipient("No payment methods found for \(pubkey)")
        }
        
        // Execute payment using the first available method
        guard let client = manager.client else {
            throw PaykitPaymentError.notInitialized
        }
        
        let amount = amountSats ?? 0
        let result = try client.executePayment(
            methodId: firstMethod.methodId,
            endpoint: firstMethod.endpoint,
            amountSats: amount,
            metadataJson: nil
        )
        
        let receipt = PaykitReceipt(
            id: UUID().uuidString,
            type: .lightning, // Assume Lightning for Paykit payments
            recipient: pubkey,
            amountSats: amount,
            feeSats: 0, // Fee not available from PaykitMobile
            paymentHash: result.executionId,
            preimage: nil,
            txid: result.executionId,
            timestamp: Date(),
            status: .succeeded
        )
        
        if autoStoreReceipts {
            receiptStore.store(receipt)
        }
        
        return PaykitPaymentResult(
            success: true,
            receipt: receipt,
            error: nil
        )
    }
    
    /// Extract pubkey from Paykit URI.
    private func extractPubkeyFromUri(_ uri: String) -> String {
        // Remove scheme prefix (paykit: or pip:)
        let cleaned = uri
            .replacingOccurrences(of: "paykit:", with: "")
            .replacingOccurrences(of: "pip:", with: "")
            .trimmingCharacters(in: .whitespaces)
        
        // If it's a full URL, extract the pubkey from the path
        if let url = URL(string: cleaned), let host = url.host {
            return host
        }
        
        return cleaned
    }
    
    // MARK: - Receipt Management
    
    /// Get all stored receipts.
    public func getReceipts() -> [PaykitReceipt] {
        return receiptStore.getAll()
    }
    
    /// Get receipt by ID.
    public func getReceipt(id: String) -> PaykitReceipt? {
        return receiptStore.get(id: id)
    }
    
    /// Clear all receipts.
    public func clearReceipts() {
        receiptStore.clear()
    }
    
    // MARK: - Error Mapping
    
    private func mapError(_ error: Error) -> PaykitPaymentError {
        if let paykitError = error as? PaykitError {
            switch paykitError {
            case .notInitialized:
                return .notInitialized
            case .timeout:
                return .timeout
            case .paymentFailed(let message):
                return .paymentFailed(message)
            default:
                return .unknown(error.localizedDescription)
            }
        }
        return .unknown(error.localizedDescription)
    }
}

// MARK: - Supporting Types

/// Detected payment type from input string.
private enum DetectedPaymentType {
    case lightning
    case onchain
    case paykit
    case unknown
}

/// Available payment method for a recipient.
public enum PaymentMethod {
    case lightning(invoice: String)
    case onchain(address: String)
    case paykit(uri: String)
}

/// Result of a payment operation.
public struct PaykitPaymentResult {
    public let success: Bool
    public let receipt: PaykitReceipt
    public let error: PaykitPaymentError?
}

/// Payment receipt for record keeping.
public struct PaykitReceipt: Codable, Identifiable {
    public let id: String
    public let type: PaykitReceiptType
    public let recipient: String
    public let amountSats: UInt64
    public let feeSats: UInt64
    public let paymentHash: String?
    public let preimage: String?
    public let txid: String?
    public let timestamp: Date
    public var status: PaykitReceiptStatus
}

public enum PaykitReceiptType: String, Codable {
    case lightning
    case onchain
}

public enum PaykitReceiptStatus: String, Codable {
    case pending
    case succeeded
    case failed
}

/// Errors specific to payment operations.
public enum PaykitPaymentError: LocalizedError {
    case notInitialized
    case invalidRecipient(String)
    case amountRequired
    case insufficientFunds
    case paymentFailed(String)
    case timeout
    case unsupportedPaymentType
    case unknown(String)
    
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Payment service not initialized"
        case .invalidRecipient(let recipient):
            return "Invalid recipient: \(recipient)"
        case .amountRequired:
            return "Amount is required for this payment type"
        case .insufficientFunds:
            return "Insufficient funds for payment"
        case .paymentFailed(let message):
            return "Payment failed: \(message)"
        case .timeout:
            return "Payment timed out"
        case .unsupportedPaymentType:
            return "Unsupported payment type"
        case .unknown(let message):
            return message
        }
    }
    
    /// User-friendly message for display.
    public var userMessage: String {
        switch self {
        case .notInitialized:
            return "Please wait for the app to initialize"
        case .invalidRecipient:
            return "Please check the payment address or invoice"
        case .amountRequired:
            return "Please enter an amount"
        case .insufficientFunds:
            return "You don't have enough funds for this payment"
        case .paymentFailed:
            return "Payment could not be completed. Please try again."
        case .timeout:
            return "Payment is taking longer than expected"
        case .unsupportedPaymentType:
            return "This payment type is not supported yet"
        case .unknown:
            return "An unexpected error occurred"
        }
    }
}


// MARK: - Receipt Store
// Note: PaykitReceiptStore is now in PaykitReceiptStore.swift with persistent storage
