import BitkitCore
import Combine
import Foundation

/// Production hardware-wallet business layer. Tracks paired Trezor devices as watch-only
/// balances by running one on-chain xpub watcher per (device, address type), aggregating the
/// per-device balance in memory, and persisting each device's on-chain activity into
/// bitkit-core scoped by a derived `walletId` (core 0.3.x wallet-scoped storage).
///
/// Fully decoupled from `TrezorManager`: it receives the paired-device snapshot through
/// `updateDevices(...)`, fed by the composition root (`AppScene`). Adapts bitkit-android's
/// `HwWalletRepo`. iOS supports Bluetooth only, so the cross-transport (BLE+USB) dedup is reduced
/// to a plain xpub-based identity and USB-specific reconnect handling is omitted.
@Observable
@MainActor
final class HwWalletManager {
    private enum Constants {
        static let watcherIdSeparator = "|"
        static let watcherStartRetryDelay: Duration = .seconds(30)
        static let defaultGapLimit: UInt32 = 20
    }

    // MARK: - Published state

    /// Paired hardware wallets, one per physical device, with aggregated balance.
    private(set) var wallets: [HwWallet] = []

    /// Sum of every paired wallet's balance.
    private(set) var totalSats: UInt64 = 0

    /// bitkit-core wallet ids for the paired hardware wallets — the activity list queries these.
    private(set) var hwWalletIds: Set<String> = []

    /// Whether the known-device store has been read at least once.
    private(set) var walletsLoaded = false

    /// Inbound transactions detected by a running watcher after its initial history sync.
    let receivedTxPublisher = PassthroughSubject<HwWalletReceivedTx, Never>()

    // MARK: - Dependencies

    private let watcherService: OnChainWatcherServicing
    private let monitoredTypesProvider: () -> Set<String>
    private let electrumUrlProvider: () -> String
    private let networkProvider: () -> TrezorCoinType
    private let persistActivities: ([Activity]) -> Void
    private let deleteActivities: (String) -> Void

    // MARK: - Internal state

    private var knownDevices: [TrezorKnownDevice] = []
    private var connectedDeviceId: String?
    private var watcherData: [String: HwWatcherData] = [:]
    private var activeWatchers: Set<String> = []
    private var activeWatcherElectrumUrls: [String: String] = [:]
    private var retryingWatcherStarts: Set<String> = []

    /// Watchers whose async start is dispatched but not yet confirmed in `activeWatchers`.
    /// Guards against a second `syncWatchers()` double-starting the same watcher in that window.
    private var pendingWatcherStarts: Set<String> = []

    private var emittedReceivedTxIds: Set<String> = []
    private var listeners: [String: TrezorEventListener] = [:]

    init(
        watcherService: OnChainWatcherServicing = OnChainHwService.shared,
        monitoredTypes: (() -> Set<String>)? = nil,
        electrumUrl: (() -> String)? = nil,
        network: (() -> TrezorCoinType)? = nil,
        persistActivities: (([Activity]) -> Void)? = nil,
        deleteActivities: ((String) -> Void)? = nil
    ) {
        self.watcherService = watcherService
        networkProvider = network ?? { OnChainHwService.appDefaultCoinType }
        monitoredTypesProvider = monitoredTypes ?? {
            Set(SettingsViewModel.shared.addressTypesToMonitor.map(\.stringValue))
        }
        electrumUrlProvider = electrumUrl ?? { OnChainHwService.getElectrumUrl() }
        self.persistActivities = persistActivities ?? { activities in
            guard !activities.isEmpty else { return }
            Task {
                try? await ServiceQueue.background(.core) {
                    try BitkitCore.upsertActivities(activities: activities)
                    CoreService.shared.activity.notifyActivitiesChanged()
                }
            }
        }
        self.deleteActivities = deleteActivities ?? { walletId in
            Task {
                try? await ServiceQueue.background(.core) {
                    _ = try BitkitCore.deleteActivitiesByWalletId(walletId: walletId)
                    CoreService.shared.activity.notifyActivitiesChanged()
                }
            }
        }
    }

