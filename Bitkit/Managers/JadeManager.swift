import BitkitCore
import Combine
import Foundation
import LDKNode
import UIKit

/// Device sessions for Blockstream Jade wallets: discovery, connect and unlock, the paired entries,
/// and the device operations Bitkit needs (address verification, the master fingerprint and PSBT
/// signing). Watchers, compose and broadcast are vendor neutral and stay in `HwWalletManager`.
///
/// A Jade locks on every power cycle and unlocks with a PIN entered on the device, which needs the
/// pinserver round trip bitkit-core performs. Silent reconnects never unlock: only the user's own
/// action (pairing, verifying an address, signing) puts the PIN screen on the device.
///
/// Core cancels a connect whenever a disconnect or cancel reaches it after that connect started, so a
/// teardown landing late would kill the connect that follows it. Every teardown therefore clears the
/// session state before its first suspension, invalidates the attempts in flight by bumping
/// `connectEpoch`, and queues its device work on `sessionTeardownTask`, which each connect waits for.
@Observable
@MainActor
final class JadeManager {
    struct Timing {
        /// How long the app may sit in the background before an open link is released. A Jade still
        /// holding a link when the app is suspended can drop its bond, so the link is closed cleanly
        /// first; the delay keeps a brief switch to another app during a PIN or signing prompt from
        /// cancelling it.
        var backgroundRelease: TimeInterval = 30
        /// Kept back from the background time left, so the release itself still fits in it.
        var expirationMargin: TimeInterval = 5
        var reconnectBackoff: TimeInterval = 2
        var reconnectAttempts = 4
        var connectPollInterval: TimeInterval = 0.25
        var connectMaxWait: TimeInterval = 28
    }

    static let allAccountTypes: [AccountType] = [.legacy, .wrappedSegwit, .nativeSegwit, .taproot]

    private static let walletNameMaxLength = 50
    private static let backgroundTaskName = "JadeBluetoothRelease"
    private nonisolated static let logContext = "JadeManager"

    private(set) var isScanning = false
    private(set) var isConnecting = false
    private(set) var isAutoReconnecting = false
    /// Set while the device waits for its PIN.
    private(set) var isUnlocking = false

    private(set) var knownDevices: [HwKnownDevice] = [] {
        didSet {
            devicesRevision &+= 1
            transport.setPairedPaths(Set(knownDevices.map(\.path).filter { HwDevicePath.isBle($0) }))
        }
    }

    /// Jades the last scan found that are not paired yet.
    private(set) var nearbyDevices: [JadeDeviceInfo] = []

    private(set) var connected: ConnectedJadeDevice? {
        didSet { devicesRevision &+= 1 }
    }

    /// Bumped whenever the paired entries or the session change, so observers can push them on.
    private(set) var devicesRevision = 0

    var isConnectInProgress: Bool {
        isConnecting || isAutoReconnecting
    }

    private let service: JadeServicing
    private let transport: JadeTransportControlling
    private let store: JadeKnownDeviceStoring
    private let backgroundTasks: BackgroundTaskScheduling
    private let timing: Timing
    private let now: () -> Date
    private let network: () -> LDKNode.Network

    @ObservationIgnored private var isSetup = false
    @ObservationIgnored private var connectingPath: String?
    @ObservationIgnored private var connectEpoch: UInt64 = 0
    @ObservationIgnored private var attemptTokenCounter: UInt64 = 0
    @ObservationIgnored private var attemptTokens: [AttemptFlag: UInt64] = [:]
    @ObservationIgnored private var sessionTeardownTask: Task<Void, Never>?
    @ObservationIgnored private var transportReconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectLoopGeneration: UInt64 = 0
    @ObservationIgnored private var backgroundReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    private enum AttemptFlag {
        case connecting
        case autoReconnecting
        case unlocking
    }

