// PaykitManager.swift
// Bitkit iOS - Paykit Integration
//
// Manages PaykitClient lifecycle and executor registration.

import Foundation
import LDKNode
// PaykitMobile types are available from FFI/PaykitMobile.swift

// MARK: - PaykitManager

/// Manages the Paykit client and executor registration for Bitkit integration.
public final class PaykitManager {
    
    // MARK: - Singleton
    
    public static let shared = PaykitManager()
    
    // MARK: - Properties
    
    public private(set) var client: PaykitClient?
    private var bitcoinExecutor: BitkitBitcoinExecutor?
    private var lightningExecutor: BitkitLightningExecutor?
    
    public private(set) var isInitialized: Bool = false
    public private(set) var hasExecutors: Bool = false
    
    public let bitcoinNetwork: BitcoinNetworkConfig
    public let lightningNetwork: LightningNetworkConfig
    
    // MARK: - Initialization
    
    private init() {
        let ldkNetwork = Env.network
        switch ldkNetwork {
        case .bitcoin:
            self.bitcoinNetwork = .mainnet
            self.lightningNetwork = .mainnet
        case .testnet:
            self.bitcoinNetwork = .testnet
            self.lightningNetwork = .testnet
        case .regtest:
            self.bitcoinNetwork = .regtest
            self.lightningNetwork = .regtest
        case .signet:
            self.bitcoinNetwork = .testnet
            self.lightningNetwork = .testnet
        @unknown default:
            self.bitcoinNetwork = .testnet
            self.lightningNetwork = .testnet
        }
    }
    
    // MARK: - Public Methods
    
    /// Initialize the Paykit client with network configuration.
    public func initialize() throws {
        guard !isInitialized else {
            Logger.debug("PaykitManager already initialized", context: "PaykitManager")
            return
        }
        
        Logger.info("Initializing PaykitManager with network: \(bitcoinNetwork)", context: "PaykitManager")
        
        client = try PaykitClient.newWithNetwork(
            bitcoinNetwork: bitcoinNetwork.toFfi(),
            lightningNetwork: lightningNetwork.toFfi()
        )
        
        isInitialized = true
        Logger.info("PaykitManager initialized successfully", context: "PaykitManager")
    }
    
    /// Register Bitcoin and Lightning executors with the Paykit client.
    public func registerExecutors() throws {
        guard isInitialized else {
            throw PaykitError.notInitialized
        }
        
        guard !hasExecutors else {
            Logger.debug("Executors already registered", context: "PaykitManager")
            return
        }
        
        Logger.info("Registering Paykit executors", context: "PaykitManager")
        
        bitcoinExecutor = BitkitBitcoinExecutor()
        lightningExecutor = BitkitLightningExecutor()
        
        guard let client = client else {
            throw PaykitError.notInitialized
        }
        try client.registerBitcoinExecutor(executor: bitcoinExecutor!)
        try client.registerLightningExecutor(executor: lightningExecutor!)
        
        hasExecutors = true
        Logger.info("Paykit executors registered successfully", context: "PaykitManager")
    }
    
    /// Reset the manager state
    public func reset() {
        client = nil
        bitcoinExecutor = nil
        lightningExecutor = nil
        isInitialized = false
        hasExecutors = false
        Logger.info("PaykitManager reset", context: "PaykitManager")
    }
}

// MARK: - Network Configuration

public enum BitcoinNetworkConfig: String {
    case mainnet, testnet, regtest
    
    func toFfi() -> BitcoinNetworkFfi {
        switch self {
        case .mainnet:
            return .mainnet
        case .testnet:
            return .testnet
        case .regtest:
            return .regtest
        }
    }
}

public enum LightningNetworkConfig: String {
    case mainnet, testnet, regtest
    
    func toFfi() -> LightningNetworkFfi {
        switch self {
        case .mainnet:
            return .mainnet
        case .testnet:
            return .testnet
        case .regtest:
            return .regtest
        }
    }
}

// MARK: - Paykit Errors

public enum PaykitError: LocalizedError {
    case notInitialized
    case executorRegistrationFailed(String)
    case paymentFailed(String)
    case timeout
    case unknown(String)
    
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "PaykitManager has not been initialized"
        case .executorRegistrationFailed(let message):
            return "Failed to register executor: \(message)"
        case .paymentFailed(let message):
            return "Payment failed: \(message)"
        case .timeout:
            return "Operation timed out"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}