    // MARK: - Device input

    /// Update the device snapshot and reconcile watchers. This is the manager's sole input: the
    /// composition root (`AppScene`) feeds it the current Trezor device list, so this type stays
    /// fully decoupled from `TrezorManager`. Also the test seam — tests drive it directly.
    func updateDevices(knownDevices: [TrezorKnownDevice], connectedDeviceId: String?) {
        let previousWalletIds = hwWalletIds
        self.knownDevices = knownDevices
        self.connectedDeviceId = connectedDeviceId
        walletsLoaded = true
        syncWatchers()
        recomputeDerivedState()

        // A device that dropped out of the snapshot (e.g. the user forgot it) would otherwise
        // leave its watch-only activities orphaned in the merged activity list, which queries
        // every wallet id. syncWatchers already stopped its watcher above; delete its persisted
        // activities too. Cleans up on any removal path, keeping us decoupled from TrezorManager.
        for walletId in previousWalletIds.subtracting(hwWalletIds) {
            deleteActivities(walletId)
        }
    }

    // MARK: - Control

    func resetState() {
        for watcherId in activeWatchers {
            try? watcherService.stopWatcher(watcherId: watcherId)
        }
        for walletId in hwWalletIds {
            deleteActivities(walletId)
        }
        activeWatchers.removeAll()
        activeWatcherElectrumUrls.removeAll()
        retryingWatcherStarts.removeAll()
        pendingWatcherStarts.removeAll()
        emittedReceivedTxIds.removeAll()
        listeners.removeAll()
        watcherData.removeAll()
        recomputeDerivedState()
    }

    /// Stop watching a paired hardware wallet and delete its stored activities. The caller is
    /// responsible for forgetting the device entries (via `TrezorManager.forgetDevice`); the next
    /// `updateDevices(...)` push then drops it from the tile list.
    func removeDevice(id deviceId: String) {
        let group = deviceGroups().first { $0.ids.contains(deviceId) }
        let ids = group?.ids ?? [deviceId]
        for watcherId in activeWatchers where ids.contains(self.deviceId(fromWatcherId: watcherId)) {
            _ = stopActiveWatcher(watcherId)
        }
        if let group { deleteActivities(group.walletId) }
        recomputeDerivedState()
    }

    // MARK: - Watcher orchestration

    func syncWatchers() {
        let monitored = monitoredTypesProvider()
        let electrumUrl = electrumUrlProvider()

        var seen = Set<String>()
        var specs: [WatcherSpec] = []
        for device in knownDevices {
            // Scope a device's watchers under its derived wallet id (skips devices without xpubs).
            guard let walletId = try? HwWalletId.derive(xpubs: device.xpubs) else { continue }
            for (addressType, xpub) in device.xpubs where monitored.contains(addressType) {
                guard seen.insert("\(addressType)\u{1}\(xpub)").inserted else { continue }
                specs.append(WatcherSpec(deviceId: device.id, walletId: walletId, addressType: addressType, xpub: xpub, electrumUrl: electrumUrl))
            }
        }
        let desiredIds = Set(specs.map(\.watcherId))

        for spec in specs {
            // A start is already in flight for this watcher; skip so we don't launch a duplicate.
            // The next sync after it completes reconciles any electrum-url change.
            if pendingWatcherStarts.contains(spec.watcherId) { continue }
            let isActive = activeWatchers.contains(spec.watcherId)
            if isActive, activeWatcherElectrumUrls[spec.watcherId] == spec.electrumUrl { continue }
            if isActive, !stopActiveWatcher(spec.watcherId) { continue }
            startWatcher(spec)
        }

        // A failed stop stays active so the next sync retries it; dropping it here would leave the
        // orphaned watcher feeding watcherData as a ghost balance.
        for staleId in activeWatchers.subtracting(desiredIds) {
            _ = stopActiveWatcher(staleId)
        }
    }