    init(
        service: JadeServicing = JadeService.shared,
        transport: JadeTransportControlling = JadeTransport.shared,
        store: JadeKnownDeviceStoring = JadeKnownDeviceStore(),
        backgroundTasks: BackgroundTaskScheduling? = nil,
        timing: Timing = Timing(),
        now: @escaping () -> Date = Date.init,
        network: @escaping () -> LDKNode.Network = { Env.network }
    ) {
        self.service = service
        self.transport = transport
        self.store = store
        self.backgroundTasks = backgroundTasks ?? UIApplicationBackgroundTasks()
        self.timing = timing
        self.now = now
        self.network = network

        transport.externalDisconnects
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                self?.handleExternalDisconnect(path: path)
            }
            .store(in: &cancellables)
    }

    // MARK: - Paired devices

    func loadKnownDevices() {
        knownDevices = store.loadAll()
    }

    /// Whether `deviceId` names a paired Jade. `advertisedName` is the name a scan reported for it: a
    /// rebooted Jade advertises under a new Bluetooth identifier, so matching on the id alone would
    /// treat a paired device as a stranger.
    func hasKnownDevice(deviceId: String, advertisedName: String? = nil) -> Bool {
        allKnownDevices().contains { $0.matches(deviceId: deviceId) || $0.advertisesAs(advertisedName) }
    }

    func isKnownBluetoothDevice(deviceId: String) -> Bool {
        knownDevice(deviceId)?.transportType == "bluetooth"
    }

    // MARK: - Scan and pair

    /// Every Jade found nearby. Core refuses to scan while a session is open, so the devices of the
    /// last scan are listed instead of failing the search.
    func scan() async throws -> [JadeDeviceInfo] {
        try await awaitSetup()
        isScanning = true
        defer { isScanning = false }
        let devices = try await scanOrListDevices()
        let paired = allKnownDevices()
        nearbyDevices = devices.filter { device in !paired.contains { $0.isSameJade(as: device) } }
        return devices
    }

    /// Pairs a discovered Jade: connects, unlocks with the PIN entered on the device, reads its
    /// accounts and stores it. A background reconnect or warm-up in flight is cancelled first, so its
    /// teardown cannot cancel this connect.
    @discardableResult
    func connect(path: String) async throws -> ConnectedJadeDevice {
        cancelReconnectLoop()
        if isConnectInProgress {
            await cancelPendingConnection(deviceId: "")
        }
        try await awaitSetup()
        let token = beginAttempt(.connecting)
        defer { endAttempt(.connecting, token: token) }
        let epoch = connectEpoch
        do {
            let device = try await resolveDevice(path: path)
            try requireCurrent(epoch)
            let session = try await connectDevice(device, unlock: true, expected: nil, epoch: epoch)
            nearbyDevices.removeAll { $0.path == path || $0.path == device.path }
            return session
        } catch {
            Logger.error("Jade connect failed: \(error)", context: Self.logContext)
            throw error
        }
    }

    /// Reconnects a paired Jade, which is found again by its stored path or, after a reboot, by the
    /// name it advertises. With `unlock` off the session stays locked, as silent reconnects want.
    @discardableResult
    func connectKnownDevice(deviceId: String, forceSession: Bool = false, unlock: Bool = true) async throws -> ConnectedJadeDevice {
        guard !isConnectInProgress else {
            throw AppError(message: "Connection already in progress", debugMessage: "A Jade connect is already running")
        }
        return try await connectKnownDeviceUnguarded(deviceId: deviceId, forceSession: forceSession, unlock: unlock)
    }

    /// Silent reconnect of the most recently used Jade; never asks for the PIN. Reads the saved entries
    /// when none are loaded yet, since a cold launch reconnects before they are.
    @discardableResult
    func autoReconnect() async throws -> ConnectedJadeDevice {
        guard !isConnectInProgress else {
            throw AppError(message: "Connection already in progress", debugMessage: "A Jade connect is already running")
        }
        guard let entry = savedOrLoadedDevices()
            .filter({ $0.transportType == "bluetooth" })
            .max(by: { $0.lastConnectedAt < $1.lastConnectedAt })
        else {
            throw AppError(message: "Reconnect Hardware Device", debugMessage: "No paired Jade to reconnect")
        }

        let token = beginAttempt(.autoReconnecting)
        defer { endAttempt(.autoReconnecting, token: token) }
        do {
            try await awaitSetup()
            if let current = connected, service.isConnected() {
                return current
            }
            if service.isConnected() {
                await beginTeardown(nil, releasingAttempts: false, core: Self.disconnectCore).value
            }
            return try await connectKnownDeviceUnguarded(deviceId: entry.id, forceSession: false, unlock: false)
        } catch {
            Logger.error("Jade auto-reconnect failed: \(error)", context: Self.logContext)
            throw error
        }
    }

    /// Closes the session: the link and core at once, since a request still waiting on the link holds
    /// core until the link goes.
    func disconnect() async {
        let link = connected.map { LinkRelease.path($0.path) }
        await beginTeardown(link, releasingAttempts: true, core: Self.disconnectCore).value
    }

    /// Stops a connect in flight, including one waiting for the PIN. A Swift task cancel never reaches
    /// core, so a cancel from the UI has to come through here.
    func cancelPendingConnection(deviceId: String) async {
        let fallbackPath = deviceId.isEmpty ? nil : knownDevice(deviceId)?.path ?? deviceId
        let path = connectingPath ?? connected?.path ?? fallbackPath
        await beginTeardown(path.map(LinkRelease.path), releasingAttempts: true) { service in
            do {
                try await service.cancel()
            } catch {
                Logger.warn("Failed to cancel the Jade request in flight: \(error)", context: JadeManager.logContext)
            }
            await JadeManager.disconnectCore(service)
        }.value
    }

    // MARK: - Device events

    /// A link dropped without the app closing it. The notice to core is queued ahead of the next
    /// connect, since a notice arriving after that connect would tear the new session down.
    func handleExternalDisconnect(path: String) {
        guard connected?.path == path || connectingPath == path else { return }
        Logger.warn("External disconnect for Jade '\(path)'", context: Self.logContext)
        connected = nil
        let previous = sessionTeardownTask
        let service = service
        sessionTeardownTask = Task {
            await previous?.value
            await service.notifyDisconnected(path: path)
        }
    }

    // MARK: - Connect internals

    private func connectKnownDeviceUnguarded(deviceId: String, forceSession: Bool, unlock: Bool) async throws -> ConnectedJadeDevice {
        let token = beginAttempt(.connecting)
        defer { endAttempt(.connecting, token: token) }
        var epoch = connectEpoch
        do {
            try await awaitSetup()
            if forceSession, let staleTeardown = beginStaleSessionTeardown(deviceId: deviceId, releasingAttempts: false) {
                // This attempt's own teardown moved the epoch; anything moving it again cancels the attempt.
                epoch = connectEpoch
                await staleTeardown.value
            }
            try requireCurrent(epoch)
            guard let entry = knownDevice(deviceId) else {
                throw AppError(message: "Reconnect Hardware Device", debugMessage: "Unknown Jade '\(deviceId)'")
            }
            let candidate = await knownDeviceCandidate(for: entry)
            try requireCurrent(epoch)
            let session = try await connectDevice(candidate, unlock: unlock, expected: entry, epoch: epoch)
            Logger.info("Reconnected known Jade '\(entry.id)'", context: Self.logContext)
            return session
        } catch {
            Logger.error("Jade reconnect failed: \(error)", context: Self.logContext)
            if connectEpoch == epoch {
                await beginStaleSessionTeardown(deviceId: deviceId, releasingAttempts: false)?.value
            }
            throw error
        }
    }

    private func connectDevice(
        _ device: JadeDeviceInfo,
        unlock: Bool,
        expected: HwKnownDevice?,
        epoch: UInt64
    ) async throws -> ConnectedJadeDevice {
        connectingPath = device.path
        defer {
            if connectEpoch == epoch, connectingPath == device.path {
                connectingPath = nil
            }
        }
        do {
            await awaitSessionTeardown()
            try requireCurrent(epoch)
            var version = try await service.connect(path: device.path)
            try requireCurrent(epoch)
            Logger.info(
                "Connected Jade '\(device.path)' firmware '\(version.jadeVersion)' state '\(version.jadeState)'",
                context: Self.logContext
            )
            try rejectUnusableDevice(version, expected: expected)
            if unlock, version.jadeState == .locked {
                version = try await unlockConnected()
                try requireCurrent(epoch)
            }
            let known = try await knownEntry(for: device, version: version, expected: expected, epoch: epoch)
            let session = ConnectedJadeDevice(id: known.id, path: device.path, versionInfo: version, walletId: known.resolvedWalletId)
            connected = session
            return session
        } catch {
            if connectEpoch == epoch {
                await beginTeardown(.path(device.path), releasingAttempts: false, core: Self.disconnectCore).value
            }
            throw error
        }
    }

    /// The entry this connect lands on: refreshed with the accounts an unlocked device reports, or,
    /// for a device still locked, the entry that already holds its keys.
    private func knownEntry(
        for device: JadeDeviceInfo,
        version: JadeVersionInfo,
        expected: HwKnownDevice?,
        epoch: UInt64
    ) async throws -> HwKnownDevice {
        if version.jadeState.isUnlocked {
            let xpubs = try await exportAccounts()
            try requireCurrent(epoch)
            return addOrUpdateKnownDevice(device, version: version, fetchedXpubs: xpubs)
        }
        let entryId = JadeDeviceIdentity.deviceId(efuseMac: version.efuseMac) ?? device.path
        guard let entry = expected ?? knownDevice(entryId) else {
            throw JadeError.DeviceLocked
        }
        return refreshKnownDevice(entry, path: device.path)
    }

    /// Refuses a Jade with no wallet yet, and one that is not the paired device expected. Runs before
    /// unlocking, so a wrong Jade never shows a PIN prompt.
    private func rejectUnusableDevice(_ version: JadeVersionInfo, expected: HwKnownDevice?) throws {
        if version.jadeState == .uninit {
            throw JadeError.DeviceUninitialized
        }
        // A device reporting no efuse MAC cannot prove it is the paired one, so it fails closed.
        guard let expectedMac = expected?.jadeDeviceId, !expectedMac.isEmpty else { return }
        if expectedMac != version.efuseMac {
            throw AppError(message: "Reconnect Hardware Device", debugMessage: "A different Jade is connected")
        }
    }

    private func unlockConnected() async throws -> JadeVersionInfo {
        let token = beginAttempt(.unlocking)
        defer { endAttempt(.unlocking, token: token) }
        // Core enforces the five minute unlock deadline; the PIN is typed on the device.
        try await service.unlock(network: jadeNetwork())
        return try await service.refreshVersionInfo()
    }

    private func exportAccounts() async throws -> [String: String] {
        let network = try jadeNetwork()
        let export: JadeAccountExport
        do {
            export = try await service.getAccountExport(network: network, accountTypes: Self.allAccountTypes, accountIndex: 0)
        } catch let error where error.isJadeFirmwareError() {
            Logger.warn("Retrying the Jade account export without taproot: \(error)", context: Self.logContext)
            let withoutTaproot = Self.allAccountTypes.filter { $0 != .taproot }
            export = try await service.getAccountExport(network: network, accountTypes: withoutTaproot, accountIndex: 0)
        }
        var xpubs: [String: String] = [:]
        for account in export.accounts {
            xpubs[AddressScriptType(jadeVariant: account.variant).stringValue] = account.xpub
        }
        guard !xpubs.isEmpty else {
            throw AppError(
                message: "Could not read any account keys from your Jade. Reconnect and try again.",
                debugMessage: "The Jade account export held no accounts"
            )
        }
        return xpubs
    }

    private func addOrUpdateKnownDevice(_ device: JadeDeviceInfo, version: JadeVersionInfo, fetchedXpubs: [String: String]) -> HwKnownDevice {
        let devices = allKnownDevices()
        let id = JadeDeviceIdentity.deviceId(efuseMac: version.efuseMac) ?? device.path
        let previous = HwKnownDeviceMatching.previous(in: devices, deviceId: id, fetchedXpubs: fetchedXpubs)
        let xpubs = (previous?.xpubs ?? [:]).merging(fetchedXpubs) { _, fetched in fetched }
        let walletKey = HwKnownDevice.walletKey(for: xpubs, fallback: id)
        let named = HwKnownDeviceMatching.named(in: devices, previous: previous, walletKey: walletKey)
        let walletId = resolvedWalletId(previous: previous, walletKey: walletKey, xpubs: xpubs, in: devices)
        // A name restored from a backup, or kept when this wallet was removed, is adopted here; the
        // store masks a pending name out once a paired entry carries it, so adopting it consumes it.
        let pendingName = walletId.flatMap { store.loadPendingNames()[$0] }.flatMap { $0.isEmpty ? nil : $0 }

        let known = HwKnownDevice(
            id: id,
            name: device.name ?? previous?.name ?? JadeDeviceIdentity.defaultName,
            path: device.path,
            transportType: device.transport == .bluetooth ? "bluetooth" : "usb",
            label: nil,
            model: JadeDeviceIdentity.model(boardType: version.boardType),
            lastConnectedAt: now(),
            xpubs: xpubs,
            customLabel: named?.customLabel ?? pendingName,
            walletId: walletId,
            passphraseProtected: false,
            vendor: .blockstream,
            jadeDeviceId: version.efuseMac
        )
        let updated = HwKnownDeviceMatching.merged(devices, with: known, refreshed: previous)
        store.saveAll(updated, pendingName: nil)
        setKnownDevices(updated)
        return known
    }

    /// The wallet id this identity already carries, else one derived from its keys. Never the device
    /// id: an id derived later would then disagree with the one stored.
    private func resolvedWalletId(previous: HwKnownDevice?, walletKey: String, xpubs: [String: String], in devices: [HwKnownDevice]) -> String? {
        if let carried = previous?.walletId ?? devices.first(where: { $0.walletKey == walletKey })?.walletId, !carried.isEmpty {
            return carried
        }
        return try? HwWalletId.derive(xpubs: xpubs, vendor: .blockstream)
    }

    private func refreshKnownDevice(_ entry: HwKnownDevice, path: String) -> HwKnownDevice {
        let refreshed = entry.refreshed(path: path, at: now())
        let updated = allKnownDevices().map { $0.id == entry.id && $0.walletKey == entry.walletKey ? refreshed : $0 }
        store.saveAll(updated, pendingName: nil)
        setKnownDevices(updated)
        return refreshed
    }

    /// The device a pairing connect dials. Core only connects to devices of its last scan, so a path
    /// it has not seen is scanned for, and a paired Jade that came back under a new Bluetooth
    /// identifier is dialled there: its stored identifier would only fail once the connect timed out.
    private func resolveDevice(path: String) async throws -> JadeDeviceInfo {
        if let nearby = nearbyDevices.first(where: { $0.path == path }) {
            return nearby
        }
        if let listed = await service.listDevices().first(where: { $0.path == path }) {
            return listed
        }
        let scanned = try await scanOrListDevices()
        if let match = scanned.first(where: { $0.path == path }) {
            return match
        }
        if let entry = knownDevice(path),
           let readvertised = scanned.first(where: { $0.transport == .bluetooth && entry.advertisesAs($0.name) })
        {
            Logger.info("Resolved Jade '\(path)' to its new path '\(readvertised.path)'", context: Self.logContext)
            return readvertised
        }
        return JadeDeviceInfo(path: path, transport: .bluetooth, name: nil, serialNumber: nil)
    }

    /// Where a paired Jade is dialled: its stored path when a scan still sees it there, else the Jade
    /// advertising under its name, else the stored path, which the transport can reach without a scan.
    private func knownDeviceCandidate(for entry: HwKnownDevice) async -> JadeDeviceInfo {
        let scanned: [JadeDeviceInfo]
        do {
            scanned = try await scanOrListDevices()
        } catch {
            Logger.warn("Scan before the Jade reconnect failed: \(error)", context: Self.logContext)
            scanned = []
        }
        let bluetooth = scanned.filter { $0.transport == .bluetooth }
        if let exact = bluetooth.first(where: { $0.path == entry.path }) {
            return exact
        }
        if let readvertised = bluetooth.first(where: { entry.advertisesAs($0.name) }) {
            return readvertised
        }
        return JadeDeviceInfo(path: entry.path, transport: .bluetooth, name: entry.name, serialNumber: nil)
    }

    private func scanOrListDevices() async throws -> [JadeDeviceInfo] {
        if service.isConnected() {
            return await service.listDevices()
        }
        return try await service.scan(timeoutMs: JadeService.scanTimeoutMs)
    }

    // MARK: - Teardown

    /// Clears the session and invalidates every attempt in flight before the first suspension, then
    /// queues closing the link and `core` behind any earlier teardown. Both start together: core
    /// signals its change at once, while the link close still interrupts a request stuck on the link.
    /// The work runs in its own task, so a cancelled caller cannot cut it short.
    ///
    /// - Parameter releasingAttempts: whether the caller gives the device up, which also stops the
    /// background reconnect and clears every in-progress flag. An attempt cleaning up after itself
    /// leaves them to its own unwinding.
    @discardableResult
    private func beginTeardown(
        _ link: LinkRelease?,
        releasingAttempts: Bool,
        core: @escaping @Sendable (JadeServicing) async -> Void
    ) -> Task<Void, Never> {
        connectEpoch &+= 1
        connected = nil
        connectingPath = nil
        if releasingAttempts {
            cancelReconnectLoop()
            resetAttempts()
        }
        let previous = sessionTeardownTask
        let service = service
        let transport = transport
        let teardown = Task {
            await previous?.value
            async let linkReleased: Void = LinkRelease.release(link, on: transport)
            async let coreReleased: Void = core(service)
            _ = await (linkReleased, coreReleased)
        }
        sessionTeardownTask = teardown
        return teardown
    }

    /// Tears the session of `deviceId` down, or of the device being connected. Nil while another Jade
    /// holds the session, which is left alone.
    private func beginStaleSessionTeardown(deviceId: String, releasingAttempts: Bool) -> Task<Void, Never>? {
        if let current = connected, !current.matches(deviceId) {
            return nil
        }
        let path = connected?.path ?? connectingPath ?? knownDevice(deviceId)?.path ?? deviceId
        return beginTeardown(.path(path), releasingAttempts: releasingAttempts, core: Self.disconnectCore)
    }

    private func awaitSessionTeardown() async {
        var awaited: Task<Void, Never>?
        while let pending = sessionTeardownTask, pending != awaited {
            await pending.value
            awaited = pending
        }
    }

    private nonisolated static let disconnectCore: @Sendable (JadeServicing) async -> Void = { service in
        do {
            try await service.disconnect()
        } catch {
            Logger.warn("Failed to close the Jade core session: \(error)", context: logContext)
        }
    }

    private func requireCurrent(_ epoch: UInt64) throws {
        guard connectEpoch == epoch else { throw JadeError.UserCancelled }
    }

    // MARK: - Connection upkeep

    private func awaitConnectedOrNull(deviceId: String) async throws -> ConnectedJadeDevice? {
        if let current = liveSession(deviceId: deviceId) {
            return current
        }
        guard isConnectInProgress else { return nil }
        let deadline = Date().addingTimeInterval(timing.connectMaxWait)
        while isConnectInProgress, liveSession(deviceId: deviceId) == nil, Date() < deadline {
            try await Task.sleep(for: .seconds(timing.connectPollInterval))
        }
        return liveSession(deviceId: deviceId)
    }

    private func liveSession(deviceId: String) -> ConnectedJadeDevice? {
        guard let current = connected, current.matches(deviceId), service.isConnected() else { return nil }
        return current
    }

    private func retryAutoReconnect() async {
        for attempt in 0 ..< timing.reconnectAttempts {
            if connected != nil || isConnectInProgress {
                return
            }
            do {
                try await Task.sleep(for: .seconds(timing.reconnectBackoff * Double(attempt + 1)))
            } catch {
                return
            }
            if Task.isCancelled || connected != nil || isConnectInProgress {
                return
            }
            Logger.info("Attempting Jade auto-reconnect, attempt \(attempt + 1)", context: Self.logContext)
            do {
                try await autoReconnect()
                return
            } catch {
                if Task.isCancelled || error.isJadeDeviceBusy() {
                    return
                }
            }
        }
    }

    private func cancelReconnectLoop() {
        transportReconnectTask?.cancel()
        transportReconnectTask = nil
    }

    private func beginAttempt(_ flag: AttemptFlag) -> UInt64 {
        attemptTokenCounter &+= 1
        attemptTokens[flag] = attemptTokenCounter
        setAttemptFlag(flag, to: true)
        return attemptTokenCounter
    }

    /// Clears `flag` unless a release already did, or a newer attempt owns it now.
    private func endAttempt(_ flag: AttemptFlag, token: UInt64) {
        guard attemptTokens[flag] == token else { return }
        attemptTokens[flag] = nil
        setAttemptFlag(flag, to: false)
    }

    private func resetAttempts() {
        attemptTokens.removeAll()
        isConnecting = false
        isAutoReconnecting = false
        isUnlocking = false
    }

    private func setAttemptFlag(_ flag: AttemptFlag, to value: Bool) {
        switch flag {
        case .connecting: isConnecting = value
        case .autoReconnecting: isAutoReconnecting = value
        case .unlocking: isUnlocking = value
        }
    }

    // MARK: - Background

    private func releaseInBackground(taskId: UIBackgroundTaskIdentifier) async {
        Logger.info("Releasing the Jade Bluetooth link while the app is in the background", context: Self.logContext)
        await releaseSession()
        endBackgroundTask(taskId)
    }

    /// The background time ran out: every link is cancelled without waiting, and core is told behind
    /// the teardown chain so the next connect still waits for it.
    private func releaseBeforeSuspension() {
        backgroundReleaseTask?.cancel()
        backgroundReleaseTask = nil
        transport.releaseAllImmediately()
        beginTeardown(nil, releasingAttempts: true, core: Self.disconnectCore)
        endBackgroundTask(backgroundTaskId)
    }

    private func backgroundReleaseDelay(for taskId: UIBackgroundTaskIdentifier) -> TimeInterval {
        guard taskId != .invalid else { return 0 }
        let budget = backgroundTasks.backgroundTimeRemaining - timing.expirationMargin
        return max(0, min(timing.backgroundRelease, budget))
    }

    /// Ends `taskId` if it is still the one running, so no task is ended twice.
    private func endBackgroundTask(_ taskId: UIBackgroundTaskIdentifier) {
        guard taskId != .invalid, backgroundTaskId == taskId else { return }
        backgroundTaskId = .invalid
        backgroundTasks.endBackgroundTask(taskId)
    }

    // MARK: - Helpers

    private func awaitSetup() async throws {
        guard !isSetup else { return }
        try await service.initialize()
        guard !isSetup else { return }
        loadKnownDevices()
        isSetup = true
    }

    private func jadeNetwork() throws -> JadeNetwork {
        try network().toJadeNetwork()
    }

    /// The stored entries plus any in memory the store does not hold, so a failed write never loses one.
    private func allKnownDevices() -> [HwKnownDevice] {
        let stored = store.loadAll()
        let storedIds = Set(stored.map(\.entryId))
        return stored + knownDevices.filter { !storedIds.contains($0.entryId) }
    }

    private func savedOrLoadedDevices() -> [HwKnownDevice] {
        knownDevices.isEmpty ? store.loadAll() : knownDevices
    }

    private func knownDevice(_ deviceId: String) -> HwKnownDevice? {
        allKnownDevices().first { $0.matches(deviceId: deviceId) }
    }

    private func setKnownDevices(_ devices: [HwKnownDevice]) {
        knownDevices = devices.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    /// Retries once after unlocking when the device locked since the session was opened: a cached
    /// unlocked state would otherwise report the Jade as busy until it is reconnected.
    private func retryingOnceIfLocked<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard case .DeviceLocked? = error.underlyingJadeError, let current = connected else { throw error }
            Logger.info("The Jade locked since it connected; unlocking and retrying", context: Self.logContext)
            connected?.versionInfo.jadeState = .locked
            try await ensureConnected(deviceId: current.id)
            return try await operation()
        }
    }
}

