import Foundation
import LDKNode

enum CustomServiceError: LocalizedError {
    case nodeNotSetup
    case nodeNotStarted
    case onchainWalletNotInitialized
    case mnemonicNotFound
    case vssAuthRequired
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
        case .vssAuthRequired:
            return "VSS requires LNURL-auth"
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

enum PaymentTimeoutError: Error {
    case timedOut
}

/// Translates LDK and BDK error messages into translated messages that can be displayed to end users
struct AppError: LocalizedError {
    static let genericMessage = "App Error"

    let message: String
    let debugMessage: String?
    let paymentFailureReason: PaymentFailureReason?
    /// The original error this was wrapped from, when known. Preserved so callers can unwrap and
    /// inspect the underlying error (e.g. `isTrezorUserCancellation()`) after it has been boxed by
    /// `ServiceQueue` into a generic `AppError`.
    let underlyingError: Error?

    var errorDescription: String? {
        return t(message)
    }

    var isGeneric: Bool {
        return message == Self.genericMessage
    }

    /// Pass any LDK or BDK error to get a translated error message
    /// - Parameter error: any error
    init(error: Error) {
        if let appError = error as? AppError {
            self = appError
            return
        }

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

        self.init(message: Self.genericMessage, debugMessage: error.localizedDescription, underlyingError: error)
    }

    init(message: String, debugMessage: String?, underlyingError: Error? = nil, paymentFailureReason: PaymentFailureReason? = nil) {
        self.message = message
        self.debugMessage = debugMessage
        self.underlyingError = underlyingError
        self.paymentFailureReason = paymentFailureReason
    }

    init(paymentFailureReason reason: PaymentFailureReason?) {
        underlyingError = nil
        debugMessage = reason.map { String(describing: $0) } ?? "Unknown payment failure reason"
        message = PaymentFailureReason.userMessageKey(for: reason)
        paymentFailureReason = reason
    }

