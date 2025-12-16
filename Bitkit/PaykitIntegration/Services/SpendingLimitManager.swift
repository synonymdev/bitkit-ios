//
//  SpendingLimitManager.swift
//  Bitkit
//
//  Manages spending limits with atomic reserve/commit/rollback operations.
//  Wraps the Rust FFI for secure, thread-safe spending limit management.
//

import Foundation

/// Manages spending limits with atomic reserve/commit/rollback operations
public class SpendingLimitManager {
    
    public static let shared = SpendingLimitManager()
    
    private var ffiManager: SpendingManagerFfi?
    private let queue = DispatchQueue(label: "to.bitkit.spendinglimit", qos: .userInitiated)
    
    private init() {}
    
    // MARK: - Initialization
    
    /// Initialize the spending limit manager with a storage path
    public func initialize(basePath: String) throws {
        try queue.sync {
            ffiManager = try SpendingManagerFfi(storagePath: basePath)
            Logger.info("SpendingLimitManager initialized at \(basePath)", context: "SpendingLimitManager")
        }
    }
    
    /// Check if the manager is initialized
    public var isInitialized: Bool {
        queue.sync { ffiManager != nil }
    }
    
    // MARK: - Spending Limits
    
    /// Set a spending limit for a peer
    /// - Parameters:
    ///   - peerPubkey: The peer's public key (z-base32 encoded)
    ///   - limitSats: Maximum amount in satoshis
    ///   - period: Reset period ("daily", "weekly", or "monthly")
    /// - Returns: The created spending limit
    public func setSpendingLimit(
        peerPubkey: String,
        limitSats: Int64,
        period: String = "daily"
    ) throws -> PeerSpendingLimitFfi {
        guard let manager = ffiManager else {
            throw SpendingLimitError.notInitialized
        }
        
        let ffiLimit = try manager.setPeerSpendingLimit(
            peerPubkey: peerPubkey,
            limitSats: limitSats,
            period: period
        )
        Logger.info("Set spending limit for \(peerPubkey): \(limitSats) sats (\(period))", context: "SpendingLimitManager")
        
        return ffiLimit
    }
    
    /// Get the spending limit for a peer
    /// - Parameter peerPubkey: The peer's public key
    /// - Returns: The spending limit if set
    public func getSpendingLimit(peerPubkey: String) throws -> PeerSpendingLimitFfi? {
        guard let manager = ffiManager else {
            throw SpendingLimitError.notInitialized
        }
        
        return try manager.getPeerSpendingLimit(peerPubkey: peerPubkey)
    }
    
    /// List all spending limits
    /// - Returns: List of all configured spending limits
    public func listSpendingLimits() throws -> [PeerSpendingLimitFfi] {
        guard let manager = ffiManager else {
            throw SpendingLimitError.notInitialized
        }
        
        return try manager.listSpendingLimits()
    }
    
    /// Remove the spending limit for a peer
    public func removeSpendingLimit(peerPubkey: String) throws {
        guard let manager = ffiManager else {
            throw SpendingLimitError.notInitialized
        }
        
        try manager.removePeerSpendingLimit(peerPubkey: peerPubkey)
        Logger.info("Removed spending limit for \(peerPubkey)", context: "SpendingLimitManager")
    }
    
    // MARK: - Atomic Spending Operations
    
    /// Try to reserve spending against a peer's limit atomically
    /// - Parameters:
    ///   - peerPubkey: The peer's public key
    ///   - amountSats: Amount to reserve
    /// - Returns: A reservation if successful
    /// - Throws: If the amount would exceed the limit
    public func tryReserveSpending(peerPubkey: String, amountSats: Int64) throws -> SpendingReservationFfi {
        guard let manager = ffiManager else {
            throw SpendingLimitError.notInitialized
        }
        
        let reservation = try manager.tryReserveSpending(peerPubkey: peerPubkey, amountSats: amountSats)
        Logger.debug("Reserved \(amountSats) sats for \(peerPubkey), id: \(reservation.reservationId)", context: "SpendingLimitManager")
        
        return reservation
    }
    
    /// Commit a spending reservation (marks the spending as final)
    /// This operation is idempotent.
    public func commitSpending(reservationId: String) throws {
        guard let manager = ffiManager else {
            throw SpendingLimitError.notInitialized
        }
        
        try manager.commitSpending(reservationId: reservationId)
        Logger.info("Committed spending for reservation: \(reservationId)", context: "SpendingLimitManager")
    }
    
    /// Commit a spending reservation (marks the spending as final)
    public func commitSpending(_ reservation: SpendingReservationFfi) throws {
        try commitSpending(reservationId: reservation.reservationId)
    }
    
    /// Rollback a spending reservation (releases the reserved amount)
    /// This operation is idempotent.
    public func rollbackSpending(reservationId: String) throws {
        guard let manager = ffiManager else {
            throw SpendingLimitError.notInitialized
        }
        
        try manager.rollbackSpending(reservationId: reservationId)
        Logger.debug("Rolled back spending for reservation: \(reservationId)", context: "SpendingLimitManager")
    }
    
    /// Rollback a spending reservation (releases the reserved amount)
    public func rollbackSpending(_ reservation: SpendingReservationFfi) throws {
        try rollbackSpending(reservationId: reservation.reservationId)
    }
    
    /// Check if spending an amount would exceed the limit (non-blocking check)
    /// - Returns: Result containing whether the limit would be exceeded and remaining details
    public func wouldExceedLimit(peerPubkey: String, amountSats: Int64) throws -> SpendingCheckResultFfi {
        guard let manager = ffiManager else {
            throw SpendingLimitError.notInitialized
        }
        
        return try manager.wouldExceedSpendingLimit(peerPubkey: peerPubkey, amountSats: amountSats)
    }
    
    /// Get the number of active (in-flight) reservations
    public func activeReservationsCount() throws -> UInt32 {
        guard let manager = ffiManager else {
            throw SpendingLimitError.notInitialized
        }
        return try manager.activeReservationsCount()
    }
    
    // MARK: - Convenience
    
    /// Execute a payment with automatic reserve/commit/rollback
    /// - Parameters:
    ///   - peerPubkey: The peer's public key
    ///   - amountSats: Amount to spend
    ///   - payment: The async payment operation to execute
    /// - Returns: The result of the payment
    public func executeWithSpendingLimit<T>(
        peerPubkey: String,
        amountSats: Int64,
        payment: () async throws -> T
    ) async throws -> T {
        let reservation = try tryReserveSpending(peerPubkey: peerPubkey, amountSats: amountSats)
        
        do {
            let result = try await payment()
            try commitSpending(reservation)
            return result
        } catch {
            try? rollbackSpending(reservation)
            throw error
        }
    }
}

// MARK: - Errors

/// Spending limit errors
public enum SpendingLimitError: LocalizedError {
    case notInitialized
    case wouldExceedLimit(remaining: Int64)
    case reservationNotFound
    case invalidReservation
    case storageFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "SpendingLimitManager is not initialized"
        case .wouldExceedLimit(let remaining):
            return "Would exceed spending limit (\(remaining) sats remaining)"
        case .reservationNotFound:
            return "Spending reservation not found"
        case .invalidReservation:
            return "Invalid reservation"
        case .storageFailed(let reason):
            return "Storage operation failed: \(reason)"
        }
    }
}

// MARK: - FFI Type Extensions

public extension PeerSpendingLimitFfi {
    var usagePercent: Double {
        guard totalLimitSats > 0 else { return 0 }
        return Double(currentSpentSats) / Double(totalLimitSats) * 100
    }
}
