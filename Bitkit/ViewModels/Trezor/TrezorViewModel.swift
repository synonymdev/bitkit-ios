import BitkitCore
import Combine
import CoreBluetooth
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

/// ViewModel for Trezor hardware wallet integration
@Observable
@MainActor
class TrezorViewModel {
    // MARK: - Network Configuration

    /// The network selected in the Trezor dashboard (independent of app's global network)
    var selectedNetwork: TrezorCoinType

    /// Map the app's current network to the corresponding TrezorCoinType (used for default initialization)
    static var appDefaultCoinType: TrezorCoinType {
        switch Env.network {
        case .bitcoin: .bitcoin
        case .testnet: .testnet
        case .signet: .signet
        case .regtest: .regtest
        }
    }

    /// BIP44 coin type component based on the dashboard's selected network: "0'" for mainnet, "1'" for test networks
    var coinTypeComponent: String {
        selectedNetwork == .bitcoin ? "0'" : "1'"
    }

    /// BIP44 coin type component based on the app's global network (used for initial default values)
    private static var defaultCoinTypeComponent: String {
        Env.network == .bitcoin ? "0'" : "1'"
    }

    // MARK: - Connection State

    /// Whether the Trezor manager is initialized
    private var isInitialized: Bool = false

    /// Whether currently scanning for devices
    var isScanning: Bool = false

    /// Whether currently performing an operation (address, signing, etc.)
    var isOperating: Bool = false

    /// List of discovered devices
    var devices: [TrezorDeviceInfo] = []

    /// Currently connected device
    var connectedDevice: TrezorDeviceInfo?

    /// Features of the connected device
    var deviceFeatures: TrezorFeatures?

    /// Device root fingerprint (hex string)
    var deviceFingerprint: String?

    /// Last error message
    var error: String?

    // MARK: - UI Dialog State

    /// Show PIN entry dialog
    var showPinEntry: Bool = false

    /// Show passphrase entry dialog
    var showPassphraseEntry: Bool = false

    /// Show BLE pairing code dialog
    var showPairingCode: Bool = false

    /// Show "Confirm on device" overlay
    var showConfirmOnDevice: Bool = false

    /// Message for confirm on device overlay
    var confirmMessage: String = ""

    /// Show the "where to enter the passphrase" chooser (phone vs Trezor).
    /// Only presented for devices that report on-device passphrase entry capability.
    var showWalletModeChooser: Bool = false

    // MARK: - Wallet Mode State

    /// The currently selected wallet mode (standard / hidden-on-phone / hidden-on-device).
    /// Drives the wallet-mode selector UI; the binding to the device session is applied
    /// via setWalletMode (disconnect/reconnect).
    var walletMode: TrezorWalletMode = .standard

    /// Whether the connected device supports entering the passphrase on the Trezor itself.
    var passphraseEntryCapable: Bool {
        deviceFeatures?.passphraseEntryCapable == true
    }

    // MARK: - Address Generation State

    /// Current derivation path
    var derivationPath: String = "m/84'/\(defaultCoinTypeComponent)/0'/0/0"

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
    var messageSigningPath: String = "m/84'/\(defaultCoinTypeComponent)/0'/0/0"

    /// Signed message result
    var signedMessage: TrezorSignedMessageResponse?

    // MARK: - Known Devices & Auto-Reconnect

    /// Previously connected devices loaded from storage
    var knownDevices: [TrezorKnownDevice] = []

    /// Whether auto-reconnect is in progress
    var isAutoReconnecting: Bool = false

    /// Status text during auto-reconnect
    var autoReconnectStatus: String?

    /// Prevents a user-initiated disconnect from immediately reconnecting
    /// when the disconnected device list appears.
    private var suppressNextAutoReconnect = false

    // MARK: - Address Index

    /// Current address index (last path component)
    var addressIndex: UInt32 = 0

    // MARK: - Public Key State

    /// Account-level derivation path for public key
    var publicKeyPath: String = "m/84'/\(defaultCoinTypeComponent)/0'"

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

    // MARK: - Bluetooth State

