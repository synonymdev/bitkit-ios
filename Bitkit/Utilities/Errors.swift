import Foundation
import LDKNode

enum CustomServiceError: LocalizedError {
    case nodeNotSetup
    case nodeNotStarted
    case onchainWalletNotInitialized
    case mnemonicNotFound
    case nodeStillRunning
    case onchainWalletStillRunning
    case invalidNodeSigningMessage
    case regtestOnlyMethod
    case channelSizeExceedsMaximum
    case currencyRateUnavailable

    var errorDescription: String? {
        switch self {
        case .nodeNotSetup:
            return "Node is not setup"
        case .nodeNotStarted:
            return "Node is not started"
        case .onchainWalletNotInitialized:
            return "Onchain wallet not created"
        case .mnemonicNotFound:
            return "Mnemonic not found"
        case .nodeStillRunning:
            return "Node is still running"
        case .onchainWalletStillRunning:
            return "Onchain wallet is still running"
        case .invalidNodeSigningMessage:
            return "Invalid node signing message"
        case .regtestOnlyMethod:
            return "Method only available in regtest environment"
        case .channelSizeExceedsMaximum:
            return "Channel size exceeds maximum allowed size"
        case .currencyRateUnavailable:
            return "Currency rate unavailable"
        }
    }
}

enum KeychainError: LocalizedError {
    case failedToSave
    case failedToSaveAlreadyExists
    case failedToDelete
    case failedToLoad
    case keychainWipeNotAllowed

