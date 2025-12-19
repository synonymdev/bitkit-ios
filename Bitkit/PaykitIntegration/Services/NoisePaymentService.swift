//
//  NoisePaymentService.swift
//  Bitkit
//
//  Noise Payment Service for coordinating Noise protocol payments
//

import Foundation
import Network
// PaykitMobile types are available from FFI/PaykitMobile.swift

/// A payment request to send over Noise channel
public struct NoisePaymentRequest {
    public let receiptId: String
    public let payerPubkey: String
    public let payeePubkey: String
    public let methodId: String
    public let amount: String?
    public let currency: String?
    public let description: String?
    /// Invoice number for cross-referencing
    public let invoiceNumber: String?
    
    public init(
        payerPubkey: String,
        payeePubkey: String,
        methodId: String,
        amount: String? = nil,
        currency: String? = nil,
        description: String? = nil,
        invoiceNumber: String? = nil
    ) {
        self.receiptId = "rcpt_\(UUID().uuidString)"
        self.payerPubkey = payerPubkey
        self.payeePubkey = payeePubkey
        self.methodId = methodId
        self.amount = amount
        self.currency = currency
        self.description = description
        self.invoiceNumber = invoiceNumber
    }
}

/// Response from a payment request
public struct NoisePaymentResponse {
    public let success: Bool
    public let receiptId: String?
    public let confirmedAt: Date?
    public let errorCode: String?
    public let errorMessage: String?
}

/// Service errors
public enum NoisePaymentError: LocalizedError {
    case noIdentity
    case keyDerivationFailed(String)
    case endpointNotFound
    case invalidEndpoint(String)
    case connectionFailed(String)
    case handshakeFailed(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case invalidResponse(String)
    case timeout
    case cancelled
    case serverError(code: String, message: String)
    
    public var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "No identity configured"
        case .keyDerivationFailed(let msg):
            return "Failed to derive encryption keys: \(msg)"
        case .endpointNotFound:
            return "Recipient has no Noise endpoint published"
        case .invalidEndpoint(let msg):
            return "Invalid endpoint format: \(msg)"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .handshakeFailed(let msg):
            return "Secure handshake failed: \(msg)"
        case .encryptionFailed(let msg):
            return "Encryption failed: \(msg)"
        case .decryptionFailed(let msg):
            return "Decryption failed: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        case .timeout:
            return "Operation timed out"
        case .cancelled:
            return "Operation cancelled"
        case .serverError(let code, let message):
            return "Server error [\(code)]: \(message)"
        }
    }
}

/// Service for coordinating Noise protocol payments
public final class NoisePaymentService {
    
    public static let shared = NoisePaymentService()
    
    private var paykitClient: PaykitClient?
    
    private init() {}
    
    /// Initialize with PaykitClient
    public func initialize(client: PaykitClient) {
        self.paykitClient = client
    }
    
    /// Send a payment request over Noise protocol
    public func sendPaymentRequest(_ request: NoisePaymentRequest) async throws -> NoisePaymentResponse {
        guard let client = paykitClient else {
            throw NoisePaymentError.noIdentity
        }
        
        // In production, this would:
        // 1. Discover Noise endpoint for recipient
        // 2. Derive X25519 keys via PubkyRingIntegration
        // 3. Establish Noise handshake
        // 4. Encrypt and send payment request
        // 5. Handle response
        
        // Simplified implementation for now
        throw NoisePaymentError.endpointNotFound
    }
    
    /// Receive a payment request (server mode)
    public func receivePaymentRequest() async throws -> NoisePaymentRequest? {
        // In production, this would:
        // 1. Listen for incoming Noise connections
        // 2. Perform handshake
        // 3. Decrypt and parse payment request
        // 4. Return request for processing
        
        return nil
    }
    
    // MARK: - Background Server Mode
    
    private var serverConnection: NWListener?
    private var isServerRunning = false
    private var onRequestCallback: ((NoisePaymentRequest) -> Void)?
    
