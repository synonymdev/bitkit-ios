//
//  Errors.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/04.
//

import Foundation
import LDKNode

enum CustomServiceError: Error {
    case nodeNotSetup
    case nodeNotStarted
    case onchainWalletNotInitialized
    case ldkNodeSqliteAlreadyExists
    case ldkToLdkNodeMigration
    case mnemonicNotFound
    case nodeStillRunning
    case onchainWalletStillRunning
    case invalidNodeSigningMessage
    case regtestOnlyMethod
    case channelSizeExceedsMaximum
}

enum KeychainError: Error {
    case failedToSave
    case failedToSaveAlreadyExists
    case failedToDelete
    case failedToLoad
    case keychainWipeNotAllowed
}

enum BlocktankError_deprecated: Error {
    case missingResponse
    case invalidResponse
    case invalidJson
    case missingDeviceToken
}

/// Translates LDK and BDK error messages into translated messages that can be displayed to end users
struct AppError: LocalizedError {
    let message: String
    let debugMessage: String?

    var errorDescription: String? {
        return NSLocalizedString(message, comment: "")
    }

    /// Pass any LDK or BDK error to get a translated error message
    /// - Parameter error: any error
    init(error: Error) {
        if let ldkBuildError = error as? BuildError {
            self.init(ldkBuildError: ldkBuildError)
            return
        }

        if let ldkError = error as? NodeError {
            self.init(ldkError: ldkError)
            return
        }

        // TODO: support all message types in switch case
        // CalculateFeeError
        // CannotConnectError
        // DescriptorError
        // EsploraError
        // PersistenceError

        self.init(message: "App Error", debugMessage: error.localizedDescription)
    }

    init(message: String, debugMessage: String?) {
        self.message = message
        self.debugMessage = debugMessage
    }

    init(serviceError: CustomServiceError) {
        switch serviceError {
        case .nodeNotSetup:
            message = "Node is not setup"
            debugMessage = nil
        case .nodeNotStarted:
            message = "Node is not started"
            debugMessage = nil
        case .onchainWalletNotInitialized:
            message = "Onchain wallet not created"
            debugMessage = nil
        case .ldkNodeSqliteAlreadyExists:
            message = "LDK-node SQLite file already exists"
            debugMessage = nil
        case .ldkToLdkNodeMigration:
            message = "LDK to LDK-node migration issue"
            debugMessage = nil
        case .mnemonicNotFound:
            message = "Mnemonic not found"
            debugMessage = nil
        case .nodeStillRunning:
            message = "Node is still running"
            debugMessage = nil
        case .onchainWalletStillRunning:
            message = "Onchain wallet is still running"
            debugMessage = nil
        case .invalidNodeSigningMessage:
            message = "Invalid node signing message"
            debugMessage = nil
        case .regtestOnlyMethod:
            message = "Method only available in regtest environment"
            debugMessage = nil
        case .channelSizeExceedsMaximum:
            message = "Channel size exceeds maximum allowed size"
            debugMessage = nil
        }

        Logger.error("\(message) [\(debugMessage ?? "")]", context: "service error")
    }

    //    private init(bdkError: Error) {
    //        message = "Onchain wallet error"
    //        debugMessage = bdkError.localizedDescription
    //
    //
    //
    //        Logger.error("\(message) [\(debugMessage ?? "")]", context: "BdkError")
    //    }

