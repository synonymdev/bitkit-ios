//
//  Errors.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/04.
//

import Foundation
import LDKNode
import BitcoinDevKit

/// Translates LDK and BDK error messages into translated messages that can be displayed to end users
struct AppError: LocalizedError {
    let message: String
    let debugMessage: String?
    
    var errorDescription: String? {
        return NSLocalizedString(message, comment: "")
    }
    
    init(error: Error) {
        if let ldkError = error as? NodeError {
            self.init(ldkError: ldkError)
            return
        } 
        
        if let bdkError = error as? BdkError {
            self.init(bdkError: bdkError)
            return
        }
        
        self.init(message: "Unknown error", debugMessage: error.localizedDescription)
    }
    
    init(message: String, debugMessage: String?) {
        self.message = message
        self.debugMessage = debugMessage
    }
    
    private init(bdkError: BdkError) {
        message = "Bdk error"
        debugMessage = bdkError.localizedDescription
        //TODO support all message types in switch case
//        switch bdkError as BdkError {
//        case .Bip32(message: let bdkMessage):
//            message = "BIP32 error"
//            debugMessage = bdkMessage
//        }
    }
    
    private init(ldkError: NodeError) {
        switch ldkError as NodeError {
        case .AlreadyRunning(message: let ldkMessage):
            message = "Node is already running"
            debugMessage = ldkMessage
            break;
        case .NotRunning(message: let ldkMessage):
            message = "Node is not running"
            debugMessage = message
        case .OnchainTxCreationFailed(message: let ldkMessage):
            message = "Failed to create onchain transaction"
            debugMessage = message
        case .ConnectionFailed(message: let ldkMessage):
            message = "Failed to connect to node"
            debugMessage = message
        case .InvoiceCreationFailed(message: let ldkMessage):
            message = "Failed to create invoice"
            debugMessage = message
        case .InvoiceRequestCreationFailed(message: let ldkMessage):
            message = "Failed to create invoice request"
            debugMessage = message
        case .OfferCreationFailed(message: let ldkMessage):
            message = "Failed to create offer"
            debugMessage = message
        case .RefundCreationFailed(message: let ldkMessage):
            message = "Failed to create refund"
            debugMessage = message
        case .PaymentSendingFailed(message: let ldkMessage):
            message = "Failed to send payment"
            debugMessage = message
        case .ProbeSendingFailed(message: let ldkMessage):
            message = "Failed to send probe"
            debugMessage = message
        case .ChannelCreationFailed(message: let ldkMessage):
            message = "Failed to create channel"
            debugMessage = message
        case .ChannelClosingFailed(message: let ldkMessage):
            message = "Failed to close channel"
            debugMessage = message
        case .ChannelConfigUpdateFailed(message: let ldkMessage):
            message = "Failed to update channel config"
            debugMessage = message
        case .PersistenceFailed(message: let ldkMessage):
            message = "Failed to persist data"
            debugMessage = message
        case .FeerateEstimationUpdateFailed(message: let ldkMessage):
            message = "Failed to update feerate estimation"
            debugMessage = message
        case .FeerateEstimationUpdateTimeout(message: let ldkMessage):
            message = "Failed to update feerate estimation due to timeout"
            debugMessage = message
        case .WalletOperationFailed(message: let ldkMessage):
            message = "Failed to perform wallet operation"
            debugMessage = message
        case .WalletOperationTimeout(message: let ldkMessage):
            message = "Failed to perform wallet operation due to timeout"
            debugMessage = message
        case .OnchainTxSigningFailed(message: let ldkMessage):
            message = "Failed to sign onchain transaction"
            debugMessage = message
        case .MessageSigningFailed(message: let ldkMessage):
            message = "Failed to sign message"
            debugMessage = message
        case .TxSyncFailed(message: let ldkMessage):
            message = "Failed to sync transaction"
            debugMessage = message
        case .TxSyncTimeout(message: let ldkMessage):
            message = "Failed to sync transaction due to timeout"
            debugMessage = message
        case .GossipUpdateFailed(message: let ldkMessage):
            message = "Failed to update gossip"
            debugMessage = message
        case .GossipUpdateTimeout(message: let ldkMessage):
            message = "Failed to update gossip due to timeout"
            debugMessage = message
        case .LiquidityRequestFailed(message: let ldkMessage):
            message = "Failed to request liquidity"
            debugMessage = message
        case .InvalidAddress(message: let ldkMessage):
            message = "Invalid address"
            debugMessage = message
        case .InvalidSocketAddress(message: let ldkMessage):
            message = "Invalid socket address"
            debugMessage = message
        case .InvalidPublicKey(message: let ldkMessage):
            message = "Invalid public key"
            debugMessage = message
        case .InvalidSecretKey(message: let ldkMessage):
            message = "Invalid secret key"
            debugMessage = message
        case .InvalidOfferId(message: let ldkMessage):
            message = "Invalid offer ID"
            debugMessage = message
        case .InvalidNodeId(message: let ldkMessage):
            message = "Invalid node ID"
            debugMessage = message
        case .InvalidPaymentId(message: let ldkMessage):
            message = "Invalid payment ID"
            debugMessage = message
        case .InvalidPaymentHash(message: let ldkMessage):
            message = "Invalid payment hash"
            debugMessage = message
        case .InvalidPaymentPreimage(message: let ldkMessage):
            message = "Invalid payment preimage"
            debugMessage = message
        case .InvalidPaymentSecret(message: let ldkMessage):
            message = "Invalid payment secret"
            debugMessage = message
        case .InvalidAmount(message: let ldkMessage):
            message = "Invalid amount"
            debugMessage = message
        case .InvalidInvoice(message: let ldkMessage):
            message = "Invalid invoice"
            debugMessage = message
        case .InvalidOffer(message: let ldkMessage):
            message = "Invalid offer"
            debugMessage = message
        case .InvalidRefund(message: let ldkMessage):
            message = "Invalid refund"
            debugMessage = message
        case .InvalidChannelId(message: let ldkMessage):
            message = "Invalid channel ID"
            debugMessage = message
        case .InvalidNetwork(message: let ldkMessage):
            message = "Invalid network"
            debugMessage = message
        case .DuplicatePayment(message: let ldkMessage):
            message = "Duplicate payment"
            debugMessage = message
        case .UnsupportedCurrency(message: let ldkMessage):
            message = "Unsupported currency"
            debugMessage = message
        case .InsufficientFunds(message: let ldkMessage):
            message = "Insufficient funds"
            debugMessage = message
        case .LiquiditySourceUnavailable(message: let ldkMessage):
            message = "Liquidity source unavailable"
            debugMessage = message
        case .LiquidityFeeTooHigh(message: let ldkMessage):
            message = "Liquidity fee too high"
            debugMessage = message
        }
    }
}
