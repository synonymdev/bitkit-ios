//
//  Receipt.swift
//  Bitkit
//
//  Receipt model for payment history tracking.
//

import Foundation
import PaykitMobile

/// Payment status
public enum PaymentReceiptStatus: String, Codable {
    case pending = "pending"
    case completed = "completed"
    case failed = "failed"
    case refunded = "refunded"
}

/// Payment direction
public enum PaymentDirection: String, Codable {
    case sent = "sent"
    case received = "received"
}

/// A payment receipt (local model, different from PaykitMobile.Receipt)
public struct PaymentReceipt: Identifiable, Codable, Equatable, Hashable {
    public let id: String
    public let direction: PaymentDirection
    public let counterpartyKey: String
    public var counterpartyName: String?
    public let amountSats: UInt64
    public var status: PaymentReceiptStatus
    public let paymentMethod: String
    public let createdAt: Date
    public var completedAt: Date?
    public var memo: String?
    public var txId: String?
    public var proof: String?
    public var proofVerified: Bool = false
    public var proofVerifiedAt: Date?
    
    public init(
        direction: PaymentDirection,
        counterpartyKey: String,
        counterpartyName: String? = nil,
        amountSats: UInt64,
        paymentMethod: String,
        memo: String? = nil
    ) {
        self.id = UUID().uuidString
        self.direction = direction
        self.counterpartyKey = counterpartyKey
        self.counterpartyName = counterpartyName
        self.amountSats = amountSats
        self.status = .pending
        self.paymentMethod = paymentMethod
        self.createdAt = Date()
        self.completedAt = nil
        self.memo = memo
        self.txId = nil
        self.proof = nil
        self.proofVerified = false
        self.proofVerifiedAt = nil
    }
    
    init(
        id: String,
        direction: PaymentDirection,
        counterpartyKey: String,
        counterpartyName: String?,
        amountSats: UInt64,
        status: PaymentReceiptStatus,
        paymentMethod: String,
        createdAt: Date,
        completedAt: Date?,
        memo: String?,
        txId: String?,
        proof: String?,
        proofVerified: Bool,
        proofVerifiedAt: Date?
    ) {
        self.id = id
        self.direction = direction
        self.counterpartyKey = counterpartyKey
        self.counterpartyName = counterpartyName
        self.amountSats = amountSats
        self.status = status
        self.paymentMethod = paymentMethod
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.memo = memo
        self.txId = txId
        self.proof = proof
        self.proofVerified = proofVerified
        self.proofVerifiedAt = proofVerifiedAt
    }
    
    mutating func complete(txId: String? = nil) {
        self.status = .completed
        self.completedAt = Date()
        self.txId = txId
    }
    
    mutating func fail() {
        self.status = .failed
    }
    
    mutating func markProofVerified() {
        self.proofVerified = true
        self.proofVerifiedAt = Date()
    }
}

extension PaymentReceipt {
    var abbreviatedCounterparty: String {
        guard counterpartyKey.count > 16 else { return counterpartyKey }
        let prefix = counterpartyKey.prefix(8)
        let suffix = counterpartyKey.suffix(8)
        return "\(prefix)...\(suffix)"
    }
    
    var displayName: String {
        counterpartyName ?? abbreviatedCounterparty
    }
    
    var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let sign = direction == .sent ? "-" : "+"
        return "\(sign)\(formatter.string(from: NSNumber(value: amountSats)) ?? "\(amountSats)") sats"
    }
    
    static func fromFFI(
        _ ffiReceipt: Receipt,
        direction: PaymentDirection,
        counterpartyName: String? = nil
    ) -> PaymentReceipt {
        let counterpartyKey = direction == .sent ? ffiReceipt.payee : ffiReceipt.payer
        let amountSats = UInt64(ffiReceipt.amount ?? "0") ?? 0
        
        return PaymentReceipt(
            id: ffiReceipt.receiptId,
            direction: direction,
            counterpartyKey: counterpartyKey,
            counterpartyName: counterpartyName,
            amountSats: amountSats,
            status: .pending,
            paymentMethod: ffiReceipt.methodId,
            createdAt: Date(timeIntervalSince1970: Double(ffiReceipt.createdAt)),
            completedAt: nil,
            memo: nil,
            txId: nil,
            proof: nil,
            proofVerified: false,
            proofVerifiedAt: nil
        )
    }
}
