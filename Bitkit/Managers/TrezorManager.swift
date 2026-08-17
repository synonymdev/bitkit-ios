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

    /// Wallet identity the live session was opened for. A device can hold a standard wallet plus
    /// several passphrase wallets, and only the one the session opened can sign. Nil while no
    /// session is open, or before its accounts could be read.
    private(set) var connectedWalletId: String? {
        didSet { devicesRevision &+= 1 }
    }

    /// Set while a session is deliberately being torn down and reopened for a chosen wallet, so a
    /// background reconnect can't race in and open the standard wallet under a hidden selection.
    private var isOpeningSession = false

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

    private(set) var pairingCodeRequestID: Int = 0

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
                self?.pairingCodeRequestID &+= 1
            }
            .store(in: &cancellables)

        uiHandler.needsPinPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.showPinEntry = true
            }
            .store(in: &cancellables)

        // A spontaneous BLE drop (device out of range or phone Bluetooth turned off)
        // must clear the live session.
        transport.externalDisconnectPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                guard let self, connectedDevice?.path == path else { return }
                trezorLog("External disconnect for \(path); clearing session")
                clearDisconnectedDeviceState()
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
    }

    // MARK: - State Reset Helpers

    func clearWalletDerivedState() {
        deviceFingerprint = nil
    }

    func clearDisconnectedDeviceState(errorMessage: String? = nil) {
        connectedDevice = nil
        connectedWalletId = nil
        deviceFeatures = nil
        clearWalletDerivedState()
        error = errorMessage
        showPinEntry = false
        showPassphraseEntry = false
        showConfirmOnDevice = false
        showPairingCode = false
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

    /// Opens a session on `device`. `mode` is the wallet selection to open it with; passing nil keeps
    /// whatever selection is already recorded on the handler, which is how a passphrase wallet is
    /// reopened. Every other caller passes `.standard` explicitly, because a passphrase selection
    /// left over from a previously connected device must never silently apply to a newly picked one.
    func connect(device: TrezorDeviceInfo, mode: TrezorWalletMode? = .standard) async {
        error = nil
        suppressNextAutoReconnect = false
        showPairingCode = false

        if let mode {
            uiHandler.setWalletMode(mode)
            walletMode = mode
        }

        trezorLog("=== Connecting to device: \(device.path) ===")

        do {
            let features = try await trezorService.connect(deviceId: device.path, selection: uiHandler.currentSelection())

            if Task.isCancelled {
                try? await trezorService.disconnect()
                trezorLog("Connect cancelled before pairing; disconnected \(device.path)")
                return
            }

            connectedDevice = device
            deviceFeatures = features
            showConfirmOnDevice = false
            // Unresolved until this session's accounts are read: reporting the previous session's
            // identity would mark the wrong wallet as the one that can sign.
            connectedWalletId = nil

            let savedComplete = await saveCurrentDeviceAsKnown()
            if savedComplete {
                trezorLog("Connected to Trezor: \(device.path)")
            } else {
                trezorLog("Connected to Trezor: \(device.path) with incomplete account-key capture", level: "warn")
            }
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

    /// Switch the live session between wallet modes, surfacing failures on `error` for the dev
    /// dashboard. Requires a connected device; `connectWithWalletMode` is the throwing variant that
    /// also works from cold.
    func setWalletMode(_ mode: TrezorWalletMode, passphrase: String = "") async {
        guard let device = connectedDevice else {
            error = "Not connected to a Trezor"
            return
        }

        do {
            _ = try await connectWithWalletMode(deviceId: device.id, mode: mode, passphrase: passphrase)
        } catch {
            trezorLog("Reconnect after wallet-mode switch failed: \(error)", level: "error")
        }
    }

    /// Opens `deviceId` with an explicit wallet selection, whether or not a session is live.
    ///
    /// The Trezor binds a passphrase when the session is created and caches it for the session's
    /// lifetime, so an existing session is torn down first; with none — the app was restarted, or a
    /// wrong passphrase closed it — the device is reconnected from its stored entry instead.
    @discardableResult
    func connectWithWalletMode(
        deviceId: String,
        mode: TrezorWalletMode,
        passphrase: String = ""
    ) async throws -> TrezorFeatures {
        isOpeningSession = true
        defer { isOpeningSession = false }

        error = nil
        let hadSession = connectedDevice != nil
        trezorLog("=== Opening \(mode) session for \(deviceId); hadSession=\(hadSession) ===")

        if hadSession {
            // The service is called directly (not the manager's disconnect()) so
            // connectedDevice/deviceFeatures stay populated for the reconnect.
            do {
                try await trezorService.disconnect()
            } catch {
                trezorLog("Disconnect before wallet-mode switch failed: \(error)", level: "warn")
            }
            // Results derived from the previous wallet no longer hold once the session is reset.
            clearWalletDerivedState()
            // Brief settle delay before reconnecting (matches Android's reconnect delay).
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // Record the selection last: disconnect resets it. THP reads it via currentSelection() to
        // bind the passphrase at session creation; non-THP devices re-request it mid-operation and
        // are answered from the same value.
        uiHandler.setWalletMode(mode, hostPassphrase: passphrase)
        walletMode = mode

        // Only the device just disconnected can be reopened from its cached handle, and only when it
        // is the one being asked for: a scan right after a disconnect usually finds nothing, whereas
        // that handle still works. Reaching for whatever held the session would open a *different*
        // device with the selection recorded above — handing it a passphrase meant for another one.
        // Any other device has no such handle, so it takes the known-device path with its scan and
        // bluetooth fallback.
        if hadSession, let reopening = connectedDevice, reopening.id == deviceId {
            await connect(device: reopening, mode: nil)
        } else {
            try await reconnectKnownDevice(deviceId: deviceId, mode: nil)
        }

        // `connect(device:)` reports failure on `error` and leaves the previous session's device and
        // features in place, so identity alone would accept a failed reopen and let the caller read
        // the wallet the old session had opened. The live session is the only proof.
        let isLive = await trezorService.isConnected()
        guard connectedDevice?.id == deviceId, isLive, let features = deviceFeatures else {
            let message = error ?? "Failed to open wallet on '\(deviceId)'"
            clearDisconnectedDeviceState(errorMessage: message)
            throw AppError(message: "Reconnect Hardware Device", debugMessage: message)
        }
        trezorLog("Opened \(mode) session for \(deviceId)")
        return features
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

    /// Display name for the currently connected device, applying any Bitkit-side custom rename (from
    /// the stored known-device record) over the device's own label/model — mirrors how watch-only
    /// tiles resolve names, so a rename shows on the connected-device screen too.
    var connectedDeviceDisplayName: String? {
        guard let device = connectedDevice else { return nil }
        let customLabel = knownDevices.first { $0.id == device.id }?.customLabel
        return resolveHwWalletName(
            label: device.label ?? deviceFeatures?.label,
            model: device.model ?? deviceFeatures?.model,
            customLabel: customLabel
        )
    }

    /// Set the Bitkit-side custom name for a paired device. The name is trimmed and capped; an empty
    /// result clears the custom name (falling back to the device label/model). Applies to every stored
    /// entry sharing the target's xpub set so the same device renamed over either transport stays
    /// consistent, then reloads so the snapshot re-pushes and `HwWallet.name` updates.
    func renameDevice(id: String, newName: String) {
        let devices = TrezorKnownDeviceStorage.loadAll()
        guard let target = devices.first(where: { $0.id == id }) else { return }

        applyCustomLabel(newName, to: devices) { device in
            device.id == id || (!target.xpubs.isEmpty && device.xpubs == target.xpubs)
        }
        trezorLog("Renamed device \(id)")
    }

    /// Set the Bitkit-side custom name for one wallet identity. The label belongs to the wallet, not
    /// to the device: renaming a passphrase wallet must leave its device's other wallets alone.
    func renameWallet(walletId: String, newName: String) {
        let devices = TrezorKnownDeviceStorage.loadAll()
        guard devices.contains(where: { $0.resolvedWalletId == walletId }) else { return }

        applyCustomLabel(newName, to: devices) { $0.resolvedWalletId == walletId }
        trezorLog("Renamed hardware wallet \(walletId)")
    }

    private func applyCustomLabel(
        _ newName: String,
        to devices: [TrezorKnownDevice],
        matching isTarget: (TrezorKnownDevice) -> Bool
    ) {
        let trimmed = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.deviceLabelMaxLength))
        let customLabel = trimmed.isEmpty ? nil : trimmed

        let updated = devices.map { device -> TrezorKnownDevice in
            guard isTarget(device) else { return device }
            var copy = device
            copy.customLabel = customLabel
            return copy
        }
        TrezorKnownDeviceStorage.saveAll(updated)
        loadKnownDevices()
    }

    /// Captures the connected device's account xpubs so watch-only balances/activity stay available
    /// while disconnected. The watch-only wallet id is derived from the captured xpub set, so a save
    /// is blocked only when an address type failed *transiently* (a retryable transport error) and
    /// isn't already covered by a previous capture — saving then would start a watcher under an id
    /// that changes once that type is read on a later connect. A type the device genuinely lacks
    /// (e.g. unsupported taproot) is accepted: its absence is stable across reconnects, so it neither
    /// blocks the device nor churns the id. Merging keeps previously-captured xpubs.
    /// Returns whether the device was saved.
    @discardableResult
    func saveCurrentDeviceAsKnown() async -> Bool {
        guard let device = connectedDevice else { return false }
        let stored = TrezorKnownDeviceStorage.loadAll()
        let (fetched, transientFailures) = await fetchAccountXpubs()
        // Not matched by transport id alone: a passphrase wallet is a separate identity on the same
        // device, so that would overwrite another identity or blend two identities' xpubs into one
        // record. Shared key material is the identity.
        let previous = TrezorKnownDeviceMatching.previous(in: stored, deviceId: device.id, fetchedXpubs: fetched)
        let mergedXpubs = (previous?.xpubs ?? [:]).merging(fetched) { _, new in new }

        guard !mergedXpubs.isEmpty else {
            trezorLog("No account xpubs could be read from device; not saving", level: "warn")
            error = "Couldn't read any account keys from your Trezor. Please reconnect to try again."
            return false
        }

        let retryableGaps = transientFailures.filter { mergedXpubs[$0.stringValue] == nil }
        guard retryableGaps.isEmpty else {
            let names = retryableGaps.map(\.localizedTitle).sorted().joined(separator: ", ")
            trezorLog("Incomplete xpub capture (transient failures: \(names)); not saving partial device", level: "warn")
            error = "Couldn't read all account keys from your Trezor (\(names)). Please reconnect to try again."
            return false
        }

        // The label belongs to the wallet, not to the transport it happens to be reached over, so a
        // wallet showing up on a new path keeps the name the user gave it.
        let identityKey = TrezorKnownDevice.walletKey(for: mergedXpubs, fallback: device.id)
        let named = TrezorKnownDeviceMatching.named(in: stored, previous: previous, walletKey: identityKey)

        let known = TrezorKnownDevice(
            id: device.id,
            name: device.name ?? "Trezor",
            path: device.path,
            transportType: device.transportType == .bluetooth ? "bluetooth" : "usb",
            label: device.label ?? deviceFeatures?.label,
            model: device.model ?? deviceFeatures?.model,
            lastConnectedAt: Date(),
            xpubs: mergedXpubs,
            customLabel: named?.customLabel,
            walletId: resolvedWalletId(previous: previous, identityKey: identityKey, xpubs: mergedXpubs, in: stored),
            passphraseProtected: passphraseProtection(previous: previous),
            trezorDeviceId: deviceFeatures?.deviceId ?? previous?.trezorDeviceId
        )
        TrezorKnownDeviceStorage.saveAll(TrezorKnownDeviceMatching.merged(stored, with: known, refreshed: previous))
        loadKnownDevices()
        connectedWalletId = known.resolvedWalletId
        trezorLog("Saved known device: \(known.name) with \(mergedXpubs.count) xpubs")
        return true
    }

    private func resolvedWalletId(
        previous: TrezorKnownDevice?,
        identityKey: String,
        xpubs: [String: String],
        in stored: [TrezorKnownDevice]
    ) -> String? {
        if let carried = previous?.walletId ?? stored.first(where: { $0.walletKey == identityKey })?.walletId,
           !carried.isEmpty
        {
            return carried
        }
        return try? HwWalletId.derive(xpubs: xpubs)
    }

    /// The selection that derived these keys is authoritative, so a wallet wrongly marked hidden is
    /// corrected the next time it is opened rather than staying gated behind a passphrase forever.
    /// On-device entry cannot say which wallet was opened, so it keeps what the entry already knew
    /// and assumes hidden only for one it has never seen.
    private func passphraseProtection(previous: TrezorKnownDevice?) -> Bool {
        switch uiHandler.currentSelection() {
        case .standard: false
        case .hidden: true
        case .onDevice: previous?.passphraseProtected ?? true
        }
    }

    private static let maxXpubFetchAttempts = 3
    private static let xpubFetchRetryDelayNanos: UInt64 = 300_000_000
    private static let deviceLabelMaxLength = 50

    /// Markers (matched against the underlying `TrezorError` carried in the wrapped error's text)
    /// for transient transport problems worth retrying. Anything else is treated as the address
    /// type being genuinely unavailable on this device — e.g. taproot on firmware without BIP86 —
    /// which must not block the device, since that absence is stable across reconnects.
    private static let transientFailureMarkers = [
        "TransportError", "ConnectionError", "DeviceDisconnected", "Timeout", "IoError", "SessionError",
    ]

    private static func isTransientTransportFailure(_ error: Error) -> Bool {
        // A locked device is worth a bounded retry: the user unlocks and the xpub read succeeds.
        if error.isTrezorDeviceBusy() {
            return true
        }
        let text = (error as? AppError)?.debugMessage ?? "\(error)"
        return transientFailureMarkers.contains { text.contains($0) }
    }

    /// Reads one account xpub per address type. Transient transport failures (e.g. a BLE timeout
    /// under load) are retried; a permanent rejection (an unsupported address type) is not. Returns
    /// the captured xpubs and the address types that still failed *transiently* after all retries,
    /// so the caller can block a save on those while accepting a device that merely lacks a type.
    func fetchAccountXpubs() async -> (xpubs: [String: String], transientFailures: Set<AddressScriptType>) {
        let coinType = selectedNetwork == .bitcoin ? "0" : "1"
        var result: [String: String] = [:]
        var transientFailures: Set<AddressScriptType> = []
        for addressType in AddressScriptType.allAddressTypes {
            let params = TrezorGetPublicKeyParams(
                path: addressType.accountDerivationPath(coinType: coinType),
                coin: selectedNetwork,
                showOnTrezor: false
            )
            var lastError: Error?
            for attempt in 1 ... Self.maxXpubFetchAttempts {
                do {
                    result[addressType.stringValue] = try await trezorService.getPublicKey(params: params).xpub
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    trezorLog(
                        "Could not read xpub for '\(addressType.stringValue)' (attempt \(attempt)/\(Self.maxXpubFetchAttempts)): \(error)",
                        level: "warn"
                    )
                    guard Self.isTransientTransportFailure(error) else { break }
                    if attempt < Self.maxXpubFetchAttempts {
                        try? await Task.sleep(nanoseconds: Self.xpubFetchRetryDelayNanos)
                    }
                }
            }
            if let lastError, Self.isTransientTransportFailure(lastError) {
                transientFailures.insert(addressType)
            }
        }
        return (result, transientFailures)
    }

    /// Forget every wallet a device holds. Used by the dev device list, where the unit is the device.
    func forgetDevice(id: String) async {
        let known = knownDevices.first(where: { $0.id == id })
        let isActiveSession = connectedDevice?.id == id || (known.map { connectedDevice?.path == $0.path } ?? false)

        if let device = known {
            await clearCredentials(path: device.path)
        }
        TrezorKnownDeviceStorage.remove(id: id)
        loadKnownDevices()
        trezorLog("Forgot device: \(id)")

        if isActiveSession {
            await disconnect()
        }
    }

    /// Forget one wallet identity, leaving the device's other wallets paired. Transport and session
    /// credentials are keyed by path and shared by every identity of a device, so they are only
    /// cleared once none remains — dropping them while a sibling is still paired would leave that
    /// wallet unable to reconnect.
    func forgetWallet(walletId: String) async {
        let stored = TrezorKnownDeviceStorage.loadAll()
        let forgotten = stored.filter { $0.resolvedWalletId == walletId }
        guard !forgotten.isEmpty else {
            trezorLog("Nothing to forget for hardware wallet '\(walletId)'", level: "warn")
            return
        }
        let remaining = stored.filter { $0.resolvedWalletId != walletId }

        for entry in forgotten where !remaining.contains(where: { $0.id == entry.id }) {
            await clearCredentials(path: entry.path)
        }

        TrezorKnownDeviceStorage.saveAll(remaining)
        loadKnownDevices()
        trezorLog("Forgot hardware wallet: \(walletId)")

        // Only the session of what is being forgotten may be torn down: the device can hold another
        // identity open, and that wallet is still paired and still signing.
        let ownsSession = forgotten.contains { $0.id == connectedDevice?.id || $0.path == connectedDevice?.path }
        if ownsSession, connectedWalletId == nil || connectedWalletId == walletId {
            await disconnect()
        }
    }

    private func clearCredentials(path: String) async {
        do {
            try await trezorService.clearCredentials(deviceId: path)
        } catch {
            trezorLog("Failed to clear credentials for forgotten device: \(error)", level: "warn")
        }
        TrezorCredentialStorage.delete(deviceId: path)
    }

    // MARK: - Auto-Reconnect

    func autoReconnect() async {
        guard !knownDevices.isEmpty else { return }
        guard !isAutoReconnecting else { return }
        // A deliberate wallet-mode open is mid-flight; reconnecting now would race it and open the
        // standard wallet under a hidden selection.
        guard !isOpeningSession else { return }
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

    // MARK: - Reconnect for on-device signing

    /// Ensure the given known device has a live session so it can sign. Reuses the current
    /// connection when it already matches the requested device; otherwise reconnects it. Throws on
    /// failure so the transfer flow can surface a reconnect error.
    func ensureConnected(deviceId: String) async throws {
        if connectedDevice?.id == deviceId, await trezorService.isConnected() {
            let features = try await refreshedFeaturesIfLocked()
            try requireUnlocked(features: features)
            return
        }
        // A stale or mismatched session blocks a clean reconnect — clear it first.
        if connectedDevice != nil {
            await disconnectStaleSession(deviceId: connectedDevice?.id ?? deviceId)
        }
        try await reconnectKnownDevice(deviceId: deviceId)
        try requireUnlocked(features: deviceFeatures)
    }

    private func refreshedFeaturesIfLocked() async throws -> TrezorFeatures {
        guard let features = deviceFeatures else {
            let refreshed = try await trezorService.refreshFeatures()
            deviceFeatures = refreshed
            return refreshed
        }
        if features.pinProtection == true, features.unlocked == false {
            let refreshed = try await trezorService.refreshFeatures()
            deviceFeatures = refreshed
            return refreshed
        }
        return features
    }

    private func requireUnlocked(features: TrezorFeatures?) throws {
        guard let features else { return }
        if features.pinProtection == true, features.unlocked == false {
            throw TrezorError.DeviceBusy
        }
    }

    private func reconnectKnownDevice(deviceId: String, mode: TrezorWalletMode? = .standard) async throws {
        await startScan(clearExisting: true)

        let target: TrezorDeviceInfo
        if let scanned = devices.first(where: { $0.id == deviceId }) {
            target = scanned
        } else if let known = knownDevices.first(where: { $0.id == deviceId }), known.transportType == "bluetooth" {
            // Honor the stored BLE transport — reconnect directly to a known device that didn't
            // surface within the scan window instead of failing outright.
            target = deviceInfo(from: known)
        } else {
            throw AppError(message: "Reconnect Hardware Device", debugMessage: "Device '\(deviceId)' not found nearby")
        }

        await connect(device: target, mode: mode)

        guard connectedDevice?.id == deviceId, await trezorService.isConnected() else {
            throw AppError(message: "Reconnect Hardware Device", debugMessage: error ?? "Failed to reconnect '\(deviceId)'")
        }
    }

    /// Whether the given device is a known Bluetooth device. iOS is BLE-only in practice, but the
    /// stored transport is honored so a USB device still gets the hard reconnect error.
    func isKnownBluetoothDevice(deviceId: String) -> Bool {
        knownDevices.first(where: { $0.id == deviceId })?.transportType == "bluetooth"
    }

    /// Best-effort pre-connect of a known BLE Trezor before the sign screen asks for it, so tapping
    /// Open Trezor Connect is less likely to hit a cold reconnect. Fire-and-forget; no-op when already
    /// connected to it, a connect is in flight, or it isn't a known BLE device.
    func warmUpConnection(deviceId: String) {
        guard connectedDevice?.id != deviceId else { return }
        guard !isScanning else { return }
        // Would race a deliberate wallet-mode open and land on the standard wallet.
        guard !isOpeningSession else { return }
        guard isKnownBluetoothDevice(deviceId: deviceId) else { return }
        Task {
            do {
                try await reconnectKnownDevice(deviceId: deviceId)
            } catch {
                trezorLog("Warm-up connect failed for '\(deviceId)': \(error)", level: "debug")
            }
        }
    }

    /// Tear down the current device session so the next connect establishes a fresh one. Used after
    /// a signing failure or timeout, where the transport session may be left in a bad state.
    func disconnectStaleSession(deviceId: String) async {
        await Task.detached { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await trezorService.disconnect()
            } catch {
                trezorLog("Failed to disconnect stale session for '\(deviceId)': \(error)", level: "warn")
            }
            clearDisconnectedDeviceState()
        }.value
    }

    /// Reconstruct a `TrezorDeviceInfo` for reconnecting to a known BLE device when a fresh scan
    /// hasn't surfaced it (BLE devices advertise intermittently).
    private func deviceInfo(from known: TrezorKnownDevice) -> TrezorDeviceInfo {
        TrezorDeviceInfo(
            id: known.id,
            transportType: known.transportType == "bluetooth" ? .bluetooth : .usb,
            name: known.name,
            path: known.path,
            label: known.label,
            model: known.model,
            isBootloader: false
        )
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
        TrezorErrorPresenter.userMessage(from: error)
    }
}
