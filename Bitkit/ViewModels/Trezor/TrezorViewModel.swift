import BitkitCore
import Combine
import Foundation

/// Represents the current step in the send transaction flow
enum SendStep {
    case form
    case review
    case signed
}

/// Account-type override for on-chain xpub tools. `automatic` preserves the
/// bitkit-core prefix detector; explicit values cover ambiguous xpub/tpub keys.
enum TrezorAccountTypeSelection: String, CaseIterable, Identifiable, CustomStringConvertible {
    case automatic
    case legacy
    case wrappedSegwit
    case nativeSegwit
    case taproot

    var id: String {
        rawValue
    }

    /// Segment label when rendered by `SegmentedControl`
    var description: String {
        title
    }

    var accountType: AccountType? {
        switch self {
        case .automatic: nil
        case .legacy: .legacy
        case .wrappedSegwit: .wrappedSegwit
        case .nativeSegwit: .nativeSegwit
        case .taproot: .taproot
        }
    }

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .legacy: "Legacy"
        case .wrappedSegwit: "Wrapped"
        case .nativeSegwit: "Native"
        case .taproot: "Taproot"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic: "Prefix"
        case .legacy: "BIP44"
        case .wrappedSegwit: "BIP49"
        case .nativeSegwit: "BIP84"
        case .taproot: "BIP86"
        }
    }
}

/// ViewModel for the Trezor hardware-wallet dev/dashboard screens. Owns only the dev-screen
/// tools (address generation, signing, lookups, the single dev watcher, etc.); device/connection
/// orchestration and pairing/PIN/passphrase coordination live in `TrezorManager`, injected here
/// as `connection`.
@Observable
@MainActor
class TrezorViewModel {
    // MARK: - Connection Manager

    /// Device/connection orchestration and pairing/PIN/passphrase coordination.
    let connection: TrezorManager

    // MARK: - Operation State

    /// Whether currently performing an operation (address, signing, etc.)
    var isOperating: Bool = false

    /// Last error message from a dev operation
    var error: String?

    // MARK: - Address Generation State

    /// Current derivation path
    var derivationPath: String = "m/84'/\(OnChainHwService.defaultCoinTypeComponent)/0'/0/0"

    /// Current script type for address generation
    var selectedScriptType: TrezorScriptType = .spendWitness

    /// Generated address
    var generatedAddress: String?

    /// Whether to show address on device
    var showAddressOnDevice: Bool = true

    // MARK: - Message Signing State

    /// Message to sign
    var messageToSign: String = "Hello, Trezor!"

    /// Path for message signing
    var messageSigningPath: String = "m/84'/\(OnChainHwService.defaultCoinTypeComponent)/0'/0/0"

    /// Signed message result
    var signedMessage: TrezorSignedMessageResponse?

    // MARK: - Address Index

    /// Current address index (last path component)
    var addressIndex: UInt32 = 0

    // MARK: - Public Key State

    /// Account-level derivation path for public key
    var publicKeyPath: String = "m/84'/\(OnChainHwService.defaultCoinTypeComponent)/0'"

    /// Retrieved xpub string
    var xpub: String?

    /// Retrieved compressed public key hex
    var publicKeyHex: String?

    /// Whether to show public key on Trezor screen
    var showPublicKeyOnDevice: Bool = false

    // MARK: - Debug Log

    /// Whether the debug log panel is expanded
    var showDebugLog: Bool = false

    // MARK: - Balance Lookup State

    /// Whether a balance lookup is in progress
    var isLookupLoading: Bool = false

    /// Error from the last balance lookup
    var lookupError: String?

    /// Account info result from xpub lookup
    var accountResult: AccountInfoResult?

    /// Single address info result from address lookup
    var addressResult: SingleAddressInfoResult?

    // MARK: - Transaction History State

    /// Whether a transaction history lookup is in progress
    var isTxHistoryLoading: Bool = false

    /// Error from the last transaction history lookup
    var txHistoryError: String?

    /// Transaction history result from xpub lookup
    var txHistoryResult: TransactionHistoryResult?

    // MARK: - Transaction Detail State

    /// Whether a transaction detail lookup is in progress
    var isTxDetailLoading: Bool = false

    /// Error from the last transaction detail lookup
    var txDetailError: String?

    /// Transaction detail result
    var txDetailResult: TransactionDetail?

    // MARK: - Send Transaction State

    /// Destination address for the transaction
    var sendAddress: String = ""

    /// Amount in satoshis to send
    var sendAmountSats: String = ""

    /// Fee rate in sat/vB
    var sendFeeRate: String = "2"

    /// Whether to send the maximum available balance
    var isSendMax: Bool = false

    /// Whether transaction composition is in progress
    var isComposing: Bool = false

    /// Coin selection strategy
    var coinSelection: CoinSelection = .branchAndBound

    /// Composed transaction result (the Success variant)
    var composeResult: ComposeResult?

    /// Signed transaction result
    var signedTxResult: TrezorSignedTx?

