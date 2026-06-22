import BitkitCore
import Combine
import Foundation

/// Production hardware-wallet business layer. Tracks paired Trezor devices as watch-only
/// balances by running one on-chain xpub watcher per (device, address type), aggregating the
/// per-device balance in memory, and persisting each device's on-chain activity into
/// bitkit-core scoped by a derived `walletId` (core 0.3.x wallet-scoped storage).
///
/// Built on top of `TrezorViewModel`, which owns the device list, connect orchestration and the
/// underlying watcher transport. Adapts bitkit-android's `HwWalletRepo`. iOS supports Bluetooth
/// only, so the cross-transport (BLE+USB) dedup is reduced to a plain xpub-based identity and
/// USB-specific reconnect handling is omitted.
@Observable
@MainActor
final class HwWalletRepo {
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

    private weak var trezor: TrezorViewModel?
    private let watcherService: TrezorWatcherServicing
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
    private var emittedReceivedTxIds: Set<String> = []
    private var listeners: [String: TrezorEventListener] = [:]

    init(
        trezor: TrezorViewModel? = nil,
        watcherService: TrezorWatcherServicing = TrezorService.shared,
        monitoredTypes: (() -> Set<String>)? = nil,
        electrumUrl: (() -> String)? = nil,
        network: (() -> TrezorCoinType)? = nil,
        persistActivities: (([Activity]) -> Void)? = nil,
        deleteActivities: ((String) -> Void)? = nil
    ) {
        self.trezor = trezor
        self.watcherService = watcherService
        networkProvider = network ?? { TrezorViewModel.appDefaultCoinType }
        monitoredTypesProvider = monitoredTypes ?? {
            Set(SettingsViewModel.shared.addressTypesToMonitor.map(\.stringValue))
        }
        electrumUrlProvider = electrumUrl ?? { TrezorViewModel.getElectrumUrl() }
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
    }

    // MARK: - Lifecycle

    /// Begin observing the Trezor device state and start the initial watcher sync.
    func start() {
        observeTrezorState()
        refreshFromTrezor()
    }

    /// Re-read device state and monitored settings, then reconcile watchers.
    func refresh() {
        refreshFromTrezor()
    }

    /// On app foreground, ask the Trezor layer to reconnect a known device so the connection
    /// indicator turns green again; watch-only balances stay live regardless.
    func onAppForegrounded() {
        guard let trezor else { return }
        Task { await trezor.autoReconnect() }
    }

    private func refreshFromTrezor() {
        guard let trezor else {
            syncWatchers()
            recomputeDerivedState()
            return
        }
        updateDevices(knownDevices: trezor.knownDevices, connectedDeviceId: trezor.connectedDevice?.id)
    }

    private func observeTrezorState() {
        guard let trezor else { return }
        withObservationTracking {
            _ = trezor.knownDevices.map { "\($0.id):\($0.xpubs.count)" }
            _ = trezor.connectedDevice?.id
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshFromTrezor()
                self.observeTrezorState()
            }
        }
    }

    /// Update the device snapshot and reconcile watchers. Exposed for tests so the engine can be
    /// exercised without a live `TrezorViewModel`.
    func updateDevices(knownDevices: [TrezorKnownDevice], connectedDeviceId: String?) {
        self.knownDevices = knownDevices
        self.connectedDeviceId = connectedDeviceId
        walletsLoaded = true
        syncWatchers()
        recomputeDerivedState()
    }

    // MARK: - Pairing passthroughs

    var needsPairingCode: Bool {
        trezor?.showPairingCode ?? false
    }

    func submitPairingCode(_ code: String) {
        trezor?.submitPairingCode(code)
    }

    func cancelPairingCode() {
        trezor?.cancelPairingCode()
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
        emittedReceivedTxIds.removeAll()
        listeners.removeAll()
        watcherData.removeAll()
        recomputeDerivedState()
    }

    /// Remove a paired hardware wallet: stop its watchers, delete its stored activities, and
    /// forget every device entry that shares the same xpub-derived identity, so the tile doesn't
    /// reappear through another entry.
    func removeDevice(id deviceId: String) async {
        let group = deviceGroups().first { $0.ids.contains(deviceId) }
        let ids = group?.ids ?? [deviceId]
        for watcherId in activeWatchers where ids.contains(self.deviceId(fromWatcherId: watcherId)) {
            _ = stopActiveWatcher(watcherId)
        }
        if let group { deleteActivities(group.walletId) }
        if let trezor {
            for id in ids {
                await trezor.forgetDevice(id: id)
            }
        }
        refreshFromTrezor()
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

        Task { @MainActor in
            do {
                try await watcherService.startWatcher(params: params, listener: listener)
                activeWatchers.insert(spec.watcherId)
                activeWatcherElectrumUrls[spec.watcherId] = spec.electrumUrl
                retryingWatcherStarts.remove(spec.watcherId)
            } catch {
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
        return grouped.values.map { transactions in
            let timestamp = transactions.compactMap(\.timestamp).min() ?? 0
            return onchainActivity(walletId: group.walletId, from: transactions, timestamp: timestamp)
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
        let txType: PaymentType = received > sent ? .received : .sent
        let value: UInt64
        switch txType {
        case .received:
            value = received >= sent ? received - sent : 0
        case .sent:
            let net = sent >= received ? sent - received : 0
            value = net >= fee ? net - fee : 0
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
