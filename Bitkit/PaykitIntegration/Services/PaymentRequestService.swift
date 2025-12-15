//
//  PaymentRequestService.swift
//  Bitkit
//
//  Service for handling payment requests with autopay support
//

import Foundation
import PaykitMobile

/// Result of autopay evaluation
public enum AutopayEvaluationResult {
    case approved(ruleId: String?, ruleName: String?)
    case denied(reason: String)
    case needsApproval
    
    public var isApproved: Bool {
        if case .approved = self { return true }
        return false
    }
}

/// Result of payment request processing
public enum PaymentRequestProcessingResult {
    case autoPaid(paymentResult: PaymentExecutionResult)
    case needsApproval(request: PaymentRequest)
    case denied(reason: String)
    case error(Error)
}

/// Protocol for autopay evaluation
public protocol AutopayEvaluator {
    /// Evaluate if a payment should be auto-approved
    func evaluate(peerPubkey: String, amount: Int64, methodId: String) -> AutopayEvaluationResult
}

/// Service for handling payment requests with autopay support
public class PaymentRequestService {
    
    private let paykitClient: PaykitClient
    private let autopayEvaluator: AutopayEvaluator
    private let paymentRequestStorage: PaymentRequestStorage
    private let directoryService: DirectoryService
    
    /// Initialize with PaykitClient and autopay evaluator
    public init(
        paykitClient: PaykitClient,
        autopayEvaluator: AutopayEvaluator,
        paymentRequestStorage: PaymentRequestStorage = PaymentRequestStorage(),
        directoryService: DirectoryService = DirectoryService.shared
    ) {
        self.paykitClient = paykitClient
        self.autopayEvaluator = autopayEvaluator
        self.paymentRequestStorage = paymentRequestStorage
        self.directoryService = directoryService
    }
    
    /// Handle an incoming payment request
    /// - Parameters:
    ///   - requestId: Payment request ID
    ///   - fromPubkey: Requester's public key
    ///   - completion: Completion handler with processing result
    public func handleIncomingRequest(
        requestId: String,
        fromPubkey: String,
        completion: @escaping (Result<PaymentRequestProcessingResult, Error>) -> Void
    ) {
        Task {
            do {
                // Fetch payment request details from storage
                let request = try await fetchPaymentRequest(requestId: requestId, fromPubkey: fromPubkey)
                
                // Evaluate autopay
                let evaluation = autopayEvaluator.evaluate(
                    peerPubkey: fromPubkey,
                    amount: request.amountSats,
                    methodId: request.methodId
                )
                
                switch evaluation {
                case .approved(let ruleId, let ruleName):
                    // Execute payment automatically
                    do {
                        let endpoint = try await resolveEndpoint(for: request)
                        let paymentResult = try await executePayment(
                            request: request,
                            endpoint: endpoint,
                            metadataJson: nil
                        )
                        
                        // Update request status
                        try paymentRequestStorage.updateStatus(id: requestId, status: .paid)
                        
                        completion(.success(.autoPaid(paymentResult: paymentResult)))
                    } catch {
                        Logger.error("PaymentRequestService: Failed to execute payment", error: error, context: "PaymentRequestService")
                        completion(.success(.error(error)))
                    }
                    
                case .denied(let reason):
                    // Update request status
                    try paymentRequestStorage.updateStatus(id: requestId, status: .declined)
                    completion(.success(.denied(reason: reason)))
                    
                case .needsApproval:
                    completion(.success(.needsApproval(request: request)))
                }
            } catch {
                Logger.error("PaymentRequestService: Failed to handle request", error: error, context: "PaymentRequestService")
                completion(.failure(error))
            }
        }
    }
    
    /// Evaluate autopay for a payment request
    public func evaluateAutopay(
        peerPubkey: String,
        amount: Int64,
        methodId: String
    ) -> AutopayEvaluationResult {
        return autopayEvaluator.evaluate(
            peerPubkey: peerPubkey,
            amount: amount,
            methodId: methodId
        )
    }
    
    /// Execute a payment request
    public func executePayment(
        request: PaymentRequest,
        endpoint: String,
        metadataJson: String?
    ) async throws -> PaymentExecutionResult {
        // Execute payment via PaykitClient
        return try paykitClient.executePayment(
            methodId: request.methodId,
            endpoint: endpoint,
            amountSats: UInt64(request.amountSats),
            metadataJson: metadataJson
        )
    }
    
    // MARK: - Private Helpers
    
    /// Fetch payment request details from storage
    private func fetchPaymentRequest(requestId: String, fromPubkey: String) async throws -> PaymentRequest {
        guard let request = paymentRequestStorage.getRequest(id: requestId) else {
            throw PaymentRequestError.notFound(requestId)
        }
        
        // Verify the request is from the expected pubkey
        if request.fromPubkey != fromPubkey {
            throw PaymentRequestError.pubkeyMismatch
        }
        
        return request
    }
    
    /// Resolve payment endpoint from request
    private func resolveEndpoint(for request: PaymentRequest) async throws -> String {
        // Try to discover payment methods for the sender
        let paymentMethods = try await directoryService.discoverPaymentMethods(for: request.fromPubkey)
        
        // Find matching method - PaymentMethod from FFI has methodId and endpoint
        guard let matchingMethod = paymentMethods.first(where: { $0.methodId == request.methodId }) else {
            throw PaymentRequestError.methodNotFound(request.methodId)
        }
        
        // Return the endpoint from the discovered payment method
        return matchingMethod.endpoint
    }
}

enum PaymentRequestError: LocalizedError {
    case notFound(String)
    case pubkeyMismatch
    case methodNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Payment request not found: \(id)"
        case .pubkeyMismatch:
            return "Payment request pubkey mismatch"
        case .methodNotFound(let methodId):
            return "Payment method not found: \(methodId)"
        }
    }
}

// Make AutoPayViewModel conform to AutopayEvaluator
extension AutoPayViewModel: AutopayEvaluator {
    // Already implements evaluate() method above
}