    /// Current step in the send flow
    var sendStep: SendStep = .form

    /// Whether a broadcast is in progress
    var isBroadcasting: Bool = false

    /// Broadcast transaction ID (set after successful broadcast)
    var broadcastTxid: String?

    /// Error specific to the send flow
    var sendError: String?

    // MARK: - Event Watcher State

    /// Connection status of the active watcher
    enum WatcherConnectionStatus {
        case idle
        case starting
        case connected
        case disconnected
        case error
    }

    /// Extended public key to watch
    var watcherExtendedKey: String = ""

    /// Gap limit input (string for the text field)
    var watcherGapLimit: String = "20"

    /// Optional account-type override shared by the on-chain xpub tools.
    /// Changing it restarts a running (or starting) watcher so the subscription uses the new type.
    var onchainAccountTypeSelection: TrezorAccountTypeSelection = .automatic {
        didSet {
            guard oldValue != onchainAccountTypeSelection else { return }
            restartWatcherIfRunning()
        }
    }

    /// Identifier of the active watcher, nil when not watching
    var activeWatcherId: String?

    /// Current connection status of the active watcher
    var watcherConnectionStatus: WatcherConnectionStatus = .idle

    /// Latest balance reported by the watcher
    var watcherBalance: WalletBalance?

    /// Latest block height reported by the watcher
    var watcherBlockHeight: UInt32 = 0

    /// Account type reported by the watcher
    var watcherAccountType: AccountType?

    /// Transaction count reported by the watcher
    var watcherTransactionCount: UInt32 = 0

    /// Latest transactions reported by the watcher
    var watcherTransactions: [HistoryTransaction] = []

    /// Rolling event log (most recent last, capped)
    var watcherEvents: [String] = []

    /// Error scoped to the watcher section.
    var watcherError: String?

    /// Whether a watcher is in the process of starting
    var isStartingWatcher: Bool = false

    /// Identifier of a watcher whose native start call is still in flight.
    private var startingWatcherId: String?

    /// Strong reference to the active listener so it stays alive while watching
    private var watcherListener: TrezorEventListener?

    /// Whether the watcher section has status or output worth keeping visible.
    var hasVisibleWatcherStatus: Bool {
        activeWatcherId != nil ||
            isStartingWatcher ||
            watcherConnectionStatus == .error ||
            watcherBalance != nil ||
            !watcherEvents.isEmpty
    }

    // MARK: - Private Properties

    private let trezorService = TrezorService.shared
    private let onChainService = OnChainHwService.shared
    private let watcherService: OnChainWatcherServicing

    // MARK: - Initialization

    init(connection: TrezorManager, watcherService: OnChainWatcherServicing = OnChainHwService.shared) {
        self.connection = connection
        self.watcherService = watcherService
    }

    // MARK: - Debug Log Helper

    /// Log to both Logger and TrezorDebugLog
    private func trezorLog(_ message: String, level: String = "info") {
        switch level {
        case "error":
            Logger.error(message, context: "TrezorViewModel")
        case "warn":
            Logger.warn(message, context: "TrezorViewModel")
        default:
            Logger.info(message, context: "TrezorViewModel")
        }
        TrezorDebugLog.shared.log(message)
    }

    // MARK: - Address Operations

    /// Get address from connected device
    /// - Parameter showOnDevice: Whether to display address on Trezor screen
    func getAddress(showOnDevice: Bool = true) async {
        guard connection.isConnected else {
            error = "Not connected to a Trezor"
            return
        }

        isOperating = true
        error = nil

        do {
            let params = TrezorGetAddressParams(
                path: derivationPath,
                coin: connection.selectedNetwork,
                showOnTrezor: showOnDevice,
                scriptType: selectedScriptType
            )

            let response = try await trezorService.getAddress(params: params)
            generatedAddress = response.address
            connection.showConfirmOnDevice = false

            trezorLog("Generated address: \(response.address)")
        } catch {
            self.error = errorMessage(from: error)
            connection.showConfirmOnDevice = false
            trezorLog("Get address failed: \(error)", level: "error")
        }

        isOperating = false
    }

    // MARK: - Message Signing

    /// Sign a message with the connected device
    func signMessage() async {
        guard connection.isConnected else {
            error = "Not connected to a Trezor"
            return
        }

        guard !messageToSign.isEmpty else {
            error = "Please enter a message to sign"
            return
        }

        isOperating = true
        error = nil

        do {
            let params = TrezorSignMessageParams(
                path: messageSigningPath,
                message: messageToSign,
                coin: connection.selectedNetwork
            )

            let response = try await trezorService.signMessage(params: params)
            signedMessage = response
            connection.showConfirmOnDevice = false

            trezorLog("Message signed successfully")
        } catch {
            self.error = errorMessage(from: error)
            connection.showConfirmOnDevice = false
            trezorLog("Sign message failed: \(error)", level: "error")
        }

        isOperating = false
    }

