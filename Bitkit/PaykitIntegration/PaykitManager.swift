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
    
    /// The owner's public key (our pubkey for receiving payments)
    public var ownerPubkey: String? {
        PaykitKeyManager.shared.getCurrentPublicKeyZ32()
    }
    
    // MARK: - Initialization
    
    private init() {
        let ldkNetwork = Env.network
        if ldkNetwork == .bitcoin {
            self.bitcoinNetwork = .mainnet
            self.lightningNetwork = .mainnet
        } else if ldkNetwork == .testnet {
            self.bitcoinNetwork = .testnet
            self.lightningNetwork = .testnet
        } else if ldkNetwork == .regtest {
            self.bitcoinNetwork = .regtest
            self.lightningNetwork = .regtest
        } else {
            // signet or unknown
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
    
    // MARK: - Pubky-Ring Integration
    
    /// Request a session from Pubky-ring app.
    /// This opens Pubky-ring to authenticate and returns a session with credentials.
    public func requestPubkySession() async throws -> PubkySession {
        if PubkyRingBridge.shared.isPubkyRingInstalled {
            Logger.info("Requesting session from Pubky-ring", context: "PaykitManager")
            return try await PubkyRingBridge.shared.requestSession()
        }
        throw PaykitError.pubkyRingNotInstalled
    }
    
    /// Get a cached session or request a new one from Pubky-ring.
    public func getOrRequestSession(for pubkey: String? = nil) async throws -> PubkySession {
        // Check cache first
        if let pubkey = pubkey, let cached = PubkyRingBridge.shared.getCachedSession(for: pubkey) {
            return cached
        }
        
        // Request new session from Pubky-ring
        return try await requestPubkySession()
    }
    
    /// Check if Pubky-ring is installed and available
    public var isPubkyRingAvailable: Bool {
        PubkyRingBridge.shared.isPubkyRingInstalled
    }
    
    /// Set a session manually (from cross-device auth or manual import)
    public func setSession(_ session: PubkySession) {
        Logger.info("Session set for pubkey: \(session.pubkey)", context: "PaykitManager")
        // The session is already cached in PubkyRingBridge during import/callback
        // This method is provided for explicit session setting from UI
    }
    
    /// Check if a session is currently active
    public var hasActiveSession: Bool {
        if let pubkey = ownerPubkey {
            return PubkyRingBridge.shared.getCachedSession(for: pubkey) != nil
        }
        return false
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
    case pubkyRingNotInstalled
    case sessionRequired
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
        case .pubkyRingNotInstalled:
            return "Pubky-ring app is not installed. Please install Pubky-ring to use this feature."
        case .sessionRequired:
            return "A Pubky session is required for this operation"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}