    var errorDescription: String? {
        switch self {
        case .failedToSave:
            return "Failed to save to keychain"
        case .failedToSaveAlreadyExists:
            return "Failed to save to keychain: item already exists"
        case .failedToDelete:
            return "Failed to delete from keychain"
        case .failedToLoad:
            return "Failed to load from keychain"
        case .keychainWipeNotAllowed:
            return "Keychain wipe not allowed"
        }
    }
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
        case .currencyRateUnavailable:
            message = "Currency rate unavailable"
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
        case let .InvalidSeedBytes(message: ldkMessage):
            message = "Invalid seed bytes"
            debugMessage = ldkMessage
        case let .InvalidSeedFile(message: ldkMessage):
            message = "Invalid seed file"
            debugMessage = ldkMessage
        case let .InvalidSystemTime(message: ldkMessage):
            message = "Invalid system time"
            debugMessage = ldkMessage
        case let .InvalidChannelMonitor(message: ldkMessage):
            message = "Invalid channel monitor"
            debugMessage = ldkMessage
        case let .InvalidListeningAddresses(message: ldkMessage):
            message = "Invalid listening addresses"
            debugMessage = ldkMessage
        case let .InvalidAnnouncementAddresses(message: ldkMessage):
            message = "Invalid announcement addresses"
            debugMessage = ldkMessage
        case let .InvalidNodeAlias(message: ldkMessage):
            message = "Invalid node alias"
            debugMessage = ldkMessage
        case let .RuntimeSetupFailed(message: ldkMessage):
            message = "Runtime setup failed"
            debugMessage = ldkMessage
        case let .ReadFailed(message: ldkMessage):
            message = "Read failed"
            debugMessage = ldkMessage
        case let .WriteFailed(message: ldkMessage):
            message = "Write failed"
            debugMessage = ldkMessage
        case let .StoragePathAccessFailed(message: ldkMessage):
            message = "Storage path access failed"
            debugMessage = ldkMessage
        case let .KvStoreSetupFailed(message: ldkMessage):
            message = "KV store setup failed"
            debugMessage = ldkMessage
        case let .WalletSetupFailed(message: ldkMessage):
            message = "Wallet setup failed"
            debugMessage = ldkMessage
        case let .LoggerSetupFailed(message: ldkMessage):
            message = "Logger setup failed"
            debugMessage = ldkMessage
        case let .NetworkMismatch(message: ldkMessage):
            message = "Network mismatch"
            debugMessage = ldkMessage
        case let .AsyncPaymentsConfigMismatch(message: ldkMessage):
            message = "Async payments config mismatch"
            debugMessage = ldkMessage
        }
    }

    private init(ldkError: NodeError) {
        switch ldkError as NodeError {
        case let .AlreadyRunning(message: ldkMessage):
            message = "Node is already running"
            debugMessage = ldkMessage
        case let .NotRunning(message: ldkMessage):
            message = "Node is not running"
            debugMessage = ldkMessage
        case let .OnchainTxCreationFailed(message: ldkMessage):
            message = "Failed to create onchain transaction"
            debugMessage = ldkMessage
        case let .ConnectionFailed(message: ldkMessage):
            message = "Failed to connect to node"
            debugMessage = ldkMessage
        case let .InvoiceCreationFailed(message: ldkMessage):
            message = "Failed to create invoice"
            debugMessage = ldkMessage
        case let .InvoiceRequestCreationFailed(message: ldkMessage):
            message = "Failed to create invoice request"
            debugMessage = ldkMessage
        case let .OfferCreationFailed(message: ldkMessage):
            message = "Failed to create offer"
            debugMessage = ldkMessage
        case let .RefundCreationFailed(message: ldkMessage):
            message = "Failed to create refund"
            debugMessage = ldkMessage
        case let .PaymentSendingFailed(message: ldkMessage):
            //            message = "Failed to send payment. \(ldkMessage)"
            message = ldkMessage
            debugMessage = ldkMessage
        case let .InvalidCustomTlvs(message: ldkMessage):
            message = "Invalid custom TLVs"
            debugMessage = ldkMessage
        case let .ProbeSendingFailed(message: ldkMessage):
            message = "Failed to send probe"
            debugMessage = ldkMessage
        case let .RouteNotFound(message: ldkMessage):
            message = "Failed to find a route for fee estimation"
            debugMessage = ldkMessage
        case let .ChannelCreationFailed(message: ldkMessage):
            message = "Failed to create channel"
            debugMessage = ldkMessage
        case let .ChannelClosingFailed(message: ldkMessage):
            message = "Failed to close channel"
            debugMessage = ldkMessage
        case let .ChannelSplicingFailed(message: ldkMessage):
            message = "Failed to splice channel"
            debugMessage = ldkMessage
        case let .ChannelConfigUpdateFailed(message: ldkMessage):
            message = "Failed to update channel config"
            debugMessage = ldkMessage
        case let .PersistenceFailed(message: ldkMessage):
            message = "Failed to persist data"
            debugMessage = ldkMessage
        case let .FeerateEstimationUpdateFailed(message: ldkMessage):
            message = "Failed to update feerate estimation"
            debugMessage = ldkMessage
        case let .FeerateEstimationUpdateTimeout(message: ldkMessage):
            message = "Failed to update feerate estimation due to timeout"
            debugMessage = ldkMessage
        case let .WalletOperationFailed(message: ldkMessage):
            message = "Failed to perform wallet operation"
            debugMessage = ldkMessage
        case let .WalletOperationTimeout(message: ldkMessage):
            message = "Failed to perform wallet operation due to timeout"
            debugMessage = ldkMessage
        case let .OnchainTxSigningFailed(message: ldkMessage):
            message = "Failed to sign onchain transaction"
            debugMessage = ldkMessage
        case let .TxSyncFailed(message: ldkMessage):
            message = "Failed to sync transaction"
            debugMessage = ldkMessage
        case let .TxSyncTimeout(message: ldkMessage):
            message = "Failed to sync transaction due to timeout"
            debugMessage = ldkMessage
        case let .GossipUpdateFailed(message: ldkMessage):
            message = "Failed to update gossip"
            debugMessage = ldkMessage
        case let .GossipUpdateTimeout(message: ldkMessage):
            message = "Failed to update gossip due to timeout"
            debugMessage = ldkMessage
        case let .LiquidityRequestFailed(message: ldkMessage):
            message = "Failed to request liquidity"
            debugMessage = ldkMessage
        case let .UriParameterParsingFailed(message: ldkMessage):
            message = "Failed to parse URI parameters"
            debugMessage = ldkMessage
        case let .InvalidAddress(message: ldkMessage):
            message = "Invalid address"
            debugMessage = ldkMessage
        case let .InvalidSocketAddress(message: ldkMessage):
            message = "Invalid socket address"
            debugMessage = ldkMessage
        case let .InvalidPublicKey(message: ldkMessage):
            message = "Invalid public key"
            debugMessage = ldkMessage
        case let .InvalidSecretKey(message: ldkMessage):
            message = "Invalid secret key"
            debugMessage = ldkMessage
        case let .InvalidOfferId(message: ldkMessage):
            message = "Invalid offer ID"
            debugMessage = ldkMessage
        case let .InvalidNodeId(message: ldkMessage):
            message = "Invalid node ID"
            debugMessage = ldkMessage
        case let .InvalidPaymentId(message: ldkMessage):
            message = "Invalid payment ID"
            debugMessage = ldkMessage
        case let .InvalidPaymentHash(message: ldkMessage):
            message = "Invalid payment hash"
            debugMessage = ldkMessage
        case let .InvalidPaymentPreimage(message: ldkMessage):
            message = "Invalid payment preimage"
            debugMessage = ldkMessage
        case let .InvalidPaymentSecret(message: ldkMessage):
            message = "Invalid payment secret"
            debugMessage = ldkMessage
        case let .InvalidAmount(message: ldkMessage):
            message = "Invalid amount"
            debugMessage = ldkMessage
        case let .InvalidInvoice(message: ldkMessage):
            message = "Invalid invoice"
            debugMessage = ldkMessage
        case let .InvalidOffer(message: ldkMessage):
            message = "Invalid offer"
            debugMessage = ldkMessage
        case let .InvalidRefund(message: ldkMessage):
            message = "Invalid refund"
            debugMessage = ldkMessage
        case let .InvalidChannelId(message: ldkMessage):
            message = "Invalid channel ID"
            debugMessage = ldkMessage
        case let .InvalidNetwork(message: ldkMessage):
            message = "Invalid network"
            debugMessage = ldkMessage
        case let .DuplicatePayment(message: ldkMessage):
            message = "Duplicate payment"
            debugMessage = ldkMessage
        case let .UnsupportedCurrency(message: ldkMessage):
            message = "Unsupported currency"
            debugMessage = ldkMessage
        case let .InsufficientFunds(message: ldkMessage):
            message = "Insufficient funds"
            debugMessage = ldkMessage
        case let .LiquiditySourceUnavailable(message: ldkMessage):
            message = "Liquidity source unavailable"
            debugMessage = ldkMessage
        case let .LiquidityFeeTooHigh(message: ldkMessage):
            message = "Liquidity fee too high"
            debugMessage = ldkMessage
        case let .InvalidBlindedPaths(message: ldkMessage):
            message = "Invalid blinded paths"
            debugMessage = ldkMessage
        case let .AsyncPaymentServicesDisabled(message: ldkMessage):
            message = "Async payment services disabled"
            debugMessage = ldkMessage
        case let .InvalidUri(message: ldkMessage):
            message = "Invalid URI"
            debugMessage = ldkMessage
        case let .InvalidQuantity(message: ldkMessage):
            message = "Invalid quantity"
            debugMessage = ldkMessage
        case let .InvalidNodeAlias(message: ldkMessage):
            message = "Invalid node alias"
            debugMessage = ldkMessage
        case let .InvalidCustomTlvs(message: ldkMessage):
            message = "Invalid custom TLVs"
            debugMessage = ldkMessage
        case let .InvalidDateTime(message: ldkMessage):
            message = "Invalid date time"
            debugMessage = ldkMessage
        case let .InvalidFeeRate(message: ldkMessage):
            message = "Invalid fee rate"
            debugMessage = ldkMessage
        case let .CannotRbfFundingTransaction(ldkMessage):
            message = "Cannot RBF funding transaction"
            debugMessage = ldkMessage
        case let .TransactionNotFound(ldkMessage):
            message = "Transaction not found"
            debugMessage = ldkMessage
        case let .TransactionAlreadyConfirmed(ldkMessage):
            message = "Transaction already confirmed"
            debugMessage = ldkMessage
        case let .NoSpendableOutputs(ldkMessage):
            message = "No spendable outputs"
            debugMessage = ldkMessage
        case let .CoinSelectionFailed(ldkMessage):
            message = "Coin selection failed"
            debugMessage = ldkMessage
        case let .InvalidMnemonic(ldkMessage):
            message = "Invalid mnemonic"
            debugMessage = ldkMessage
        case let .BackgroundSyncNotEnabled(ldkMessage):
            message = "Background sync not enabled"
            debugMessage = ldkMessage
        }
        Logger.error("\(message) [\(debugMessage ?? "")]", context: "ldk-node error")
    }
}
