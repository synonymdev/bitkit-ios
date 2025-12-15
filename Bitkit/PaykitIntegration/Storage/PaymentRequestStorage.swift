//
//  PaymentRequestStorage.swift
//  Bitkit
//
//  Persistent storage for payment requests using Keychain.
//

import Foundation

/// Manages persistent storage of payment requests
public class PaymentRequestStorage {
    
    private let keychain: PaykitKeychainStorage
    private let identityName: String
    private let maxRequestsToKeep = 200  // Limit stored requests
    
    // In-memory cache
    private var requestsCache: [PaymentRequest]?
    
    private var requestsKey: String {
        "paykit.payment_requests.\(identityName)"
    }
    
    public init(identityName: String = "default", keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.identityName = identityName
        self.keychain = keychain
    }
    
    // MARK: - CRUD Operations
    
    /// Get all requests (newest first)
    public func listRequests() -> [PaymentRequest] {
        if let cached = requestsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: requestsKey) else {
                return []
            }
            var requests = try JSONDecoder().decode([PaymentRequest].self, from: data)
            // Sort by date, newest first
            requests.sort { $0.createdAt > $1.createdAt }
            requestsCache = requests
            return requests
        } catch {
            Logger.error("PaymentRequestStorage: Failed to load requests: \(error)", context: "PaymentRequestStorage")
            return []
        }
    }
    
    /// Get pending requests only
    public func pendingRequests() -> [PaymentRequest] {
        return listRequests().filter { $0.status == .pending }
    }
    
    /// Get requests filtered by status
    public func listRequests(status: PaymentRequestStatus) -> [PaymentRequest] {
        return listRequests().filter { $0.status == status }
    }
    
    /// Get requests filtered by direction
    public func listRequests(direction: RequestDirection) -> [PaymentRequest] {
        return listRequests().filter { $0.direction == direction }
    }
    
    /// Get recent requests (limited count)
    public func recentRequests(limit: Int = 10) -> [PaymentRequest] {
        return Array(listRequests().prefix(limit))
    }
    
    /// Get a specific request
    public func getRequest(id: String) -> PaymentRequest? {
        return listRequests().first { $0.id == id }
    }
    
    /// Add a new request
    public func addRequest(_ request: PaymentRequest) throws {
        var requests = listRequests()
        
        // Add new request at the beginning (newest first)
        requests.insert(request, at: 0)
        
        // Trim to max size
        if requests.count > maxRequestsToKeep {
            requests = Array(requests.prefix(maxRequestsToKeep))
        }
        
        try persistRequests(requests)
    }
    
    /// Update an existing request
    public func updateRequest(_ request: PaymentRequest) throws {
        var requests = listRequests()
        
        guard let index = requests.firstIndex(where: { $0.id == request.id }) else {
            throw PaykitStorageError.loadFailed(key: request.id)
        }
        
        requests[index] = request
        try persistRequests(requests)
    }
    
    /// Update request status
    public func updateStatus(id: String, status: PaymentRequestStatus) throws {
        guard var request = getRequest(id: id) else {
            throw PaykitStorageError.loadFailed(key: id)
        }
        var updatedRequest = request
        updatedRequest.status = status
        try updateRequest(updatedRequest)
    }
    
    /// Delete a request
    public func deleteRequest(id: String) throws {
        var requests = listRequests()
        requests.removeAll { $0.id == id }
        try persistRequests(requests)
    }
    
    /// Check and mark expired requests
    public func checkExpirations() throws {
        let now = Date()
        var requests = listRequests()
        var hasChanges = false
        
        for i in 0..<requests.count {
            if requests[i].status == .pending,
               let expiresAt = requests[i].expiresAt,
               expiresAt < now {
                var updatedRequest = requests[i]
                updatedRequest.status = .expired
                requests[i] = updatedRequest
                hasChanges = true
            }
        }
        
        if hasChanges {
            try persistRequests(requests)
        }
    }
    
    /// Clear all requests
    public func clearAll() throws {
        try persistRequests([])
    }
    
    // MARK: - Statistics
    
    /// Count of pending requests
    public func pendingCount() -> Int {
        return listRequests(status: .pending).count
    }
    
    /// Count of incoming pending requests
    public func incomingPendingCount() -> Int {
        return listRequests(direction: .incoming).filter { $0.status == .pending }.count
    }
    
    /// Count of outgoing pending requests
    public func outgoingPendingCount() -> Int {
        return listRequests(direction: .outgoing).filter { $0.status == .pending }.count
    }
    
    // MARK: - Private
    
    private func persistRequests(_ requests: [PaymentRequest]) throws {
        let data = try JSONEncoder().encode(requests)
        try keychain.store(key: requestsKey, data: data)
        requestsCache = requests
    }
}