    /// Verify a signed message
    func verifyMessage(address: String, signature: String, message: String) async -> Bool {
        guard connection.isConnected else {
            error = "Not connected to a Trezor"
            return false
        }

        isOperating = true
        error = nil

        do {
            let params = TrezorVerifyMessageParams(
                address: address,
                signature: signature,
                message: message,
                coin: connection.selectedNetwork
            )

            let isValid = try await trezorService.verifyMessage(params: params)
            connection.showConfirmOnDevice = false

            trezorLog("Message verification result: \(isValid)")

            isOperating = false
            return isValid
        } catch {
            self.error = errorMessage(from: error)
            connection.showConfirmOnDevice = false
            trezorLog("Verify message failed: \(error)", level: "error")

            isOperating = false
            return false
        }
    }

    // MARK: - Address Index

    /// Increment the address index and update derivation path
    func incrementAddressIndex() {
        addressIndex += 1
        updateDerivationPathIndex()
    }

    /// Decrement the address index (minimum 0) and update derivation path
    func decrementAddressIndex() {
        guard addressIndex > 0 else { return }
        addressIndex -= 1
        updateDerivationPathIndex()
    }

    /// Update the last component of the derivation path to match addressIndex
    private func updateDerivationPathIndex() {
        var components = derivationPath.split(separator: "/")
        guard components.count >= 2 else { return }
        components[components.count - 1] = Substring("\(addressIndex)")
        derivationPath = components.joined(separator: "/")
    }

    // MARK: - Public Key Operations

    /// Get public key (xpub) from connected device
    func getPublicKey(showOnDevice: Bool = false) async {
        guard connection.isConnected else {
            error = "Not connected to a Trezor"
            return
        }

        isOperating = true
        error = nil

        do {
            let params = TrezorGetPublicKeyParams(
                path: publicKeyPath,
                coin: connection.selectedNetwork,
                showOnTrezor: showOnDevice
            )

            let response = try await trezorService.getPublicKey(params: params)
            xpub = response.xpub
            publicKeyHex = response.publicKey
            connection.showConfirmOnDevice = false

            trezorLog("Got public key for path: \(publicKeyPath)")
        } catch {
            self.error = errorMessage(from: error)
            connection.showConfirmOnDevice = false
            trezorLog("Get public key failed: \(error)", level: "error")
        }

        isOperating = false
    }

    // MARK: - Transaction Signing

    /// Sign a Bitcoin transaction
    func signTx(params: TrezorSignTxParams) async -> TrezorSignedTx? {
        guard connection.isConnected else {
            error = "Not connected to a Trezor"
            return nil
        }

        isOperating = true
        error = nil

        do {
            let result = try await trezorService.signTx(params: params)
            connection.showConfirmOnDevice = false
            trezorLog("Transaction signed successfully")
            isOperating = false
            return result
        } catch {
            self.error = errorMessage(from: error)
            connection.showConfirmOnDevice = false
            trezorLog("Sign tx failed: \(error)", level: "error")
            isOperating = false
            return nil
        }
    }

    // MARK: - PSBT Signing

    /// Sign a Bitcoin transaction from a PSBT (base64-encoded)
    /// - Parameter psbtBase64: Base64-encoded PSBT data
    /// - Returns: The signed transaction, or nil on failure
    func signTxFromPsbt(psbtBase64: String) async -> TrezorSignedTx? {
        guard connection.isConnected else {
            error = "Not connected to a Trezor"
            return nil
        }

        isOperating = true
        error = nil

        do {
            let result = try await trezorService.signTxFromPsbt(
                psbtBase64: psbtBase64,
                network: connection.selectedNetwork
            )
            connection.showConfirmOnDevice = false
            trezorLog("PSBT signed successfully")
            isOperating = false
            return result
        } catch {
            self.error = errorMessage(from: error)
            connection.showConfirmOnDevice = false
            trezorLog("Sign PSBT failed: \(error)", level: "error")
            isOperating = false
            return nil
        }
    }

    // MARK: - Device Fingerprint

    /// Get the device's master root fingerprint
    func getDeviceFingerprint() async {
        guard connection.isConnected else {
            error = "Not connected to a Trezor"
            return
        }

        isOperating = true
        error = nil

        do {
            let fingerprint = try await trezorService.getDeviceFingerprint()
            connection.deviceFingerprint = fingerprint
            trezorLog("Device fingerprint: \(fingerprint)")
        } catch {
            self.error = errorMessage(from: error)
            trezorLog("Get fingerprint failed: \(error)", level: "error")
        }

        isOperating = false
    }

    // MARK: - Network Switching

    /// React to a dashboard network switch by resetting the dev-tool derivation paths,
    /// results and the dev watcher. The network change itself is owned by `TrezorManager`.
    func handleNetworkChange() {
        // A running watcher is bound to the previous network's Electrum server.
        stopWatcher()

        // Reset derivation paths with the new coin type
        derivationPath = "m/84'/\(connection.coinTypeComponent)/0'/0/0"
        publicKeyPath = "m/84'/\(connection.coinTypeComponent)/0'"
        messageSigningPath = "m/84'/\(connection.coinTypeComponent)/0'/0/0"
        addressIndex = 0

        clearWalletResults()
    }