// MARK: - JadeSessioning

extension JadeManager: JadeSessioning {
    var storedDevices: [HwKnownDevice] {
        knownDevices
    }

    var connectedDeviceId: String? {
        connected?.id
    }

    var connectedWalletId: String? {
        connected?.walletId
    }

    var isSessionActive: Bool {
        connected != nil || isConnectInProgress || transportReconnectTask != nil
    }

    /// Reuses a live session of `deviceId`, unlocking it when locked, else reconnects it. A pending
    /// background reconnect is dropped rather than waited out; only an attempt already dialling is.
    func ensureConnected(deviceId: String) async throws {
        cancelReconnectLoop()
        try await awaitSetup()
        guard let current = try await awaitConnectedOrNull(deviceId: deviceId) else {
            try await connectKnownDevice(deviceId: deviceId, forceSession: true)
            return
        }
        guard current.isLocked else { return }
        let epoch = connectEpoch
        let version = try await unlockConnected()
        try requireCurrent(epoch)
        connected?.versionInfo = version
    }

    func verifyAddress(addressType: AddressScriptType, derivationPath: String, expectedAddress: String) async throws {
        let network = try jadeNetwork()
        try await retryingOnceIfLocked {
            try await service.verifyAddress(
                network: network,
                variant: addressType.jadeVariant,
                derivationPath: derivationPath,
                expectedAddress: expectedAddress
            )
        }
    }

