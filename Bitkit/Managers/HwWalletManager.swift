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
    private let nowProvider: () -> UInt64

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

    /// First-seen wall-clock timestamp per unconfirmed txid, kept so a mempool tx stays at a
    /// stable position in the (timestamp-sorted) activity list across watcher events.
    private var assignedTimestamps: [String: UInt64] = [:]

    init(
        watcherService: OnChainWatcherServicing = OnChainHwService.shared,
        monitoredTypes: (() -> Set<String>)? = nil,
        electrumUrl: (() -> String)? = nil,
        network: (() -> TrezorCoinType)? = nil,
        persistActivities: (([Activity]) -> Void)? = nil,
        deleteActivities: ((String) -> Void)? = nil,
        now: (() -> UInt64)? = nil
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
                }
            }
        }
        self.deleteActivities = deleteActivities ?? { walletId in
            Task {
                try? await ServiceQueue.background(.core) {
                    _ = try BitkitCore.deleteActivitiesByWalletId(walletId: walletId)
                }
            }
        }
        nowProvider = now ?? { UInt64(Date().timeIntervalSince1970) }
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
        assignedTimestamps.removeAll()
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
            for (addressType, xpub) in device.xpubs where monitored.contains(addressType) {
                guard seen.insert("\(addressType)\u{1}\(xpub)").inserted else { continue }
                specs.append(WatcherSpec(deviceId: device.id, addressType: addressType, xpub: xpub, electrumUrl: electrumUrl))
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
            extendedKey: spec.xpub,
            electrumUrl: spec.electrumUrl,
            network: toNetwork(network),
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
    func handleWatcherEvent(watcherId: String, event: WatcherEvent) {
        guard case let .transactionsChanged(transactions, balance, _, _, _) = event else { return }
        let previous = watcherData[watcherId]
        watcherData[watcherId] = HwWatcherData(
            deviceId: deviceId(fromWatcherId: watcherId),
            balanceSats: balance.total,
            transactions: transactions
        )
        recomputeDerivedState()
        persistGroupActivities(forDevice: deviceId(fromWatcherId: watcherId))
        emitReceivedTxs(previous: previous, transactions: transactions)
    }

    private func emitReceivedTxs(previous: HwWatcherData?, transactions: [HistoryTransaction]) {
        guard let previous else { return }
        let knownTxIds = Set(previous.transactions.map(\.txid))
        for tx in transactions where tx.direction == .received {
            guard !knownTxIds.contains(tx.txid) else { continue }
            guard emittedReceivedTxIds.insert(tx.txid).inserted else { continue }
            receivedTxPublisher.send(HwWalletReceivedTx(txid: tx.txid, sats: tx.amount))
        }
    }

    // MARK: - Persistence

    private func persistGroupActivities(forDevice deviceId: String) {
        guard let group = deviceGroups().first(where: { $0.ids.contains(deviceId) }) else { return }
        persistActivities(mergedActivities(for: group))
    }

    private func mergedActivities(for group: DeviceGroup) -> [Activity] {
        let watchers = watcherData.values.filter { group.ids.contains($0.deviceId) }
        let grouped = Dictionary(grouping: watchers.flatMap(\.transactions), by: \.txid)
        return grouped.map { txid, transactions in
            let timestamp = resolveTimestamp(txid: txid, transactions: transactions)
            return onchainActivity(walletId: group.walletId, from: transactions, timestamp: timestamp)
        }
    }

    /// Confirmed txs carry a block timestamp; mempool txs report `nil`. Falling back to `0`
    /// would bury a fresh receive at the bottom of the timestamp-sorted activity list, so use
    /// the first-seen wall-clock time instead and remember it per txid until the tx confirms.
    private func resolveTimestamp(txid: String, transactions: [HistoryTransaction]) -> UInt64 {
        if let confirmed = transactions.compactMap(\.timestamp).min() {
            assignedTimestamps[txid] = nil
            return confirmed
        }
        if let assigned = assignedTimestamps[txid] {
            return assigned
        }
        let now = nowProvider()
        assignedTimestamps[txid] = now
        return now
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
            let walletId = HwWalletId.derive(xpubs: device.xpubs, fallbackId: device.id)
            if grouped[walletId] == nil { order.append(walletId) }
            grouped[walletId, default: []].append(device)
        }
        return order.compactMap { walletId in
            guard let devices = grouped[walletId] else { return nil }
            return DeviceGroup(walletId: walletId, devices: devices)
        }
    }

    private func onchainActivity(walletId: String, from transactions: [HistoryTransaction], timestamp: UInt64) -> Activity {
        let first = transactions[0]
        let received = transactions.reduce(UInt64(0)) { saturatingAdd($0, $1.received) }
        let sent = transactions.reduce(UInt64(0)) { saturatingAdd($0, $1.sent) }
        let fee = transactions.compactMap(\.fee).max() ?? 0

        // Classify by core's TxDirection (core 0.3.x): received-vs-sent arithmetic alone cannot
        // tell a self-transfer/consolidation apart from a normal send (both have sent > received,
        // since sent == received + fee), so without this a consolidation would show value 0
        // instead of the fee paid.
        let txType: PaymentType
        let value: UInt64
        switch first.direction {
        case .received:
            txType = .received
            value = received >= sent ? received - sent : 0
        case .sent:
            txType = .sent
            let net = sent >= received ? sent - received : 0
            value = net >= fee ? net - fee : 0
        case .selfTransfer:
            txType = .sent
            value = fee
        }
        let confirmations = transactions.map(\.confirmations).max() ?? 0
        let confirmed = confirmations > 0
        return .onchain(
            OnchainActivity(
                walletId: walletId,
                id: first.txid,
                txType: txType,
                txId: first.txid,
                value: value,
                fee: fee,
                feeRate: 1,
                address: "",
                confirmed: confirmed,
                timestamp: timestamp,
                isBoosted: false,
                boostTxIds: [],
                isTransfer: false,
                doesExist: true,
                confirmTimestamp: confirmed ? timestamp : nil,
                channelId: nil,
                transferTxId: nil,
                contact: nil,
                createdAt: timestamp,
                updatedAt: timestamp,
                seenAt: nil
            )
        )
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

    private func toNetwork(_ coin: TrezorCoinType) -> BitkitCore.Network {
        switch coin {
        case .bitcoin: .bitcoin
        case .testnet: .testnet
        case .signet: .signet
        case .regtest: .regtest
        }
    }

    private func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    // MARK: - Supporting types

    private struct WatcherSpec {
        let deviceId: String
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
        let transactions: [HistoryTransaction]
    }
}
