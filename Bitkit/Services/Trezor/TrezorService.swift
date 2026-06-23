import BitkitCore
import Foundation

/// Service layer wrapper for Trezor FFI functions
/// All operations run on ServiceQueue.background(.core) to ensure thread safety
class TrezorService {
    static let shared = TrezorService()

    private var callbacksRegistered = false
    private let callbackLock = NSLock()

    private init() {}

    // MARK: - Callback Registration

    /// Ensures transport callback is registered before any Trezor operations
    private func ensureCallbacksRegistered() {
        callbackLock.lock()
        defer { callbackLock.unlock() }

        guard !callbacksRegistered else { return }

        trezorSetTransportCallback(callback: TrezorTransport.shared)
        trezorSetUiCallback(callback: TrezorUiHandler.shared)
        callbacksRegistered = true

        Logger.info("Trezor callbacks registered", context: "TrezorService")
    }

    // MARK: - Initialization

    /// Initialize the Trezor manager
    /// - Parameter credentialPath: Optional path for credential storage (nil uses app default)
    func initialize(credentialPath: String? = nil) async throws {
        try await ServiceQueue.background(.core) { [self] in
            ensureCallbacksRegistered()
            try await trezorInitialize(credentialPath: credentialPath)
        }
        Logger.info("Trezor manager initialized", context: "TrezorService")
    }

    /// Check if the Trezor manager is initialized
    func isInitialized() async -> Bool {
        await trezorIsInitialized()
    }

    // MARK: - Device Discovery

    /// Scan for available Trezor devices (USB + Bluetooth)
    /// - Returns: Array of discovered devices
    func scan() async throws -> [TrezorDeviceInfo] {
        try await ServiceQueue.background(.core) { [self] in
            ensureCallbacksRegistered()
            return try await trezorScan()
        }
    }

    /// List previously discovered devices
    /// - Returns: Array of known devices
    func listDevices() async throws -> [TrezorDeviceInfo] {
        try await ServiceQueue.background(.core) {
            try await trezorListDevices()
        }
    }

    // MARK: - Connection Management

    /// Connect to a Trezor device by its ID, opening the wallet given by `selection`.
    /// On THP devices (Safe 5/7) the passphrase is bound to the session at creation, so
    /// it is supplied per-connect rather than cached between calls.
    /// - Parameters:
    ///   - deviceId: The device identifier (path)
    ///   - selection: Which wallet to open (standard / hidden / on-device passphrase)
    /// - Returns: Device features after successful connection
    func connect(deviceId: String, selection: WalletSelection) async throws -> TrezorFeatures {
        try await ServiceQueue.background(.core) { [self] in
            ensureCallbacksRegistered()
            return try await trezorConnect(deviceId: deviceId, selection: selection)
        }
    }

    /// Disconnect from the currently connected device
    func disconnect() async throws {
        try await ServiceQueue.background(.core) {
            try await trezorDisconnect()
        }
        Logger.info("Disconnected from Trezor", context: "TrezorService")
    }

    /// Check if a device is currently connected
    func isConnected() async -> Bool {
        await trezorIsConnected()
    }

    /// Get information about the currently connected device
    func getConnectedDevice() async -> TrezorDeviceInfo? {
        await trezorGetConnectedDevice()
    }

    /// Get cached features of the currently connected device
    func getFeatures() async -> TrezorFeatures? {
        await trezorGetFeatures()
    }

    /// Get the device's master root fingerprint as an 8-character hex string
    /// - Returns: The root fingerprint (e.g., "73c5da0a")
    func getDeviceFingerprint() async throws -> String {
        try await ServiceQueue.background(.core) {
            try await trezorGetDeviceFingerprint()
        }
    }

    // MARK: - Address Operations

    /// Get a Bitcoin address from the connected device
    /// - Parameter params: Address derivation parameters
    /// - Returns: The generated address response
    func getAddress(params: TrezorGetAddressParams) async throws -> TrezorAddressResponse {
        try await ServiceQueue.background(.core) {
            try await trezorGetAddress(params: params)
        }
    }

    /// Get a public key (xpub) from the connected device
    /// - Parameter params: Public key derivation parameters
    /// - Returns: The public key response
    func getPublicKey(params: TrezorGetPublicKeyParams) async throws -> TrezorPublicKeyResponse {
        try await ServiceQueue.background(.core) {
            try await trezorGetPublicKey(params: params)
        }
    }

    // MARK: - Transaction Signing

    /// Sign a Bitcoin transaction with the connected device
    /// - Parameter params: Transaction signing parameters
    /// - Returns: The signed transaction
    func signTx(params: TrezorSignTxParams) async throws -> TrezorSignedTx {
        try await ServiceQueue.background(.core) {
            try await trezorSignTx(params: params)
        }
    }

    /// Sign a Bitcoin transaction from a PSBT (base64-encoded)
    /// - Parameters:
    ///   - psbtBase64: Base64-encoded PSBT data
    ///   - network: Bitcoin network type. Defaults to Bitcoin (mainnet) if nil.
    /// - Returns: The signed transaction
    func signTxFromPsbt(psbtBase64: String, network: TrezorCoinType? = nil) async throws -> TrezorSignedTx {
        try await ServiceQueue.background(.core) {
            try await trezorSignTxFromPsbt(psbtBase64: psbtBase64, network: network)
        }
    }

    // MARK: - Message Signing

    /// Sign a message with the connected device
    /// - Parameter params: Message signing parameters
    /// - Returns: The signed message response
    func signMessage(params: TrezorSignMessageParams) async throws -> TrezorSignedMessageResponse {
        try await ServiceQueue.background(.core) {
            try await trezorSignMessage(params: params)
        }
    }

    /// Verify a message signature with the connected device
    /// - Parameter params: Message verification parameters
    /// - Returns: True if the signature is valid
    func verifyMessage(params: TrezorVerifyMessageParams) async throws -> Bool {
        try await ServiceQueue.background(.core) {
            try await trezorVerifyMessage(params: params)
        }
    }

    // MARK: - Credential Management

    /// Clear stored Bluetooth pairing credentials for a specific device
    /// - Parameter deviceId: The device identifier
    func clearCredentials(deviceId: String) async throws {
        try await ServiceQueue.background(.core) {
            try await trezorClearCredentials(deviceId: deviceId)
        }
        Logger.info("Cleared credentials for device: \(deviceId)", context: "TrezorService")
    }
}