    func masterFingerprint() async throws -> String {
        try await service.getMasterFingerprint(network: jadeNetwork())
    }

    func signPsbt(_ psbtBase64: String) async throws -> CompletedTransaction {
        let network = try jadeNetwork()
        let signed = try await retryingOnceIfLocked {
            try await service.signPsbt(network: network, psbtBase64: psbtBase64)
        }
        return try await service.finalizePsbt(originalPsbt: psbtBase64, signedPsbt: signed)
    }

    func disconnectStaleSession(deviceId: String) async {
        await beginStaleSessionTeardown(deviceId: deviceId, releasingAttempts: true)?.value
    }

    func releaseSession() async {
        if connected != nil {
            await disconnect()
        } else if isConnectInProgress {
            await cancelPendingConnection(deviceId: "")
        } else {
            cancelReconnectLoop()
        }
    }

    func warmUpConnection(deviceId: String) {
        guard !isConnectInProgress, liveSession(deviceId: deviceId) == nil, isKnownBluetoothDevice(deviceId: deviceId) else { return }
        Logger.info("Warming up paired Jade '\(deviceId)'", context: Self.logContext)
        Task {
            do {
                try await connectKnownDevice(deviceId: deviceId, unlock: false)
            } catch {
                Logger.debug("Warm-up connect failed for '\(deviceId)': \(error)", context: Self.logContext)
            }
        }
    }