    private func startWatcher(_ spec: WatcherSpec) {
        guard let addressType = HwAddressType(settingsString: spec.addressType) else { return }
        let network = networkProvider()
        let params = WatcherParams(
            watcherId: spec.watcherId,
            walletId: spec.walletId,
            extendedKey: spec.xpub,
            electrumUrl: spec.electrumUrl,
            network: network.coreNetwork,
            accountType: addressType.accountType,
            gapLimit: Constants.defaultGapLimit
        )
        let listener = TrezorEventListener { [weak self] id, event in
            self?.handleWatcherEvent(watcherId: id, event: event)
        }
        listeners[spec.watcherId] = listener
        pendingWatcherStarts.insert(spec.watcherId)

        Task { @MainActor in
            do {
                try await watcherService.startWatcher(params: params, listener: listener)
                pendingWatcherStarts.remove(spec.watcherId)
                activeWatchers.insert(spec.watcherId)
                activeWatcherElectrumUrls[spec.watcherId] = spec.electrumUrl
                retryingWatcherStarts.remove(spec.watcherId)
            } catch {
                pendingWatcherStarts.remove(spec.watcherId)
                listeners[spec.watcherId] = nil
                Logger.warn("Retrying hardware watcher '\(spec.watcherId)' after start failure: \(error)")
                scheduleWatcherStartRetry(spec.watcherId)
            }
        }
    }

    @discardableResult
    private func stopActiveWatcher(_ watcherId: String) -> Bool {
        do {
            try watcherService.stopWatcher(watcherId: watcherId)
            activeWatchers.remove(watcherId)
            activeWatcherElectrumUrls[watcherId] = nil
            watcherData[watcherId] = nil
            listeners[watcherId] = nil
            return true
        } catch {
            return false
        }
    }

    private func scheduleWatcherStartRetry(_ watcherId: String) {
        guard retryingWatcherStarts.insert(watcherId).inserted else { return }
        Task { @MainActor in
            try? await Task.sleep(for: Constants.watcherStartRetryDelay)
            retryingWatcherStarts.remove(watcherId)
            syncWatchers()
        }
    }

    // MARK: - Watcher events

    /// Update aggregated state from a watcher event. The first event after a watcher starts
    /// delivers the full history (baseline); only later inbound txs are surfaced as received.
    /// Core builds the persistence-ready activities (core 0.3.4 watch-only watcher); the manager
    /// stores, aggregates, and scopes them to the device.
    func handleWatcherEvent(watcherId: String, event: WatcherEvent) {
        guard case let .transactionsChanged(activities, _, balance, _, _, _) = event else { return }
        let previous = watcherData[watcherId]
        watcherData[watcherId] = HwWatcherData(
            deviceId: deviceId(fromWatcherId: watcherId),
            balanceSats: balance.total,
            activities: activities
        )
        recomputeDerivedState()
        persistGroupActivities(forDevice: deviceId(fromWatcherId: watcherId))
        emitReceivedTxs(previous: previous, activities: activities)
    }

    private func emitReceivedTxs(previous: HwWatcherData?, activities: [Activity]) {
        guard let previous else { return }
        let knownTxIds = onchainTxIds(in: previous.activities)
        for activity in activities {
            guard case let .onchain(onchain) = activity, onchain.txType == .received else { continue }
            guard !knownTxIds.contains(onchain.txId) else { continue }
            guard emittedReceivedTxIds.insert(onchain.txId).inserted else { continue }
            receivedTxPublisher.send(HwWalletReceivedTx(txid: onchain.txId, sats: onchain.value))
        }
    }

    private func onchainTxIds(in activities: [Activity]) -> Set<String> {
        Set(activities.compactMap { activity in
            guard case let .onchain(onchain) = activity else { return nil }
            return onchain.txId
        })
    }

    // MARK: - Persistence

    private func persistGroupActivities(forDevice deviceId: String) {
        guard let group = deviceGroups().first(where: { $0.ids.contains(deviceId) }) else { return }
        persistActivities(mergedActivities(for: group))
    }