    /// Start a background Noise server to receive incoming payment requests.
    /// This is called when the app is woken by a push notification indicating
    /// an incoming Noise connection.
    ///
    /// - Parameters:
    ///   - port: Port to listen on
    ///   - onRequest: Callback invoked when a payment request is received
    public func startBackgroundServer(
        port: UInt16,
        onRequest: @escaping (NoisePaymentRequest) -> Void
    ) async throws {
        guard !isServerRunning else {
            Logger.warn("NoisePaymentService: Background server already running", context: "NoisePaymentService")
            return
        }
        
        self.onRequestCallback = onRequest
        
        do {
            // Create NWListener for incoming connections
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.serverConnection = listener
            self.isServerRunning = true
            
            Logger.info("NoisePaymentService: Starting Noise server on port \(port)", context: "NoisePaymentService")
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleServerConnection(connection)
            }
            
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Logger.info("NoisePaymentService: Server ready on port \(port)", context: "NoisePaymentService")
                case .failed(let error):
                    Logger.error("NoisePaymentService: Server failed: \(error)", context: "NoisePaymentService")
                    self?.stopBackgroundServer()
                case .cancelled:
                    Logger.info("NoisePaymentService: Server cancelled", context: "NoisePaymentService")
                default:
                    break
                }
            }
            
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            
            // Wait for connection with timeout
            try await withTimeout(seconds: 30) { [weak self] in
                // Keep server running until connection is handled
                while self?.isServerRunning == true {
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
            
        } catch {
            Logger.error("NoisePaymentService: Server error: \(error)", context: "NoisePaymentService")
            stopBackgroundServer()
            throw error
        }
    }
    
    /// Stop the background server
    public func stopBackgroundServer() {
        serverConnection?.cancel()
        serverConnection = nil
        isServerRunning = false
        onRequestCallback = nil
        Logger.info("NoisePaymentService: Background server stopped", context: "NoisePaymentService")
    }
    
    /// Handle an incoming server connection
    private func handleServerConnection(_ connection: NWConnection) {
        Logger.info("NoisePaymentService: Received incoming connection", context: "NoisePaymentService")
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveFromConnection(connection)
            case .failed(let error):
                Logger.error("NoisePaymentService: Connection failed: \(error)", context: "NoisePaymentService")
                self?.stopBackgroundServer()
            default:
                break
            }
        }
        
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    }
    
    /// Receive data from connection and process as payment request
    private func receiveFromConnection(_ connection: NWConnection) {
        // Read length prefix (4 bytes)
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let lengthData = data, error == nil else {
                Logger.error("NoisePaymentService: Failed to receive length: \(error?.localizedDescription ?? "unknown")", context: "NoisePaymentService")
                self?.stopBackgroundServer()
                return
            }
            
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            // Read message body
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, _, error in
                guard let messageData = data, error == nil else {
                    Logger.error("NoisePaymentService: Failed to receive message: \(error?.localizedDescription ?? "unknown")", context: "NoisePaymentService")
                    self?.stopBackgroundServer()
                    return
                }
                
                // Parse the payment request
                self?.parseAndHandleRequest(messageData, connection: connection)
            }
        }
    }
    
    /// Parse incoming message and handle as payment request
    private func parseAndHandleRequest(_ data: Data, connection: NWConnection) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NoisePaymentError.invalidResponse("Invalid JSON structure")
            }
            
            guard let type = json["type"] as? String, type == "request_receipt" else {
                throw NoisePaymentError.invalidResponse("Unexpected message type")
            }
            
            let request = NoisePaymentRequest(
                payerPubkey: json["payer"] as? String ?? "",
                payeePubkey: json["payee"] as? String ?? "",
                methodId: json["method_id"] as? String ?? "",
                amount: json["amount"] as? String,
                currency: json["currency"] as? String,
                description: json["description"] as? String,
                invoiceNumber: json["invoice_number"] as? String
            )
            
            // Send confirmation response
            let response: [String: Any] = [
                "type": "confirm_receipt",
                "receipt_id": request.receiptId,
                "confirmed_at": Int(Date().timeIntervalSince1970)
            ]
            
            if let responseData = try? JSONSerialization.data(withJSONObject: response) {
                // Length prefix
                var length = UInt32(responseData.count).bigEndian
                var lengthData = Data(bytes: &length, count: 4)
                lengthData.append(responseData)
                
                connection.send(content: lengthData, completion: .contentProcessed { error in
                    if let error = error {
                        Logger.error("NoisePaymentService: Failed to send response: \(error)", context: "NoisePaymentService")
                    }
                })
            }
            
            // Notify callback
            onRequestCallback?(request)
            Logger.info("NoisePaymentService: Successfully received payment request: \(request.receiptId)", context: "NoisePaymentService")
            
            // Stop server after handling request
            stopBackgroundServer()
            
        } catch {
            Logger.error("NoisePaymentService: Failed to parse request: \(error)", context: "NoisePaymentService")
            stopBackgroundServer()
        }
    }
    
    /// Helper to run async operation with timeout
    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NoisePaymentError.timeout
            }
            
            guard let result = try await group.next() else {
                throw NoisePaymentError.timeout
            }
            
            group.cancelAll()
            return result
        }
    }
}