    private init(ldkBuildError: BuildError) {
        switch ldkBuildError as BuildError {
        case .InvalidChannelMonitor(message: let ldkMessage):
            message = "Invalid channel monitor"
            debugMessage = ldkMessage
        case .InvalidSeedBytes(message: let ldkMessage):
            message = "Invalid seed bytes"
            debugMessage = ldkMessage
        case .InvalidSeedFile(message: let ldkMessage):
            message = "Invalid seed file"
            debugMessage = ldkMessage
        case .InvalidSystemTime(message: let ldkMessage):
            message = "Invalid system time"
            debugMessage = ldkMessage
        case .InvalidListeningAddresses(message: let ldkMessage):
            message = "Invalid listening addresses"
            debugMessage = ldkMessage
        case .ReadFailed(message: let ldkMessage):
            message = "Read failed"
            debugMessage = ldkMessage
        case .WriteFailed(message: let ldkMessage):
            message = "Write failed"
            debugMessage = ldkMessage
        case .StoragePathAccessFailed(message: let ldkMessage):
            message = "Storage path access failed"
            debugMessage = ldkMessage
        case .KvStoreSetupFailed(message: let ldkMessage):
            message = "KV store setup failed"
            debugMessage = ldkMessage
        case .WalletSetupFailed(message: let ldkMessage):
            message = "Wallet setup failed"
            debugMessage = ldkMessage
        case .LoggerSetupFailed(message: let ldkMessage):
            message = "Logger setup failed"
            debugMessage = ldkMessage
        case .InvalidNodeAlias(message: let ldkMessage):
            message = ldkMessage
            debugMessage = nil
        }
    }