    /// Clear dev-tool results derived from the connected wallet (generated address, xpub, public
    /// key, signed message and lookup results). Called on network switch, disconnect and
    /// wallet-mode change so a previous wallet's data is never shown for a different/absent wallet.
    func clearWalletResults() {
        generatedAddress = nil
        xpub = nil
        publicKeyHex = nil
        signedMessage = nil
        error = nil
        accountResult = nil
        addressResult = nil
        lookupError = nil
        resetSendFlow()
    }

    // MARK: - Balance Lookup Operations

    /// Input type detection for balance lookup
    enum LookupInputType {
        case address
        case extendedKey
        case unknown
    }

    /// Detect the type of input string
    static func detectInputType(_ input: String) -> LookupInputType {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }
        let xpubPrefixes = ["xpub", "ypub", "zpub", "tpub", "upub", "vpub"]
        if xpubPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return .extendedKey
        }
        if trimmed.hasPrefix("1") || trimmed.hasPrefix("3") ||
            trimmed.hasPrefix("bc1") || trimmed.hasPrefix("tb1") ||
            trimmed.hasPrefix("bcrt1") || trimmed.hasPrefix("m") ||
            trimmed.hasPrefix("n") || trimmed.hasPrefix("2")
        {
            return .address
        }
        return .unknown
    }

    /// Perform a balance lookup for the given input (address or xpub)
    func performLookup(input: String) async {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return }

        isLookupLoading = true
        lookupError = nil
        accountResult = nil
        addressResult = nil
        resetSendFlow()

        let electrumUrl = OnChainHwService.electrumUrlForNetwork(connection.selectedNetwork)

        do {
            switch Self.detectInputType(trimmedInput) {
            case .extendedKey:
                accountResult = try await onChainService.getAccountInfo(
                    extendedKey: trimmedInput,
                    electrumUrl: electrumUrl,
                    network: connection.selectedNetwork,
                    scriptType: onchainAccountTypeSelection.accountType
                )
            case .address:
                addressResult = try await onChainService.getAddressInfo(
                    address: trimmedInput,
                    electrumUrl: electrumUrl,
                    network: connection.selectedNetwork
                )
            case .unknown:
                lookupError = "Unrecognized input. Enter a Bitcoin address or extended public key (xpub/ypub/zpub/tpub/upub/vpub)."
            }
        } catch {
            lookupError = formatLookupError(error)
        }

        isLookupLoading = false
    }

    /// Format balance lookup errors for user display
    private func formatLookupError(_ error: Error) -> String {
        if let accountError = error as? AccountInfoError {
            switch accountError {
            case let .InvalidExtendedKey(errorDetails):
                return "Invalid extended public key: \(errorDetails)"
            case let .InvalidAddress(errorDetails):
                return "Invalid Bitcoin address: \(errorDetails)"
            case let .ElectrumError(errorDetails):
                return "Electrum connection failed: \(errorDetails)"
            case let .WalletError(errorDetails):
                return "Wallet error: \(errorDetails)"
            case let .SyncError(errorDetails):
                return "Sync failed: \(errorDetails)"
            case let .UnsupportedKeyType(errorDetails):
                return "Unsupported key type: \(errorDetails)"
            case let .NetworkMismatch(errorDetails):
                return "Network mismatch: \(errorDetails)"
            case let .InvalidTxid(errorDetails):
                return "Invalid transaction ID: \(errorDetails)"
            case let .TransactionNotFound(errorDetails):
                return "Transaction not found: \(errorDetails)"
            case let .WatcherError(errorDetails):
                return "Watcher error: \(errorDetails)"
            }
        }
        if let appError = error as? AppError,
           let debugMessage = appError.debugMessage, !debugMessage.isEmpty
        {
            return debugMessage
        }
        return error.localizedDescription
    }

    // MARK: - Transaction History Operations

    /// Fetch transaction history for an extended public key
    func fetchTransactionHistory(extendedKey: String) async {
        let trimmedKey = extendedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        isTxHistoryLoading = true
        txHistoryError = nil
        txHistoryResult = nil

        let electrumUrl = OnChainHwService.electrumUrlForNetwork(connection.selectedNetwork)

        do {
            txHistoryResult = try await onChainService.getTransactionHistory(
                extendedKey: trimmedKey,
                electrumUrl: electrumUrl,
                network: connection.selectedNetwork,
                scriptType: onchainAccountTypeSelection.accountType
            )
        } catch {
            txHistoryError = formatLookupError(error)
        }

        isTxHistoryLoading = false
    }

    // MARK: - Transaction Detail Operations

    /// Fetch detailed information for a specific transaction
    func fetchTransactionDetail(extendedKey: String, txid: String) async {
        let trimmedKey = extendedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTxid = txid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedTxid.isEmpty else { return }

        isTxDetailLoading = true
        txDetailError = nil
        txDetailResult = nil

        let electrumUrl = OnChainHwService.electrumUrlForNetwork(connection.selectedNetwork)

        do {
            txDetailResult = try await onChainService.getTransactionDetail(
                extendedKey: trimmedKey,
                electrumUrl: electrumUrl,
                txid: trimmedTxid,
                network: connection.selectedNetwork,
                scriptType: onchainAccountTypeSelection.accountType
            )
        } catch {
            txDetailError = formatLookupError(error)
        }

        isTxDetailLoading = false
    }

    // MARK: - Send Transaction Operations

    /// Toggle the send-max flag
    func toggleSendMax() {
        isSendMax.toggle()
    }

    /// Set the coin selection strategy
    func setCoinSelection(_ selection: CoinSelection) {
        coinSelection = selection
    }

    /// Compose a transaction using BDK-based PSBT generation
    /// - Parameters:
    ///   - extendedKey: The extended public key (xpub/ypub/zpub) used for the balance lookup
    ///   - accountInfo: The account info from a prior xpub balance lookup
    func composeTx(extendedKey: String, accountInfo: AccountInfoResult) async {
        // Validate inputs
        let address = sendAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            sendError = "Enter a destination address"
            return
        }
        if !isSendMax {
            guard let amount = UInt64(sendAmountSats.trimmingCharacters(in: .whitespacesAndNewlines)), amount > 0 else {
                sendError = "Enter a valid amount"
                return
            }
        }
        guard let feeRate = Float(sendFeeRate), feeRate > 0 else {
            sendError = "Enter a valid fee rate"
            return
        }

        isComposing = true
        sendError = nil

        // Ensure we have the device fingerprint for proper PSBT derivation paths.
        // Without it, BDK produces relative paths (e.g. m/0/0) that the Trezor
        // rejects as "Forbidden key path".
        if connection.deviceFingerprint == nil {
            do {
                connection.deviceFingerprint = try await trezorService.getDeviceFingerprint()
            } catch {
                trezorLog("Failed to get device fingerprint: \(error)", level: "error")
                sendError = "Failed to get device fingerprint"
                isComposing = false
                return
            }
        }

        trezorLog("=== composeTx START ===")
        trezorLog("address=\(address), amount=\(sendAmountSats), sendMax=\(isSendMax)")
        trezorLog("feeRate=\(sendFeeRate) sat/vB, coinSelection=\(String(describing: coinSelection))")
        trezorLog("balance=\(accountInfo.balance)")

        let output: ComposeOutput = isSendMax
            ? .sendMax(address: address)
            : .payment(address: address, amountSats: UInt64(sendAmountSats) ?? 0)

        let electrumUrl = OnChainHwService.electrumUrlForNetwork(connection.selectedNetwork)
        let network = connection.selectedNetwork.coreNetwork

        let wallet = WalletParams(
            extendedKey: extendedKey,
            electrumUrl: electrumUrl,
            fingerprint: connection.deviceFingerprint,
            network: network,
            accountType: accountInfo.accountType
        )

        let params = ComposeParams(
            wallet: wallet,
            outputs: [output],
            feeRates: [feeRate],
            coinSelection: coinSelection
        )

        do {
            let results = try await onChainService.composeTransaction(params: params)
            handleComposeResults(results)
        } catch {
            trezorLog("composeTx FAILED: \(error)", level: "error")
            sendError = errorMessage(from: error)
            isComposing = false
        }
    }

    /// Process compose results, extracting the first Success result
    private func handleComposeResults(_ results: [ComposeResult]) {
        trezorLog("Got \(results.count) compose result(s)")

        var successResult: ComposeResult?
        var errorMsg: String?

        for (i, result) in results.enumerated() {
            switch result {
            case let .success(psbt, fee, feeRate, totalSpent):
                trezorLog("[\(i)] Success: fee=\(fee), feeRate=\(feeRate), totalSpent=\(totalSpent), psbtLen=\(psbt.count)")
                if successResult == nil {
                    successResult = result
                }
            case let .error(error):
                trezorLog("[\(i)] Error: \(error)")
                if errorMsg == nil {
                    errorMsg = error
                }
            }
        }

        if successResult != nil {
            trezorLog("=== composeTx SUCCESS ===")
            composeResult = successResult
            sendStep = .review
        } else if let errorMsg {
            trezorLog("=== composeTx FAILED (compose error) ===")
            sendError = errorMsg
        } else {
            trezorLog("=== composeTx FAILED (no valid result) ===")
            sendError = "No valid composition returned"
        }

        isComposing = false
    }

    /// Sign the composed PSBT with the connected Trezor device
    func signComposedTx() async {
        guard let result = composeResult else { return }

        // Extract PSBT from the Success case
        guard case let .success(psbt, _, _, _) = result else {
            sendError = "No valid compose result to sign"
            return
        }

        guard connection.isConnected else {
            sendError = "Not connected to a Trezor"
            return
        }

        isOperating = true
        sendError = nil

        trezorLog("=== signComposedTx START ===")
        trezorLog("psbtLen=\(psbt.count)")

        do {
            // Sign PSBT directly with Trezor
            trezorLog("Calling trezor signTxFromPsbt...")
            let signedTx = try await trezorService.signTxFromPsbt(
                psbtBase64: psbt,
                network: connection.selectedNetwork
            )
            connection.showConfirmOnDevice = false

            trezorLog("=== signComposedTx SUCCESS ===")
            trezorLog("signatures=\(signedTx.signatures.count), txid=\(signedTx.txid ?? "nil"), rawTxLen=\(signedTx.serializedTx.count)")

            signedTxResult = signedTx
            sendStep = .signed
        } catch {
            connection.showConfirmOnDevice = false
            trezorLog("signComposedTx FAILED: \(error)", level: "error")
            sendError = errorMessage(from: error)
        }

        isOperating = false
    }

    /// Broadcast the signed transaction via Electrum
    func broadcastSignedTx() async {
        guard let rawTx = signedTxResult?.serializedTx else { return }

        isBroadcasting = true
        sendError = nil

        let electrumUrl = OnChainHwService.electrumUrlForNetwork(connection.selectedNetwork)

        do {
            let txid = try await onChainService.broadcastRawTx(serializedTx: rawTx, electrumUrl: electrumUrl)
            trezorLog("BROADCAST SUCCESS txid=\(txid)")
            broadcastTxid = txid
        } catch {
            trezorLog("BROADCAST FAILED: \(error)", level: "error")
            sendError = errorMessage(from: error)
        }

        isBroadcasting = false
    }

    /// Reset all send flow state to defaults
    func resetSendFlow() {
        sendAddress = ""
        sendAmountSats = ""
        sendFeeRate = "2"
        isSendMax = false
        isComposing = false
        coinSelection = .branchAndBound
        composeResult = nil
        signedTxResult = nil
        sendStep = .form
        isBroadcasting = false
        broadcastTxid = nil
        sendError = nil
    }

    /// Go back from review to compose form
    func backToComposeForm() {
        sendStep = .form
        composeResult = nil
        signedTxResult = nil
        sendError = nil
    }

    // MARK: - Helpers

    // Convert TrezorCoinType to the Network enum used by onchain FFI functions

    // MARK: - Error Handling

    /// Extract a user-friendly error message from a Trezor error
    private func errorMessage(from error: Error) -> String {
        // ServiceQueue wraps all errors in AppError, so extract the original message
        if let appError = error as? AppError {
            // debugMessage contains the original error's localizedDescription
            if let debugMessage = appError.debugMessage, !debugMessage.isEmpty {
                // Check for common Trezor error patterns in the debug message
                return formatTrezorErrorMessage(debugMessage)
            }
            // Fall through to show the app error message if no debug info
            return appError.message
        }

        // Handle TrezorError directly (if not wrapped)
        if let trezorError = error as? TrezorError {
            return trezorError.localizedDescription
        }

        // Handle TrezorBLEError from BLE layer
        if let bleError = error as? TrezorBLEError {
            return bleError.localizedDescription
        }

        // Handle TrezorTransportError from transport layer
        if let transportError = error as? TrezorTransportError {
            return transportError.localizedDescription
        }

        // For any other error, try to get a meaningful description
        let description = error.localizedDescription
        if description == "The operation couldn't be completed." || description.isEmpty {
            return "Connection failed. Please ensure your Trezor is in pairing mode and try again."
        }
        return description
    }

    /// Format Trezor error messages for user display
    private func formatTrezorErrorMessage(_ message: String) -> String {
        // Clean up common Trezor error prefixes for better readability
        let cleanedMessage = message
            .replacingOccurrences(of: "Transport error: ", with: "")
            .replacingOccurrences(of: "Connection error: ", with: "")
            .replacingOccurrences(of: "Protocol error: ", with: "")
            .replacingOccurrences(of: "Device error: ", with: "")
            .replacingOccurrences(of: "Session error: ", with: "")
            .replacingOccurrences(of: "IO error: ", with: "")

        // Map technical messages to user-friendly ones
        if message.contains("Stale Bluetooth pairing") || message.contains("Peer removed pairing") {
            return "Stale Bluetooth pairing detected. Go to iOS Settings → Bluetooth, forget your Trezor device, then put it back in pairing mode and try again."
        }
        if message.contains("Unable to open device") || message.contains("Failed to connect") {
            return "Failed to connect to Trezor. Please ensure it's in pairing mode and try again."
        }
        if message.contains("Pairing required") {
            return "Bluetooth pairing required. Please put your Trezor in pairing mode."
        }
        if message.contains("Pairing failed") || message.contains("Invalid credentials") {
            return "Pairing failed. Please try putting your Trezor back in pairing mode."
        }
        if message.contains("THP handshake failed") {
            return "Connection handshake failed. Please disconnect and try again."
        }
        if message.contains("timed out") || message.contains("Timeout") {
            return "Connection timed out. Please try again."
        }
        if message.contains("Device disconnected") {
            return "Trezor disconnected. Please reconnect and try again."
        }
        if message.contains("Action cancelled") {
            return "Action was cancelled on the device."
        }

        // Return the cleaned message if no specific mapping
        return cleanedMessage
    }

    // MARK: - Event Watcher Operations

    /// Copy the most recently retrieved xpub into the watcher's extended-key field.
    func populateWatcherFromXpub() {
        if let xpub {
            watcherExtendedKey = xpub
        }
    }

    /// Start watching the entered extended key for on-chain activity.
    func startWatcher() async {
        let key = watcherExtendedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            watcherError = "Enter an extended public key to watch"
            return
        }
        guard !isStartingWatcher, activeWatcherId == nil else { return }

        guard let gapLimit = UInt32(watcherGapLimit.trimmingCharacters(in: .whitespacesAndNewlines)), gapLimit > 0 else {
            watcherError = "Gap limit must be a positive integer"
            return
        }

        let watcherId = UUID().uuidString
        let network = connection.selectedNetwork
        let accountType = onchainAccountTypeSelection.accountType

        let params = WatcherParams(
            watcherId: watcherId,
            extendedKey: key,
            electrumUrl: OnChainHwService.electrumUrlForNetwork(network),
            network: network.coreNetwork,
            accountType: accountType,
            gapLimit: gapLimit
        )

        let listener = TrezorEventListener { [weak self] id, event in
            self?.handleWatcherEvent(watcherId: id, event: event)
        }
        watcherListener = listener

        isStartingWatcher = true
        startingWatcherId = watcherId
        watcherConnectionStatus = .starting
        watcherTransactions = []
        watcherEvents = ["starting: \(watcherId)"]
        watcherBalance = nil
        watcherTransactionCount = 0
        watcherBlockHeight = 0
        watcherAccountType = nil
        watcherError = nil
        trezorLog("Starting watcher \(watcherId) for \(key.prefix(12))...")

        do {
            try await watcherService.startWatcher(params: params, listener: listener)
            guard startingWatcherId == watcherId else {
                try? watcherService.stopWatcher(watcherId: watcherId)
                trezorLog("Stopped stale watcher start: \(watcherId)", level: "warn")
                return
            }

            if connection.selectedNetwork != network {
                try? watcherService.stopWatcher(watcherId: watcherId)
                finishStoppedWatcherStartup(watcherId: watcherId)
                return
            }

            if onchainAccountTypeSelection.accountType != accountType {
                try? watcherService.stopWatcher(watcherId: watcherId)
                finishStoppedWatcherStartup(watcherId: watcherId)
                trezorLog("Account type changed during watcher startup, restarting: \(watcherId)")
                scheduleWatcherRestart()
                return
            }

            activeWatcherId = watcherId
            startingWatcherId = nil
            isStartingWatcher = false
            appendWatcherEvent("started")
            trezorLog("Watcher started: \(watcherId)")
        } catch {
            guard startingWatcherId == watcherId else {
                trezorLog("Superseded watcher start failed: \(watcherId)", level: "warn")
                return
            }

            // A native-side stop that aborts the Rust startup surfaces here as a
            // thrown error rather than a return. A Swift-side stop is already handled
            // by the quarantine in stopWatcher() and the stale guard above; this covers
            // the core stopping the watcher directly. It's a cancellation, not a
            // failure the user caused.
            if Self.isWatcherStartupCancellation(error) {
                finishStoppedWatcherStartup(watcherId: watcherId)
                return
            }

            let message = errorMessage(from: error)
            watcherError = message
            watcherConnectionStatus = .error
            activeWatcherId = nil
            startingWatcherId = nil
            watcherListener = nil
            appendWatcherEvent("start failed: \(message)")
            trezorLog("Watcher start failed: \(error)", level: "error")
            isStartingWatcher = false
        }
    }

    /// Stop the active watcher, if any. A watcher whose native start call is still
    /// in flight is stopped too: its id is quarantined so handleWatcherEvent drops
    /// any events that arrive before the native call returns.
    func stopWatcher() {
        if let startingId = startingWatcherId {
            // Abort the in-flight native startup and quarantine the id; if the
            // native call still returns success, startWatcher's stale-start check
            // stops the watcher then.
            try? watcherService.stopWatcher(watcherId: startingId)
            finishStoppedWatcherStartup(watcherId: startingId)
        }

        guard let watcherId = activeWatcherId else { return }
        do {
            try watcherService.stopWatcher(watcherId: watcherId)
        } catch {
            trezorLog("Watcher stop failed: \(error)", level: "warn")
        }
        activeWatcherId = nil
        watcherConnectionStatus = .idle
        watcherListener = nil
        watcherBalance = nil
        watcherTransactions = []
        watcherTransactionCount = 0
        watcherBlockHeight = 0
        watcherAccountType = nil
        watcherEvents = []
        watcherError = nil
        trezorLog("Watcher stopped: \(watcherId)")
    }

    /// Tear down all watchers when the Trezor dashboard is dismissed. On Android this
    /// happens in the ViewModel's onCleared, but this ViewModel is app-lifetime, so the
    /// root view calls it from onDisappear.
    func stopAllWatchers() {
        stopWatcher()
        watcherService.stopAllWatchers()
    }

    /// Full teardown when the Trezor dashboard is dismissed: stop all watchers and
    /// reset the watcher input state so the next visit starts fresh.
    func handleDashboardDismiss() {
        stopAllWatchers()
        watcherExtendedKey = ""
        watcherGapLimit = "20"
        onchainAccountTypeSelection = .automatic
    }

    /// Restart a running watcher (e.g. after the account-type override changes)
    /// so the Electrum subscription reflects the new settings. A change that lands
    /// while a start is still in flight is handled by startWatcher itself, which
    /// re-checks the selection once the native call returns.
    private func restartWatcherIfRunning() {
        guard activeWatcherId != nil else { return }
        stopWatcher()
        scheduleWatcherRestart()
    }

    /// Start a replacement watcher on the next main-actor turn. Bails if the input
    /// state was cleared in the meantime (dashboard dismissed) so an unsolicited
    /// restart never revives a watcher or surfaces a validation error.
    private func scheduleWatcherRestart() {
        Task {
            guard !watcherExtendedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await startWatcher()
        }
    }

    /// Handle a watcher event on the main actor. Filters out events from stale watchers.
    private func handleWatcherEvent(watcherId: String, event: WatcherEvent) {
        guard watcherId == activeWatcherId || watcherId == startingWatcherId else { return }

        switch event {
        case let .transactionsChanged(transactions, balance, txCount, blockHeight, accountType):
            watcherConnectionStatus = .connected
            watcherError = nil
            watcherTransactions = transactions
            watcherBalance = balance
            watcherTransactionCount = txCount
            watcherBlockHeight = blockHeight
            watcherAccountType = accountType
            appendWatcherEvent("transactionsChanged: \(txCount) txs, balance \(balance.total) sats")
        case let .error(message):
            watcherConnectionStatus = .error
            watcherError = message
            appendWatcherEvent("error: \(message)")
        case let .disconnected(message):
            watcherConnectionStatus = .disconnected
            appendWatcherEvent("disconnected: \(message)")
        case .reconnected:
            watcherConnectionStatus = .connected
            appendWatcherEvent("reconnected")
        }
    }

    /// Append to the rolling event log, capping at the most recent 50 entries.
    private func appendWatcherEvent(_ message: String) {
        watcherEvents.append(message)
        if watcherEvents.count > 50 {
            watcherEvents.removeFirst(watcherEvents.count - 50)
        }
    }

    /// Message the Rust core throws when a stop aborts a watcher whose startup is
    /// still in flight — a cancellation, not a genuine failure.
    private static let watcherStartupCancelledMessage = "Watcher stopped during startup"

    /// True when a thrown startup error is the Rust core reporting that the watcher
    /// was deliberately stopped mid-startup. ServiceQueue wraps core errors in
    /// AppError, so check the wrapped debug message as well as the typed error.
    private static func isWatcherStartupCancellation(_ error: Error) -> Bool {
        if let accountInfoError = error as? AccountInfoError,
           case let .WatcherError(errorDetails) = accountInfoError
        {
            return errorDetails.contains(watcherStartupCancelledMessage)
        }
        if let appError = error as? AppError, let debugMessage = appError.debugMessage {
            return debugMessage.contains(watcherStartupCancelledMessage)
        }
        return false
    }

    private func finishStoppedWatcherStartup(watcherId: String) {
        guard startingWatcherId == watcherId else { return }
        activeWatcherId = nil
        startingWatcherId = nil
        isStartingWatcher = false
        watcherConnectionStatus = .idle
        watcherListener = nil
        watcherBalance = nil
        watcherTransactions = []
        watcherTransactionCount = 0
        watcherBlockHeight = 0
        watcherAccountType = nil
        watcherEvents = []
        watcherError = nil
        trezorLog("Watcher startup stopped before activation: \(watcherId)")
    }

    // MARK: - AI Test Hooks

    func testShowPinPrompt() {
        guard Env.isTrezorEmulatorTesting else { return }
        connection.showPinEntry = true
    }

    func testShowPassphrasePrompt() {
        guard Env.isTrezorEmulatorTesting else { return }
        connection.showPassphraseEntry = true
    }

    func testShowPairingCodePrompt() {
        guard Env.isTrezorEmulatorTesting else { return }
        connection.showPairingCode = true
    }

    func testShowConfirmOnDevicePrompt() {
        guard Env.isTrezorEmulatorTesting else { return }
        connection.confirmMessage = "Confirm test action on your Trezor"
        connection.showConfirmOnDevice = true
    }
}