    /// Current Bluetooth state — reads directly from BLEManager (@Observable chaining)
    var bluetoothState: CBManagerState {
        TrezorBLEManager.shared.bluetoothState
    }

    var isBridgeModeEnabled: Bool {
        transport.isBridgeEnabled
    }

    // MARK: - Private Properties

    private let trezorService = TrezorService.shared
    private let watcherService: TrezorWatcherServicing
    private let transport = TrezorTransport.shared
    private let uiHandler = TrezorUiHandler.shared
    private var cancellables = Set<AnyCancellable>()
    private var hasSetupSubscriptions = false

    // MARK: - Initialization

    init(watcherService: TrezorWatcherServicing = TrezorService.shared) {
        self.watcherService = watcherService
        selectedNetwork = Self.appDefaultCoinType
        // Callback subscriptions are deferred to initialize() to avoid
        // triggering BLE stack and Combine overhead at app launch.
    }

    /// Subscribe to callback publishers for UI notifications
    private func setupCallbackSubscriptions() {
        // Pairing code request
        transport.needsPairingCodePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.showPairingCode = true
            }
            .store(in: &cancellables)

        // PIN request from device
        uiHandler.needsPinPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.showPinEntry = true
            }
            .store(in: &cancellables)

        // Passphrase entry is now driven proactively by the wallet-mode selector
        // (see setWalletMode / requestPassphraseWallet). The device callback
        // `onPassphraseRequest` is answered silently from the selected mode, so there
        // is no reactive passphrase prompt to subscribe to here.
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

    // MARK: - State Reset Helpers

    func clearWalletDerivedState() {
        deviceFingerprint = nil
        generatedAddress = nil
        signedMessage = nil
        xpub = nil
        publicKeyHex = nil
    }

    func clearDisconnectedDeviceState(errorMessage: String? = nil) {
        connectedDevice = nil
        deviceFeatures = nil
        clearWalletDerivedState()
        error = errorMessage
        showPinEntry = false
        showPassphraseEntry = false
        showConfirmOnDevice = false
        showWalletModeChooser = false
        uiHandler.setWalletMode(.standard)
        walletMode = .standard
    }

    // MARK: - Manager Setup

    /// Set up subscriptions and start BLE stack (synchronous, non-blocking).
    /// Called from TrezorRootView's .task to prepare the UI layer.
    func setup() {
        guard !hasSetupSubscriptions else { return }
        if !transport.isBridgeEnabled {
            // Start BLE stack early so bluetoothState is updated by the time
            // TrezorDeviceListView renders (the delegate callback fires async).
            TrezorBLEManager.shared.ensureStarted()
        }
        setupCallbackSubscriptions()
        hasSetupSubscriptions = true
    }

    /// Initialize the Trezor FFI manager (async, may be slow).
    /// Called lazily before first scan/connect.
    func initialize() async {
        setup()

        guard !isInitialized else { return }

        do {
            try await trezorService.initialize()
            isInitialized = true
            error = nil
            trezorLog("TrezorViewModel initialized")
        } catch {
            self.error = errorMessage(from: error)
            trezorLog("Failed to initialize Trezor: \(error)", level: "error")
        }
    }

    // MARK: - Device Scanning

    /// Start scanning for Trezor devices
    /// - Parameter clearExisting: Whether to clear existing device list before scanning
    func startScan(clearExisting: Bool = true) async {
        if !isInitialized {
            await initialize()
        }

        isScanning = true
        error = nil

        if clearExisting {
            devices = []
        }

        if !transport.isBridgeEnabled {
            // Start BLE scanning
            transport.startBLEScanning()

            // Wait for BLE to discover devices (like Android's 3-second scan)
            // This ensures devices are found before we call the FFI enumerate
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

            // Stop BLE scanning before calling FFI to prevent race conditions
            transport.stopBLEScanning()
        }

        do {
            // Trigger FFI scan which will use our transport callbacks
            let foundDevices = try await trezorService.scan()

            // Deduplicate by path (in case of duplicate scan results)
            var seenPaths = Set<String>()
            let uniqueDevices = foundDevices.filter { device in
                if seenPaths.contains(device.path) {
                    return false
                }
                seenPaths.insert(device.path)
                return true
            }

            devices = uniqueDevices
            trezorLog("Found \(uniqueDevices.count) Trezor devices (filtered from \(foundDevices.count))")
        } catch {
            self.error = errorMessage(from: error)
            trezorLog("Scan failed: \(error)", level: "error")
        }

        isScanning = false
    }

    /// Stop scanning for devices
    func stopScan() {
        transport.stopBLEScanning()
        isScanning = false
    }

    // MARK: - Connection

    /// Connect to a device
    func connect(device: TrezorDeviceInfo) async {
        error = nil
        suppressNextAutoReconnect = false

        // Explicit user-initiated connect always opens the standard wallet — a
        // passphrase/on-device selection left over from a previously connected device
        // must not silently apply to a newly selected one.
        uiHandler.setWalletMode(.standard)
        walletMode = .standard

        trezorLog("=== Connecting to device: \(device.path) ===")

        do {
            let features = try await trezorService.connect(deviceId: device.path, selection: uiHandler.currentSelection())
            connectedDevice = device
            deviceFeatures = features
            showConfirmOnDevice = false

            await saveCurrentDeviceAsKnown()
            trezorLog("Connected to Trezor: \(device.path)")
        } catch {
            let errorMsg = errorMessage(from: error)
            self.error = errorMsg
            showConfirmOnDevice = false
            trezorLog("Connection failed: \(error)", level: "error")
        }
    }

    /// Disconnect from current device
    func disconnect() async {
        guard connectedDevice != nil else { return }
        suppressNextAutoReconnect = true

        // NOTE: the event watcher is intentionally NOT stopped here. It subscribes to
        // Electrum directly and does not require a connected device, so it survives a
        // disconnect and remains controllable from the device-list screen. It is only
        // torn down on a network switch (different Electrum server) or via stopWatcher().

        do {
            try await trezorService.disconnect()
            // Clear connection state but preserve device list for quick reconnection
            clearDisconnectedDeviceState()

            trezorLog("Disconnected from Trezor")
        } catch {
            // Even if disconnect fails, clear local state
            clearDisconnectedDeviceState(errorMessage: errorMessage(from: error))
            trezorLog("Disconnect failed: \(error)", level: "error")
        }
    }

    /// Check if currently connected
    var isConnected: Bool {
        connectedDevice != nil
    }

    // MARK: - Address Operations

    /// Get address from connected device
    /// - Parameter showOnDevice: Whether to display address on Trezor screen
    func getAddress(showOnDevice: Bool = true) async {
        guard isConnected else {
            error = "Not connected to a Trezor"
            return
        }

        isOperating = true
        error = nil

        do {
            let params = TrezorGetAddressParams(
                path: derivationPath,
                coin: selectedNetwork,
                showOnTrezor: showOnDevice,
                scriptType: selectedScriptType
            )

            let response = try await trezorService.getAddress(params: params)
            generatedAddress = response.address
            showConfirmOnDevice = false

            trezorLog("Generated address: \(response.address)")
        } catch {
            self.error = errorMessage(from: error)
            showConfirmOnDevice = false
            trezorLog("Get address failed: \(error)", level: "error")
        }

        isOperating = false
    }

    // MARK: - Message Signing

    /// Sign a message with the connected device
    func signMessage() async {
        guard isConnected else {
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
                coin: selectedNetwork
            )

            let response = try await trezorService.signMessage(params: params)
            signedMessage = response
            showConfirmOnDevice = false

            trezorLog("Message signed successfully")
        } catch {
            self.error = errorMessage(from: error)
            showConfirmOnDevice = false
            trezorLog("Sign message failed: \(error)", level: "error")
        }

        isOperating = false
    }

    /// Verify a signed message
    func verifyMessage(address: String, signature: String, message: String) async -> Bool {
        guard isConnected else {
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
                coin: selectedNetwork
            )

            let isValid = try await trezorService.verifyMessage(params: params)
            showConfirmOnDevice = false

            trezorLog("Message verification result: \(isValid)")

            isOperating = false
            return isValid
        } catch {
            self.error = errorMessage(from: error)
            showConfirmOnDevice = false
            trezorLog("Verify message failed: \(error)", level: "error")

            isOperating = false
            return false
        }
    }

    // MARK: - UI Callbacks

    /// Submit PIN from UI
    func submitPin(_ pin: String) {
        showPinEntry = false
        uiHandler.submitPin(pin)
    }

    /// Cancel PIN entry
    func cancelPin() {
        showPinEntry = false
        uiHandler.cancelPin()
    }

    /// Submit a host-entered passphrase from the UI — opens the corresponding hidden
    /// wallet (or the standard wallet when empty) by resetting the session.
    func submitPassphrase(_ passphrase: String) async {
        showPassphraseEntry = false
        showConfirmOnDevice = false
        await setWalletMode(passphrase.isEmpty ? .standard : .passphraseHost, passphrase: passphrase)
    }

    /// Cancel passphrase entry
    func cancelPassphrase() {
        showPassphraseEntry = false
        showConfirmOnDevice = false
        showWalletModeChooser = false
    }

    // MARK: - Wallet Mode Selection

    /// User tapped the "Standard" wallet option in the selector.
    func selectStandardWallet() async {
        guard walletMode != .standard else { return }
        await setWalletMode(.standard)
    }

    /// User tapped the "Passphrase" wallet option. On a capable device this offers a
    /// choice of where to enter the passphrase; otherwise it goes straight to host entry.
    func requestPassphraseWallet() {
        if passphraseEntryCapable {
            showWalletModeChooser = true
        } else {
            showPassphraseEntry = true
        }
    }

    /// Wallet-mode chooser: user chose to enter the passphrase on this phone.
    func choosePhonePassphraseEntry() {
        showWalletModeChooser = false
        showPassphraseEntry = true
    }

    /// Wallet-mode chooser: user chose to enter the passphrase on the Trezor.
    func chooseDevicePassphraseEntry() async {
        showWalletModeChooser = false
        await setWalletMode(.passphraseDevice)
    }

    /// Switch between wallet modes. The Trezor caches the passphrase for the whole
    /// session, so switching requires a fresh session: this records the desired mode,
    /// then disconnects and reconnects by path. Mirrors bitkit-android's setWalletMode.
    func setWalletMode(_ mode: TrezorWalletMode, passphrase: String = "") async {
        guard let device = connectedDevice else {
            error = "Not connected to a Trezor"
            return
        }

        isOperating = true
        error = nil
        trezorLog("=== Switching wallet mode to \(mode); resetting session ===")

        // Reset the session. We call the service directly (not the VM's disconnect())
        // so connectedDevice/deviceFeatures stay populated for the reconnect.
        do {
            try await trezorService.disconnect()
        } catch {
            trezorLog("Disconnect before wallet-mode switch failed: \(error)", level: "warn")
        }

        // Results derived from the previous wallet are no longer valid once the
        // session has been reset for a different wallet mode.
        clearWalletDerivedState()

        // Brief settle delay before reconnecting (matches Android's reconnect delay).
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Record the selection AFTER the disconnect so it survives into the new session.
        // THP reads it via currentSelection() to bind the passphrase at session creation;
        // non-THP devices re-request it mid-operation and are answered from the same value.
        uiHandler.setWalletMode(mode, hostPassphrase: passphrase)
        walletMode = mode

        do {
            let features = try await trezorService.connect(deviceId: device.path, selection: uiHandler.currentSelection())
            connectedDevice = device
            deviceFeatures = features
            showConfirmOnDevice = false
            trezorLog("Reconnected with wallet mode \(mode)")
        } catch {
            clearDisconnectedDeviceState(errorMessage: errorMessage(from: error))
            trezorLog("Reconnect after wallet-mode switch failed: \(error)", level: "error")
        }

        isOperating = false
    }

    /// Submit pairing code from UI
    func submitPairingCode(_ code: String) {
        showPairingCode = false
        transport.submitPairingCode(code)
    }

    /// Cancel pairing code entry
    func cancelPairingCode() {
        showPairingCode = false
        transport.cancelPairingCode()
    }

    /// Dismiss confirm on device overlay
    func dismissConfirmOnDevice() {
        showConfirmOnDevice = false
        confirmMessage = ""
    }

    // MARK: - Known Devices

    /// Load known devices from storage
    func loadKnownDevices() {
        knownDevices = TrezorKnownDeviceStorage.loadAll()
    }

    /// Save the currently connected device as a known device, capturing its account
    /// xpubs so watch-only balances/activity stay available while disconnected.
    func saveCurrentDeviceAsKnown() async {
        guard let device = connectedDevice else { return }
        let previous = TrezorKnownDeviceStorage.loadAll().first { $0.id == device.id }
        let fetched = await fetchAccountXpubs()
        let mergedXpubs = (previous?.xpubs ?? [:]).merging(fetched) { _, new in new }
        let known = TrezorKnownDevice(
            id: device.id,
            name: device.name ?? "Trezor",
            path: device.path,
            transportType: device.transportType == .bluetooth ? "bluetooth" : "usb",
            label: device.label ?? deviceFeatures?.label,
            model: device.model ?? deviceFeatures?.model,
            lastConnectedAt: Date(),
            xpubs: mergedXpubs
        )
        TrezorKnownDeviceStorage.save(known)
        loadKnownDevices()
        trezorLog("Saved known device: \(known.name) with \(mergedXpubs.count) xpubs")
    }

    /// Read the account-level xpub for every address type from the connected device.
    /// Per-type failures are swallowed so a single missing type doesn't block the rest.
    func fetchAccountXpubs() async -> [String: String] {
        var result: [String: String] = [:]
        for addressType in HwAddressType.allCases {
            do {
                let params = TrezorGetPublicKeyParams(
                    path: addressType.accountDerivationPath(network: selectedNetwork),
                    coin: selectedNetwork,
                    showOnTrezor: false
                )
                let response = try await trezorService.getPublicKey(params: params)
                result[addressType.settingsString] = response.xpub
            } catch {
                trezorLog("Could not read xpub for '\(addressType.settingsString)': \(error)", level: "warn")
            }
        }
        return result
    }

    /// Forget a known device — removes from storage and clears credentials
    func forgetDevice(id: String) async {
        // Find the device to get its path for credential clearing
        if let device = knownDevices.first(where: { $0.id == id }) {
            do {
                try await trezorService.clearCredentials(deviceId: device.path)
            } catch {
                trezorLog("Failed to clear credentials for forgotten device: \(error)", level: "warn")
            }
            TrezorCredentialStorage.delete(deviceId: device.path)
        }
        TrezorKnownDeviceStorage.remove(id: id)
        loadKnownDevices()
        trezorLog("Forgot device: \(id)")
    }

    // MARK: - Auto-Reconnect

    /// Automatically scan and reconnect to the first matching known device
    func autoReconnect() async {
        guard !knownDevices.isEmpty else { return }
        guard !isAutoReconnecting else { return }
        if suppressNextAutoReconnect {
            suppressNextAutoReconnect = false
            trezorLog("Auto-reconnect: skipped after manual disconnect")
            return
        }

        isAutoReconnecting = true
        autoReconnectStatus = "Scanning for known devices..."
        trezorLog("Auto-reconnect: starting scan")

        await startScan(clearExisting: true)

        // Find the first scanned device that matches a known device
        let knownIds = Set(knownDevices.map(\.id))
        if let match = devices.first(where: { knownIds.contains($0.id) }) {
            autoReconnectStatus = "Connecting to \(match.label ?? match.name ?? "Trezor")..."
            trezorLog("Auto-reconnect: found known device \(match.path)")
            await connect(device: match)
        } else {
            autoReconnectStatus = nil
            trezorLog("Auto-reconnect: no known devices found nearby")
        }

        isAutoReconnecting = false
        autoReconnectStatus = nil
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
        guard isConnected else {
            error = "Not connected to a Trezor"
            return
        }

        isOperating = true
        error = nil

        do {
            let params = TrezorGetPublicKeyParams(
                path: publicKeyPath,
                coin: selectedNetwork,
                showOnTrezor: showOnDevice
            )

            let response = try await trezorService.getPublicKey(params: params)
            xpub = response.xpub
            publicKeyHex = response.publicKey
            showConfirmOnDevice = false

            trezorLog("Got public key for path: \(publicKeyPath)")
        } catch {
            self.error = errorMessage(from: error)
            showConfirmOnDevice = false
            trezorLog("Get public key failed: \(error)", level: "error")
        }

        isOperating = false
    }

    // MARK: - Transaction Signing

    /// Sign a Bitcoin transaction
    func signTx(params: TrezorSignTxParams) async -> TrezorSignedTx? {
        guard isConnected else {
            error = "Not connected to a Trezor"
            return nil
        }

        isOperating = true
        error = nil

        do {
            let result = try await trezorService.signTx(params: params)
            showConfirmOnDevice = false
            trezorLog("Transaction signed successfully")
            isOperating = false
            return result
        } catch {
            self.error = errorMessage(from: error)
            showConfirmOnDevice = false
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
        guard isConnected else {
            error = "Not connected to a Trezor"
            return nil
        }

        isOperating = true
        error = nil

        do {
            let result = try await trezorService.signTxFromPsbt(
                psbtBase64: psbtBase64,
                network: selectedNetwork
            )
            showConfirmOnDevice = false
            trezorLog("PSBT signed successfully")
            isOperating = false
            return result
        } catch {
            self.error = errorMessage(from: error)
            showConfirmOnDevice = false
            trezorLog("Sign PSBT failed: \(error)", level: "error")
            isOperating = false
            return nil
        }
    }

    // MARK: - Device Fingerprint

    /// Get the device's master root fingerprint
    func getDeviceFingerprint() async {
        guard isConnected else {
            error = "Not connected to a Trezor"
            return
        }

        isOperating = true
        error = nil

        do {
            let fingerprint = try await trezorService.getDeviceFingerprint()
            deviceFingerprint = fingerprint
            trezorLog("Device fingerprint: \(fingerprint)")
        } catch {
            self.error = errorMessage(from: error)
            trezorLog("Get fingerprint failed: \(error)", level: "error")
        }

        isOperating = false
    }

    // MARK: - Electrum URL Helpers

    /// Get the Electrum server URL for a specific network (hardcoded per-network URLs)
    static func electrumUrlForNetwork(_ network: TrezorCoinType) -> String {
        if network == .regtest, let trezorElectrumUrl = Env.trezorElectrumUrl {
            return trezorElectrumUrl
        }

        switch network {
        case .bitcoin:
            return "ssl://bitkit.to:9999"
        case .testnet, .signet:
            return "ssl://electrum.blockstream.info:60002"
        case .regtest:
            return "ssl://electrs.bitkit.stag0.blocktank.to:9999"
        }
    }

    /// Get the current Electrum server URL from configuration (uses app's configured server)
    static func getElectrumUrl() -> String {
        let configService = ElectrumConfigService()
        let server = configService.getCurrentServer()
        return server.fullUrl.isEmpty ? Env.electrumServerUrl : server.fullUrl
    }

    // MARK: - Network Switching

    /// Switch the dashboard's network independently of the app's global network
    func setSelectedNetwork(_ network: TrezorCoinType) {
        guard network != selectedNetwork else { return }
        selectedNetwork = network

        // A running watcher is bound to the previous network's Electrum server.
        stopWatcher()

        // Reset derivation paths with the new coin type
        derivationPath = "m/84'/\(coinTypeComponent)/0'/0/0"
        publicKeyPath = "m/84'/\(coinTypeComponent)/0'"
        messageSigningPath = "m/84'/\(coinTypeComponent)/0'/0/0"
        addressIndex = 0

        // Clear results from previous network
        generatedAddress = nil
        xpub = nil
        publicKeyHex = nil
        signedMessage = nil
        error = nil
        accountResult = nil
        addressResult = nil
        lookupError = nil
        resetSendFlow()

        trezorLog("Switched dashboard network to \(network)")
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

        let electrumUrl = Self.electrumUrlForNetwork(selectedNetwork)

        do {
            switch Self.detectInputType(trimmedInput) {
            case .extendedKey:
                accountResult = try await trezorService.getAccountInfo(
                    extendedKey: trimmedInput,
                    electrumUrl: electrumUrl,
                    network: selectedNetwork,
                    scriptType: onchainAccountTypeSelection.accountType
                )
            case .address:
                addressResult = try await trezorService.getAddressInfo(
                    address: trimmedInput,
                    electrumUrl: electrumUrl,
                    network: selectedNetwork
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

        let electrumUrl = Self.electrumUrlForNetwork(selectedNetwork)

        do {
            txHistoryResult = try await trezorService.getTransactionHistory(
                extendedKey: trimmedKey,
                electrumUrl: electrumUrl,
                network: selectedNetwork,
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

        let electrumUrl = Self.electrumUrlForNetwork(selectedNetwork)

        do {
            txDetailResult = try await trezorService.getTransactionDetail(
                extendedKey: trimmedKey,
                electrumUrl: electrumUrl,
                txid: trimmedTxid,
                network: selectedNetwork,
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
        if deviceFingerprint == nil {
            do {
                deviceFingerprint = try await trezorService.getDeviceFingerprint()
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

        let electrumUrl = Self.electrumUrlForNetwork(selectedNetwork)
        let network = toNetwork(selectedNetwork)

        let wallet = WalletParams(
            extendedKey: extendedKey,
            electrumUrl: electrumUrl,
            fingerprint: deviceFingerprint,
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
            let results = try await trezorService.composeTransaction(params: params)
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

        guard isConnected else {
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
                network: selectedNetwork
            )
            showConfirmOnDevice = false

            trezorLog("=== signComposedTx SUCCESS ===")
            trezorLog("signatures=\(signedTx.signatures.count), txid=\(signedTx.txid ?? "nil"), rawTxLen=\(signedTx.serializedTx.count)")

            signedTxResult = signedTx
            sendStep = .signed
        } catch {
            showConfirmOnDevice = false
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

        let electrumUrl = Self.electrumUrlForNetwork(selectedNetwork)

        do {
            let txid = try await trezorService.broadcastRawTx(serializedTx: rawTx, electrumUrl: electrumUrl)
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

    /// Convert TrezorCoinType to the Network enum used by onchain FFI functions
    private func toNetwork(_ coin: TrezorCoinType) -> Network? {
        switch coin {
        case .bitcoin: return .bitcoin
        case .testnet: return .testnet
        case .signet: return .signet
        case .regtest: return .regtest
        }
    }

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

    // MARK: - Credential Management

    /// Clear stored credentials for current device
    func clearCredentials() async {
        guard let device = connectedDevice else {
            error = "No device connected"
            return
        }

        do {
            try await trezorService.clearCredentials(deviceId: device.path)
            trezorLog("Cleared credentials for \(device.path)")
        } catch {
            self.error = errorMessage(from: error)
            trezorLog("Failed to clear credentials: \(error)", level: "error")
        }
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
        let network = selectedNetwork
        let accountType = onchainAccountTypeSelection.accountType

        let params = WatcherParams(
            watcherId: watcherId,
            extendedKey: key,
            electrumUrl: Self.electrumUrlForNetwork(network),
            network: toNetwork(network),
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

            if selectedNetwork != network {
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
        showPinEntry = true
    }

    func testShowPassphrasePrompt() {
        guard Env.isTrezorEmulatorTesting else { return }
        showPassphraseEntry = true
    }

    func testShowPairingCodePrompt() {
        guard Env.isTrezorEmulatorTesting else { return }
        showPairingCode = true
    }

    func testShowConfirmOnDevicePrompt() {
        guard Env.isTrezorEmulatorTesting else { return }
        confirmMessage = "Confirm test action on your Trezor"
        showConfirmOnDevice = true
    }
}
