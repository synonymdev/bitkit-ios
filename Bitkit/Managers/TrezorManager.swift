import BitkitCore
import Combine
import CoreBluetooth
import Foundation

/// Device/connection orchestration and pairing/PIN/passphrase coordination for the Trezor
/// hardware wallet. Owns the device list, connect/disconnect lifecycle, known-device storage,
/// auto-reconnect, network selection, and the UI dialog state for PIN/passphrase/pairing flows.
///
/// Split out of `TrezorViewModel` so production managers (e.g. `HwWalletManager`) depend on a
/// manager rather than a dev-screen ViewModel, keeping dependencies pointing Manager→Manager→Service.
@Observable
@MainActor
final class TrezorManager {
    // MARK: - Network Configuration

    /// Independent of the app's global network — scoped to the Trezor dashboard.
    var selectedNetwork: TrezorCoinType

    /// BIP44 coin type component based on the dashboard's selected network: "0'" for mainnet, "1'" for test networks
    var coinTypeComponent: String {
        selectedNetwork == .bitcoin ? "0'" : "1'"
    }

    // MARK: - Connection State

    private var isInitialized: Bool = false

    var isScanning: Bool = false

    var devices: [TrezorDeviceInfo] = []

    var connectedDevice: TrezorDeviceInfo? {
        didSet { devicesRevision &+= 1 }
    }

    /// Bumped whenever the device list or connection state changes, so observers (e.g. the
    /// composition root that feeds `HwWalletManager`) can react without those types coupling.
    private(set) var devicesRevision: Int = 0

    var deviceFeatures: TrezorFeatures?

    var deviceFingerprint: String?

    var error: String?

    // MARK: - UI Dialog State

    var showPinEntry: Bool = false

    var showPassphraseEntry: Bool = false

    var showPairingCode: Bool = false

    var showConfirmOnDevice: Bool = false

    var confirmMessage: String = ""

    /// Only presented for devices that report on-device passphrase entry capability.
    var showWalletModeChooser: Bool = false

    // MARK: - Wallet Mode State

    /// The binding to the device session is applied via setWalletMode (disconnect/reconnect),
    /// not by mutating this property directly.
    var walletMode: TrezorWalletMode = .standard

    var passphraseEntryCapable: Bool {
        deviceFeatures?.passphraseEntryCapable == true
    }

    // MARK: - Known Devices & Auto-Reconnect

    var knownDevices: [TrezorKnownDevice] = [] {
        didSet { devicesRevision &+= 1 }
    }

    var isAutoReconnecting: Bool = false

    var autoReconnectStatus: String?

    /// Prevents a user-initiated disconnect from immediately reconnecting
    /// when the disconnected device list appears.
    private var suppressNextAutoReconnect = false

    // MARK: - Bluetooth State

    /// Reads directly from BLEManager (@Observable chaining).
    var bluetoothState: CBManagerState {
        TrezorBLEManager.shared.bluetoothState
    }

    var isBridgeModeEnabled: Bool {
        transport.isBridgeEnabled
    }

    // MARK: - Private Properties

    private let trezorService = TrezorService.shared
    private let transport = TrezorTransport.shared
    private let uiHandler = TrezorUiHandler.shared
    private var cancellables = Set<AnyCancellable>()
    private var hasSetupSubscriptions = false

    // MARK: - Initialization

    init() {
        selectedNetwork = OnChainHwService.appDefaultCoinType
        // Callback subscriptions are deferred to setup() to avoid
        // triggering BLE stack and Combine overhead at app launch.
    }

    private func setupCallbackSubscriptions() {
        transport.needsPairingCodePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.showPairingCode = true
            }
            .store(in: &cancellables)

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

    private func trezorLog(_ message: String, level: String = "info") {
        switch level {
        case "error":
            Logger.error(message, context: "TrezorManager")
        case "warn":
            Logger.warn(message, context: "TrezorManager")
        default:
            Logger.info(message, context: "TrezorManager")
        }
        TrezorDebugLog.shared.log(message)
    }

    // MARK: - State Reset Helpers

    func clearWalletDerivedState() {
        deviceFingerprint = nil
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

    /// Synchronous, non-blocking. Called from TrezorRootView's .task to prepare the UI layer.
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

    /// Async and potentially slow. Called lazily before first scan/connect.
    func initialize() async {
        setup()

        guard !isInitialized else { return }

        do {
            try await trezorService.initialize()
            isInitialized = true
            error = nil
            trezorLog("TrezorManager initialized")
        } catch {
            self.error = errorMessage(from: error)
            trezorLog("Failed to initialize Trezor: \(error)", level: "error")
        }
    }

    // MARK: - Device Scanning

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
            transport.startBLEScanning()

            // Wait for BLE to discover devices (like Android's 3-second scan) before
            // calling the FFI enumerate, then stop scanning to prevent race conditions.
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            transport.stopBLEScanning()
        }