    init(serviceError: CustomServiceError) {
        underlyingError = serviceError
        paymentFailureReason = nil
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
        case .vssAuthRequired:
            message = "VSS requires LNURL-auth"
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
        underlyingError = ldkBuildError
        paymentFailureReason = nil
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
        case let .DangerousValue(message: ldkMessage):
            message = "Dangerous value"
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
        underlyingError = ldkError
        paymentFailureReason = nil
        debugMessage = String(describing: ldkError)
        switch ldkError as NodeError {
        case .AlreadyRunning:
            message = "Node is already running"
        case .NotRunning:
            message = "Node is not running"
        case .OnchainTxCreationFailed:
            message = "Failed to create onchain transaction"
        case .OnchainTxBroadcastRejected:
            message = "Onchain transaction was rejected"
        case .OnchainTxBroadcastFailed:
            message = "Failed to broadcast onchain transaction"
        case .OnchainTxBroadcastTimeout:
            message = "Onchain transaction broadcast timed out"
        case .OnchainTxBroadcastNotDispatched:
            message = "Onchain transaction was not dispatched"
        case .OnchainWalletAccountNotRegistered:
            message = "Onchain wallet account is not registered"
        case .ConnectionFailed:
            message = "Failed to connect to node"
        case .InvoiceCreationFailed:
            message = "Failed to create invoice"
        case .InvoiceRequestCreationFailed:
            message = "Failed to create invoice request"
        case .OfferCreationFailed:
            message = "Failed to create offer"
        case .RefundCreationFailed:
            message = "Failed to create refund"
        case .PaymentSendingFailed:
            message = "Failed to send payment"
        case .ProbeSendingFailed:
            message = "Failed to send probe"
        case .RouteNotFound:
            message = "Failed to find a route for fee estimation"
        case .ChannelCreationFailed:
            message = "Failed to create channel"
        case .ChannelClosingFailed:
            message = "Failed to close channel"
        case .ChannelSplicingFailed:
            message = "Failed to splice channel"
        case .ChannelConfigUpdateFailed:
            message = "Failed to update channel config"
        case .PersistenceFailed:
            message = "Failed to persist data"
        case .FeerateEstimationUpdateFailed:
            message = "Failed to update feerate estimation"
        case .FeerateEstimationUpdateTimeout:
            message = "Failed to update feerate estimation due to timeout"
        case .WalletOperationFailed:
            message = "Failed to perform wallet operation"
        case .WalletOperationTimeout:
            message = "Failed to perform wallet operation due to timeout"
        case .OnchainTxSigningFailed:
            message = "Failed to sign onchain transaction"
        case .TxSyncFailed:
            message = "Failed to sync transaction"
        case .TxSyncTimeout:
            message = "Failed to sync transaction due to timeout"
        case .GossipUpdateFailed:
            message = "Failed to update gossip"
        case .GossipUpdateTimeout:
            message = "Failed to update gossip due to timeout"
        case .LiquidityRequestFailed:
            message = "Failed to request liquidity"
        case .UriParameterParsingFailed:
            message = "Failed to parse URI parameters"
        case .InvalidAddress:
            message = "Invalid address"
        case .InvalidSocketAddress:
            message = "Invalid socket address"
        case .InvalidPublicKey:
            message = "Invalid public key"
        case .InvalidSecretKey:
            message = "Invalid secret key"
        case .InvalidOfferId:
            message = "Invalid offer ID"
        case .InvalidNodeId:
            message = "Invalid node ID"
        case .InvalidPaymentId:
            message = "Invalid payment ID"
        case .InvalidPaymentHash:
            message = "Invalid payment hash"
        case .InvalidPaymentPreimage:
            message = "Invalid payment preimage"
        case .InvalidPaymentSecret:
            message = "Invalid payment secret"
        case .InvalidAmount:
            message = "Invalid amount"
        case .InvalidInvoice:
            message = "Invalid invoice"
        case .InvalidOffer:
            message = "Invalid offer"
        case .InvalidRefund:
            message = "Invalid refund"
        case .InvalidChannelId:
            message = "Invalid channel ID"
        case .InvalidNetwork:
            message = "Invalid network"
        case .DuplicatePayment:
            message = "Duplicate payment"
        case .UnsupportedCurrency:
            message = "Unsupported currency"
        case .InsufficientFunds:
            message = "Insufficient funds"
        case .LiquiditySourceUnavailable:
            message = "Liquidity source unavailable"
        case .LiquidityFeeTooHigh:
            message = "Liquidity fee too high"
        case .InvalidBlindedPaths:
            message = "Invalid blinded paths"
        case .AsyncPaymentServicesDisabled:
            message = "Async payment services disabled"
        case .InvalidUri:
            message = "Invalid URI"
        case .InvalidQuantity:
            message = "Invalid quantity"
        case .InvalidNodeAlias:
            message = "Invalid node alias"
        case .InvalidCustomTlvs:
            message = "Invalid custom TLVs"
        case .InvalidDateTime:
            message = "Invalid date time"
        case .InvalidFeeRate:
            message = "Invalid fee rate"
        case .CannotRbfFundingTransaction:
            message = "Cannot RBF funding transaction"
        case .TransactionNotFound:
            message = "Transaction not found"
        case .TransactionAlreadyConfirmed:
            message = "Transaction already confirmed"
        case .NoSpendableOutputs:
            message = "No spendable outputs"
        case .CoinSelectionFailed:
            message = "Coin selection failed"
        case .InvalidMnemonic:
            message = "Invalid mnemonic"
        case .BackgroundSyncNotEnabled:
            message = "Background sync not enabled"
        case .AddressTypeAlreadyMonitored:
            message = "Address type already monitored"
        case .AddressTypeIsPrimary:
            message = "Address type is primary"
        case .AddressTypeNotMonitored:
            message = "Address type not monitored"
        case .InvalidSeedBytes:
            message = "Invalid seed bytes"
        }
        Logger.error("\(message) [\(debugMessage ?? "")]", context: "ldk-node error")
    }
}
