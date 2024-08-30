//
//  ActivityItem.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import BitcoinDevKit
import LDKNode
import SwiftUI

enum ActivityType {
    case onchain
    case lightning
}

enum PaymentType {
    case sent
    case received
}

enum PaymentState {
    case pending
    case completed
    case failed
}

struct OnchainActivityItem: Hashable {
    var id: String
    var txType: PaymentType
    var txId: String
    var valueSats: UInt64
    var fee: UInt64
    var feeRate: Double
    var address: String
    var confirmed: Bool
    var timestamp: TimeInterval
    var isBoosted: Bool
    var isTransfer: Bool
    var exists: Bool
    var confirmTimestamp: TimeInterval?
    var channelId: String?
    var transferTxId: String?

    init(tx: CanonicalTx) {
        let transaction = tx.transaction

        self.id = transaction.txid()
        self.txId = transaction.txid()

        switch tx.chainPosition {
        case .confirmed(height: let height, timestamp: let timestamp):
            self.confirmed = true
            self.timestamp = TimeInterval(timestamp) // TODO: get first time in mempool
            self.confirmTimestamp = TimeInterval(timestamp)
        case .unconfirmed(timestamp: let timestamp):
            self.confirmed = false
            self.timestamp = TimeInterval(timestamp)
            self.confirmTimestamp = nil
        }

        // TODO: don't yet have the actual values from BDK yet
        self.txType = .received
        self.valueSats = 999
        self.fee = 9
        self.feeRate = 99
        self.address = "abc123"
        self.isBoosted = false
        self.isTransfer = false
        self.exists = true
        self.channelId = nil
        self.transferTxId = nil
    }
}

struct LightningActivityItem: Hashable {
    var id: String
    var activityType: ActivityType = .lightning
    var txType: PaymentType
    var status: PaymentState
    var valueSats: UInt64
    var fee: UInt64?
    var message: String
    var timestamp: TimeInterval
    var preimage: String?

    init(payment: PaymentDetails) {
        switch payment.kind {
        case .bolt11(hash: let hash, preimage: let preimage, _):
            self.id = hash
            self.preimage = preimage
        case .spontaneous(let hash, let preimage):
            self.id = hash
            self.preimage = preimage
        case .onchain:
            break
        // TODO: skip these as they're added from BDK
        case .bolt11Jit(hash: _, preimage: _, secret: _, lspFeeLimits: _):
            break
        case .bolt12Offer(hash: _, preimage: _, secret: _, offerId: _):
            break
        case .bolt12Refund(hash: _, preimage: _, secret: _):
            break
        }

        self.id = payment.id
        self.txType = payment.direction == .outbound ? .sent : .received

        switch payment.status {
        case .pending:
            self.status = .pending
        case .succeeded:
            self.status = .completed
        case .failed:
            self.status = .failed
        }

        self.valueSats = (payment.amountMsat ?? 0) / 1000
        self.fee = 0 // TODO: find this

        self.message = "TODO: find note" //
        self.timestamp = TimeInterval(payment.latestUpdateTimestamp)
    }
}

enum ActivityItem: Hashable {
    case onchain(OnchainActivityItem)
    case lightning(LightningActivityItem)
}