        do {
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

    func stopScan() {
        transport.stopBLEScanning()
        isScanning = false
    }

    // MARK: - Connection

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

    var isConnected: Bool {
        connectedDevice != nil
    }

    // MARK: - UI Callbacks

    func submitPin(_ pin: String) {
        showPinEntry = false
        uiHandler.submitPin(pin)
    }

    func cancelPin() {
        showPinEntry = false
        uiHandler.cancelPin()
    }

    /// Opens the corresponding hidden wallet (or the standard wallet when empty) by resetting the session.
    func submitPassphrase(_ passphrase: String) async {
        showPassphraseEntry = false
        showConfirmOnDevice = false
        await setWalletMode(passphrase.isEmpty ? .standard : .passphraseHost, passphrase: passphrase)
    }

    func cancelPassphrase() {
        showPassphraseEntry = false
        showConfirmOnDevice = false
        showWalletModeChooser = false
    }

    // MARK: - Wallet Mode Selection

    func selectStandardWallet() async {
        guard walletMode != .standard else { return }
        await setWalletMode(.standard)
    }

    /// On a capable device this offers a choice of where to enter the passphrase;
    /// otherwise it goes straight to host entry.
    func requestPassphraseWallet() {
        if passphraseEntryCapable {
            showWalletModeChooser = true
        } else {
            showPassphraseEntry = true
        }
    }

    func choosePhonePassphraseEntry() {
        showWalletModeChooser = false
        showPassphraseEntry = true
    }

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

        error = nil
        trezorLog("=== Switching wallet mode to \(mode); resetting session ===")

        // Reset the session. We call the service directly (not the manager's disconnect())
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
    }

    func submitPairingCode(_ code: String) {
        showPairingCode = false
        transport.submitPairingCode(code)
    }

    func cancelPairingCode() {
        showPairingCode = false
        transport.cancelPairingCode()
    }

    func dismissConfirmOnDevice() {
        showConfirmOnDevice = false
        confirmMessage = ""
    }

    // MARK: - Known Devices

    func loadKnownDevices() {
        knownDevices = TrezorKnownDeviceStorage.loadAll()
    }

    /// Captures the connected device's account xpubs so watch-only balances/activity
    /// stay available while disconnected.
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

    func forgetDevice(id: String) async {
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

    func autoReconnect() async {
        guard !knownDevices.isEmpty else { return }
        guard !isAutoReconnecting else { return }
        guard connectedDevice == nil else {
            trezorLog("Auto-reconnect: skipped, device already connected")
            return
        }
        if suppressNextAutoReconnect {
            suppressNextAutoReconnect = false
            trezorLog("Auto-reconnect: skipped after manual disconnect")
            return
        }

        isAutoReconnecting = true
        autoReconnectStatus = "Scanning for known devices..."
        trezorLog("Auto-reconnect: starting scan")

        await startScan(clearExisting: true)

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

    // MARK: - Network Switching

    /// Switches the dashboard's network independently of the app's global network.
    func setSelectedNetwork(_ network: TrezorCoinType) {
        guard network != selectedNetwork else { return }
        selectedNetwork = network
        error = nil
        trezorLog("Switched dashboard network to \(network)")
    }

    // MARK: - Credential Management

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

    // MARK: - Error Handling

    private func errorMessage(from error: Error) -> String {
        // ServiceQueue wraps all errors in AppError, so extract the original message
        if let appError = error as? AppError {
            // debugMessage contains the original error's localizedDescription
            if let debugMessage = appError.debugMessage, !debugMessage.isEmpty {
                return formatTrezorErrorMessage(debugMessage)
            }
            // Fall through to the app error message if no debug info
            return appError.message
        }

        if let trezorError = error as? TrezorError {
            return trezorError.localizedDescription
        }

        if let bleError = error as? TrezorBLEError {
            return bleError.localizedDescription
        }

        if let transportError = error as? TrezorTransportError {
            return transportError.localizedDescription
        }

        let description = error.localizedDescription
        if description == "The operation couldn't be completed." || description.isEmpty {
            return "Connection failed. Please ensure your Trezor is in pairing mode and try again."
        }
        return description
    }

    private func formatTrezorErrorMessage(_ message: String) -> String {
        let cleanedMessage = message
            .replacingOccurrences(of: "Transport error: ", with: "")
            .replacingOccurrences(of: "Connection error: ", with: "")
            .replacingOccurrences(of: "Protocol error: ", with: "")
            .replacingOccurrences(of: "Device error: ", with: "")
            .replacingOccurrences(of: "Session error: ", with: "")
            .replacingOccurrences(of: "IO error: ", with: "")

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

        return cleanedMessage
    }
}
