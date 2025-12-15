//
//  Contact.swift
//  Bitkit
//
//  Contact model for managing payment recipients in Paykit.
//

import Foundation

/// A payment contact (recipient)
public struct Contact: Identifiable, Codable, Equatable {
    /// Unique identifier (derived from public key)
    let id: String
    /// Public key in z-base32 format
    let publicKeyZ32: String
    /// Display name
    var name: String
    /// Optional notes
    var notes: String?
    /// When the contact was added
    let createdAt: Date
    /// Last payment to this contact (if any)
    var lastPaymentAt: Date?
    /// Total number of payments to this contact
    var paymentCount: Int
    
    init(publicKeyZ32: String, name: String, notes: String? = nil) {
        self.id = publicKeyZ32
        self.publicKeyZ32 = publicKeyZ32
        self.name = name
        self.notes = notes
        self.createdAt = Date()
        self.lastPaymentAt = nil
        self.paymentCount = 0
    }
    
    /// Update after making a payment
    mutating func recordPayment() {
        lastPaymentAt = Date()
        paymentCount += 1
    }
}

extension Contact {
    /// Abbreviated public key for display (first and last 8 chars)
    var abbreviatedKey: String {
        guard publicKeyZ32.count > 16 else { return publicKeyZ32 }
        let prefix = publicKeyZ32.prefix(8)
        let suffix = publicKeyZ32.suffix(8)
        return "\(prefix)...\(suffix)"
    }
}