    /// Aggregate the activities core emitted across a device-group's watchers, scoping each to the
    /// group's wallet id and deduping by activity id (so the same tx seen by two address-type
    /// watchers persists once).
    private func mergedActivities(for group: DeviceGroup) -> [Activity] {
        let watchers = watcherData.values.filter { group.ids.contains($0.deviceId) }
        var byId: [String: Activity] = [:]
        for activity in watchers.flatMap(\.activities) {
            let scoped = scopedToWallet(activity, walletId: group.walletId)
            byId[activityId(of: scoped)] = scoped
        }
        return Array(byId.values)
    }

    private func scopedToWallet(_ activity: Activity, walletId: String) -> Activity {
        switch activity {
        case var .onchain(onchain):
            onchain.walletId = walletId
            return .onchain(onchain)
        case var .lightning(lightning):
            lightning.walletId = walletId
            return .lightning(lightning)
        }
    }

    private func activityId(of activity: Activity) -> String {
        switch activity {
        case let .onchain(onchain): return onchain.id
        case let .lightning(lightning): return lightning.id
        }
    }

    // MARK: - Aggregation

    private func recomputeDerivedState() {
        let groups = deviceGroups()

        wallets = groups.map { group in
            let connectedDevice = group.devices.first { $0.id == connectedDeviceId }
            let device = connectedDevice ?? group.representative
            let deviceWatchers = watcherData.values.filter { group.ids.contains($0.deviceId) }
            return HwWallet(
                id: device.id,
                walletId: group.walletId,
                name: displayName(of: device),
                model: device.model,
                isConnected: connectedDevice != nil,
                balanceSats: deviceWatchers.reduce(UInt64(0)) { saturatingAdd($0, $1.balanceSats) },
                deviceIds: group.ids
            )
        }

        totalSats = wallets.reduce(UInt64(0)) { saturatingAdd($0, $1.balanceSats) }
        hwWalletIds = Set(groups.map(\.walletId))
    }

    /// Group device entries sharing an xpub identity (same physical device over different
    /// transports), preserving first-seen order. Entries without captured xpubs are skipped.
    private func deviceGroups() -> [DeviceGroup] {
        var order: [String] = []
        var grouped: [String: [TrezorKnownDevice]] = [:]
        for device in knownDevices where !device.xpubs.isEmpty {
            guard let walletId = try? HwWalletId.derive(xpubs: device.xpubs) else { continue }
            if grouped[walletId] == nil { order.append(walletId) }
            grouped[walletId, default: []].append(device)
        }
        return order.compactMap { walletId in
            guard let devices = grouped[walletId] else { return nil }
            return DeviceGroup(walletId: walletId, devices: devices)
        }
    }

    // MARK: - Helpers

    /// The label is the user-set name stored on the device; without one (or with the factory
    /// default that mirrors the model), fall back to the vendor-prefixed model.
    private func displayName(of device: TrezorKnownDevice) -> String {
        if let label = device.label, label != device.model { return label }
        guard let model = device.model else { return "Trezor" }
        return model.hasPrefix("Trezor") ? model : "Trezor \(model)"
    }

    private func deviceId(fromWatcherId watcherId: String) -> String {
        guard let range = watcherId.range(of: Constants.watcherIdSeparator) else { return watcherId }
        return String(watcherId[..<range.lowerBound])
    }

    private func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    // MARK: - Supporting types

    private struct WatcherSpec {
        let deviceId: String
        let walletId: String
        let addressType: String
        let xpub: String
        let electrumUrl: String

        var watcherId: String {
            "\(deviceId)\(Constants.watcherIdSeparator)\(addressType)"
        }
    }

    private struct DeviceGroup {
        let walletId: String
        let devices: [TrezorKnownDevice]

        var ids: Set<String> {
            Set(devices.map(\.id))
        }

        var representative: TrezorKnownDevice {
            devices.max(by: { $0.lastConnectedAt < $1.lastConnectedAt }) ?? devices[0]
        }
    }

    private struct HwWatcherData {
        let deviceId: String
        let balanceSats: UInt64
        let activities: [Activity]
    }
}