    private init(ldkError: NodeError) {
        switch ldkError as NodeError {
        case .AlreadyRunning(message: let ldkMessage):
            message = "Node is already running"
            debugMessage = ldkMessage
        case .NotRunning(message: let ldkMessage):
            message = "Node is not running"
            debugMessage = ldkMessage
        case .OnchainTxCreationFailed(message: let ldkMessage):
            message = "Failed to create onchain transaction"
            debugMessage = ldkMessage
        case .ConnectionFailed(message: let ldkMessage):
            message = "Failed to connect to node"
            debugMessage = ldkMessage
        case .InvoiceCreationFailed(message: let ldkMessage):
            message = "Failed to create invoice"
            debugMessage = ldkMessage
        case .InvoiceRequestCreationFailed(message: let ldkMessage):
            message = "Failed to create invoice request"
            debugMessage = ldkMessage
        case .OfferCreationFailed(message: let ldkMessage):
            message = "Failed to create offer"
            debugMessage = ldkMessage
        case .RefundCreationFailed(message: let ldkMessage):
            message = "Failed to create refund"
            debugMessage = ldkMessage
        case .PaymentSendingFailed(message: let ldkMessage):
            //            message = "Failed to send payment. \(ldkMessage)"
            message = ldkMessage
            debugMessage = ldkMessage
        case .ProbeSendingFailed(message: let ldkMessage):
            message = "Failed to send probe"
            debugMessage = ldkMessage
        case .ChannelCreationFailed(message: let ldkMessage):
            message = "Failed to create channel"
            debugMessage = ldkMessage
        case .ChannelClosingFailed(message: let ldkMessage):
            message = "Failed to close channel"
            debugMessage = ldkMessage
        case .ChannelConfigUpdateFailed(message: let ldkMessage):
            message = "Failed to update channel config"
            debugMessage = ldkMessage
        case .PersistenceFailed(message: let ldkMessage):
            message = "Failed to persist data"
            debugMessage = ldkMessage
        case .FeerateEstimationUpdateFailed(message: let ldkMessage):
            message = "Failed to update feerate estimation"
            debugMessage = ldkMessage
        case .FeerateEstimationUpdateTimeout(message: let ldkMessage):
            message = "Failed to update feerate estimation due to timeout"
            debugMessage = ldkMessage
        case .WalletOperationFailed(message: let ldkMessage):
            message = "Failed to perform wallet operation"
            debugMessage = ldkMessage
        case .WalletOperationTimeout(message: let ldkMessage):
            message = "Failed to perform wallet operation due to timeout"
            debugMessage = ldkMessage
        case .OnchainTxSigningFailed(message: let ldkMessage):
            message = "Failed to sign onchain transaction"
            debugMessage = ldkMessage
        case .TxSyncFailed(message: let ldkMessage):
            message = "Failed to sync transaction"
            debugMessage = ldkMessage
        case .TxSyncTimeout(message: let ldkMessage):
            message = "Failed to sync transaction due to timeout"
            debugMessage = ldkMessage
        case .GossipUpdateFailed(message: let ldkMessage):
            message = "Failed to update gossip"
            debugMessage = ldkMessage
        case .GossipUpdateTimeout(message: let ldkMessage):
            message = "Failed to update gossip due to timeout"
            debugMessage = ldkMessage
        case .LiquidityRequestFailed(message: let ldkMessage):
            message = "Failed to request liquidity"
            debugMessage = ldkMessage
        case .InvalidAddress(message: let ldkMessage):
            message = "Invalid address"
            debugMessage = ldkMessage
        case .InvalidSocketAddress(message: let ldkMessage):
            message = "Invalid socket address"
            debugMessage = ldkMessage
        case .InvalidPublicKey(message: let ldkMessage):
            message = "Invalid public key"
            debugMessage = ldkMessage
        case .InvalidSecretKey(message: let ldkMessage):
            message = "Invalid secret key"
            debugMessage = ldkMessage
        case .InvalidOfferId(message: let ldkMessage):
            message = "Invalid offer ID"
            debugMessage = ldkMessage
        case .InvalidNodeId(message: let ldkMessage):
            message = "Invalid node ID"
            debugMessage = ldkMessage
        case .InvalidPaymentId(message: let ldkMessage):
            message = "Invalid payment ID"
            debugMessage = ldkMessage
        case .InvalidPaymentHash(message: let ldkMessage):
            message = "Invalid payment hash"
            debugMessage = ldkMessage
        case .InvalidPaymentPreimage(message: let ldkMessage):
            message = "Invalid payment preimage"
            debugMessage = ldkMessage
        case .InvalidPaymentSecret(message: let ldkMessage):
            message = "Invalid payment secret"
            debugMessage = ldkMessage
        case .InvalidAmount(message: let ldkMessage):
            message = "Invalid amount"
            debugMessage = ldkMessage
        case .InvalidInvoice(message: let ldkMessage):
            message = "Invalid invoice"
            debugMessage = ldkMessage
        case .InvalidOffer(message: let ldkMessage):
            message = "Invalid offer"
            debugMessage = ldkMessage
        case .InvalidRefund(message: let ldkMessage):
            message = "Invalid refund"
            debugMessage = ldkMessage
        case .InvalidChannelId(message: let ldkMessage):
            message = "Invalid channel ID"
            debugMessage = ldkMessage
        case .InvalidNetwork(message: let ldkMessage):
            message = "Invalid network"
            debugMessage = ldkMessage
        case .DuplicatePayment(message: let ldkMessage):
            message = "Duplicate payment"
            debugMessage = ldkMessage
        case .UnsupportedCurrency(message: let ldkMessage):
            message = "Unsupported currency"
            debugMessage = ldkMessage
        case .InsufficientFunds(message: let ldkMessage):
            message = "Insufficient funds"
            debugMessage = ldkMessage
        case .LiquiditySourceUnavailable(message: let ldkMessage):
            message = "Liquidity source unavailable"
            debugMessage = ldkMessage
        case .LiquidityFeeTooHigh(message: let ldkMessage):
            message = "Liquidity fee too high"
            debugMessage = ldkMessage
        case .UriParameterParsingFailed(message: let ldkMessage):
            message = "Uri parameter parsing failed"
            debugMessage = ldkMessage
        case .InvalidUri(message: let ldkMessage):
            message = "Invalid URI"
            debugMessage = ldkMessage
        case .InvalidQuantity(message: let ldkMessage):
            message = "Invalid quantity"
            debugMessage = ldkMessage
        case .InvalidNodeAlias(message: let ldkMessage):
            message = "Invalid node alias"
            debugMessage = ldkMessage
        }

        Logger.error("\(message) [\(debugMessage ?? "")]", context: "ldk-node error")
    }
}