    func forgetWallet(walletId: String, pendingName: PendingHwWalletName?) async {
        let devices = allKnownDevices()
        let forgotten = devices.filter { $0.resolvedWalletId == walletId }
        guard !forgotten.isEmpty else {
            Logger.warn("Nothing to forget for Jade wallet '\(walletId)'", context: Self.logContext)
            return
        }
        let remaining = devices.filter { $0.resolvedWalletId != walletId }
        store.saveAll(remaining, pendingName: pendingName)
        setKnownDevices(remaining)
        Logger.info("Forgot Jade wallet '\(walletId)'", context: Self.logContext)

        if let current = connected, forgotten.contains(where: { $0.id == current.id || $0.path == current.path }) {
            await disconnect()
        }
    }

    func renameWallet(walletId: String, newName: String) {
        let devices = allKnownDevices()
        guard devices.contains(where: { $0.resolvedWalletId == walletId }) else { return }
        let trimmed = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.walletNameMaxLength))
        let customLabel = trimmed.isEmpty ? nil : trimmed
        let updated = devices.map { device -> HwKnownDevice in
            guard device.resolvedWalletId == walletId else { return device }
            var renamed = device
            renamed.customLabel = customLabel
            return renamed
        }
        // Dropped before the label is written, while the entry still masks it: a pending name left
        // behind would come back the moment the user clears this label.
        store.setPendingName(walletId: walletId, name: nil)
        store.saveAll(updated, pendingName: nil)
        setKnownDevices(updated)
        Logger.info("Renamed Jade wallet '\(walletId)'", context: Self.logContext)
    }

    func startAutoReconnect() {
        guard connected == nil, !isConnectInProgress, transportReconnectTask == nil else { return }
        guard savedOrLoadedDevices().contains(where: { $0.transportType == "bluetooth" }) else { return }
        reconnectLoopGeneration &+= 1
        let generation = reconnectLoopGeneration
        transportReconnectTask = Task { [weak self] in
            await self?.retryAutoReconnect()
            guard let self, reconnectLoopGeneration == generation else { return }
            transportReconnectTask = nil
        }
    }

    /// Schedules releasing the link, unless the app returns first. A pending background reconnect is
    /// dropped, and counts as a session to release in case it had already dialled.
    func onAppBackgrounded() {
        let hadPendingReconnect = transportReconnectTask != nil
        cancelReconnectLoop()
        // A release already scheduled or still running covers this one.
        guard backgroundReleaseTask == nil, backgroundTaskId == .invalid else { return }
        guard connected != nil || isConnectInProgress || hadPendingReconnect else { return }

        let taskId = backgroundTasks.beginBackgroundTask(named: Self.backgroundTaskName) { [weak self] in
            self?.releaseBeforeSuspension()
        }
        backgroundTaskId = taskId
        let delay = backgroundReleaseDelay(for: taskId)
        backgroundReleaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            backgroundReleaseTask = nil
            await releaseInBackground(taskId: taskId)
        }
    }

    func onAppBecameActive() {
        backgroundReleaseTask?.cancel()
        backgroundReleaseTask = nil
        endBackgroundTask(backgroundTaskId)
    }

    func resetForWipe() async {
        backgroundReleaseTask?.cancel()
        backgroundReleaseTask = nil
        endBackgroundTask(backgroundTaskId)
        await beginTeardown(.all, releasingAttempts: true, core: Self.disconnectCore).value
        isSetup = false
        nearbyDevices = []
        knownDevices = []
    }
}

/// The links a teardown closes.
private enum LinkRelease {
    case path(String)
    case all

    static func release(_ link: LinkRelease?, on transport: JadeTransportControlling) async {
        switch link {
        case let .path(path)?:
            await transport.disconnectDevice(path: path)
        case .all?:
            await transport.closeAllConnections()
        case nil:
            return
        }
    }
}
