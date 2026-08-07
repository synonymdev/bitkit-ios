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
    private let persistSnapshot: @MainActor (HwWalletSnapshot) async throws -> Void
    private let deleteActivities: @MainActor (String) async throws -> Void

    /// One chain per wallet id, shared by both writes: a snapshot landing after the delete it was
    /// racing would resurrect the wallet `removeDevice` just wiped.
    private let persistQueue = SnapshotPersistQueue()

    // MARK: - Internal state

    private var knownDevices: [TrezorKnownDevice] = []
    private var connectedDeviceId: String?
    private var watcherData: [String: HwWatcherData] = [:]
    private var activeWatchers: Set<String> = []
    private var activeWatcherElectrumUrls: [String: String] = [:]

    /// Xpub each active watcher was started with. The watcher id is only `deviceId|addressType`, so
    /// the same physical device re-saved with a different xpub for that type (e.g. a passphrase/
    /// hidden wallet, or re-fetched accounts) keeps the same watcher id and derives a new wallet id.
    /// Tracked here so `syncWatchers()` restarts the watcher on the new xpub instead of leaving the
    /// old one feeding the old wallet's balance/activity under the new wallet id.
    private var activeWatcherXpubs: [String: String] = [:]
    private var retryingWatcherStarts: Set<String> = []

    /// Watchers whose async start is dispatched but not yet confirmed in `activeWatchers`.
    /// Guards against a second `syncWatchers()` double-starting the same watcher in that window.
    private var pendingWatcherStarts: Set<String> = []

    /// Last watcher-relevant settings seen by `reconcileForSettingsChange()`, so an unrelated
    /// settings change (theme, currency, …) doesn't trigger a needless watcher reconcile.
    private var lastSyncedMonitored: Set<String>?
    private var lastSyncedElectrumUrl: String?

    /// Memoized `HwWalletId.derive` results keyed by an xpubs signature. The mapping is
    /// deterministic and immutable, so caching avoids repeated FFI derivations on every watcher
    /// event and sync. Pruned to the live device set on `updateDevices`/`removeDevice`.
    private var walletIdCache: [String: String] = [:]

    /// Cache key of the last snapshot persisted per group wallet id, so an unchanged watcher event
    /// doesn't re-write the whole history to core and fire a redundant activity-list reload. The key
    /// carries `isComplete`, so a group that just became complete re-persists even when its merged
    /// content is byte-identical — that write is what applies the deletions the partial ones deferred.
    private var lastPersisted: [String: HwWalletSnapshot] = [:]

    private var emittedReceivedTxIds: Set<String> = []
    private var listeners: [String: TrezorEventListener] = [:]

    init(
        watcherService: OnChainWatcherServicing = OnChainHwService.shared,
        monitoredTypes: (() -> Set<String>)? = nil,
        electrumUrl: (() -> String)? = nil,
        network: (() -> TrezorCoinType)? = nil,
        persistSnapshot: (@MainActor (HwWalletSnapshot) async throws -> Void)? = nil,
        deleteActivities: (@MainActor (String) async throws -> Void)? = nil
    ) {
        self.watcherService = watcherService
        networkProvider = network ?? { OnChainHwService.appDefaultCoinType }
        monitoredTypesProvider = monitoredTypes ?? {
            Set(SettingsViewModel.shared.addressTypesToMonitor.map(\.stringValue))
        }
        electrumUrlProvider = electrumUrl ?? { OnChainHwService.getElectrumUrl() }
        // Both seams are plain writes: queueing, failure handling and cache repair live in
        // `persist(_:)` / `delete(walletId:)`, so an injected seam exercises them too.
        self.persistSnapshot = persistSnapshot ?? { snapshot in
            try await CoreService.shared.activity.replaceHwSnapshot(
                walletId: snapshot.walletId,
                activities: snapshot.activities,
                transactionDetails: snapshot.transactionDetails,
                pruneMissing: snapshot.isComplete,
                transferChannelIdsByFundingTxId: Self.transferChannelIdsByFundingTxId()
            )
        }
        self.deleteActivities = deleteActivities ?? { walletId in
            _ = try await CoreService.shared.activity.deleteByWalletId(walletId)
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

        // A device that dropped out of the snapshot (e.g. the user forgot it) would otherwise
        // leave its watch-only activities orphaned in the merged activity list, which queries
        // every wallet id. syncWatchers already stopped its watcher above; delete its persisted
        // activities too. Cleans up on any removal path, keeping us decoupled from TrezorManager.
        for walletId in previousWalletIds.subtracting(hwWalletIds) {
            delete(walletId: walletId)
        }
        pruneCaches()
    }

    // MARK: - Control

    /// Stop watching a paired hardware wallet and delete its stored activities. The caller is
    /// responsible for forgetting the device entries (via `TrezorManager.forgetDevice`); the next
    /// `updateDevices(...)` push then drops it from the tile list.
    func removeDevice(id deviceId: String) {
        let group = deviceGroups().first { $0.ids.contains(deviceId) }
        let ids = group?.ids ?? [deviceId]
        for watcherId in activeWatchers where ids.contains(self.deviceId(fromWatcherId: watcherId)) {
            _ = stopActiveWatcher(watcherId)
        }
        if let group {
            delete(walletId: group.walletId)
            lastPersisted[group.walletId] = nil
        }
        if let device = knownDevices.first(where: { $0.id == deviceId }) {
            walletIdCache[xpubsSignature(device.xpubs)] = nil
        }
        recomputeDerivedState()
    }

    /// Funding tx id → channel id for transfers the app recorded itself. `removeDevice` deletes a
    /// hardware wallet's activities but never touches these, so they are what lets a re-paired
    /// wallet's rediscovered funding tx read as a transfer again instead of a plain send. Only
    /// transfers that resolved a channel are usable; the rest are still unsettled, so
    /// `TransferService.syncTransferStates` re-marks those itself.
    ///
    /// Nothing hardware-specific is retained to make this work: the tx id comes back from the
    /// device's own watcher on re-pair, and these records belong to the still-open channel.
    private static func transferChannelIdsByFundingTxId() -> [String: String] {
        guard let transfers = try? TransferStorage.shared.getAll() else { return [:] }
        return Dictionary(
            transfers.compactMap { transfer -> (String, String)? in
                guard let fundingTxId = transfer.fundingTxId, let channelId = transfer.channelId else { return nil }
                return (fundingTxId, channelId)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Removes a hardware wallet and forgets every device entry that belongs to its wallet identity.
    func removeWallet(
        _ wallet: HwWallet,
        forgetDevice: (String) async -> Void
    ) async {
        removeDevice(id: wallet.id)
        for deviceId in wallet.deviceIds {
            await forgetDevice(deviceId)
        }
    }

    /// The bitkit-core wallet id scoping a paired device's activities. Throws when the device is
    /// unknown or has no captured xpubs, so callers that must write wallet-scoped data (e.g. the
    /// pending Transfer To Spending activity) fail loudly rather than writing to the wrong wallet.
    func walletId(forDevice deviceId: String) throws -> String {
        guard let group = deviceGroups().first(where: { $0.ids.contains(deviceId) }) else {
            throw AppError(message: "Unknown hardware wallet", debugMessage: "No wallet id for device '\(deviceId)'")
        }
        return group.walletId
    }

    // MARK: - Watcher orchestration

    /// Reconcile watchers in response to a settings change, but only when the monitored address
    /// types or the Electrum URL actually changed — `settingsPublisher` fires for every setting
    /// (theme, currency, …), and a full `syncWatchers()` re-derives each device's wallet id over
    /// the FFI, so we skip the work when nothing watcher-relevant moved.
    func reconcileForSettingsChange() {
        let monitored = monitoredTypesProvider()
        let electrumUrl = electrumUrlProvider()
        guard monitored != lastSyncedMonitored || electrumUrl != lastSyncedElectrumUrl else { return }
        lastSyncedMonitored = monitored
        lastSyncedElectrumUrl = electrumUrl
        syncWatchers()
    }

    func syncWatchers() {
        let specs = desiredWatcherSpecs()
        let desiredIds = Set(specs.map(\.watcherId))

        for spec in specs {
            // A start is already in flight for this watcher; skip so we don't launch a duplicate.
            // The next sync after it completes reconciles any electrum-url change.
            if pendingWatcherStarts.contains(spec.watcherId) { continue }
            let isActive = activeWatchers.contains(spec.watcherId)
            if isActive,
               activeWatcherElectrumUrls[spec.watcherId] == spec.electrumUrl,
               activeWatcherXpubs[spec.watcherId] == spec.xpub { continue }
            if isActive, !stopActiveWatcher(spec.watcherId) { continue }
            startWatcher(spec)
        }

        // A failed stop stays active so the next sync retries it; dropping it here would leave the
        // orphaned watcher feeding watcherData as a ghost balance.
        for staleId in activeWatchers.subtracting(desiredIds) {
            _ = stopActiveWatcher(staleId)
        }

        // Stopping a stale watcher clears its cached balance/activities; recompute so the published
        // totals reflect it immediately (a started watcher recomputes again on its first event).
        recomputeDerivedState()
    }

    /// Build the watcher specs the current device/settings snapshot wants running: one per
    /// (device, monitored address type), deduped by (addressType, xpub) and scoped to the
    /// device's derived wallet id (devices without xpubs are skipped).
    private func desiredWatcherSpecs() -> [WatcherSpec] {
        let monitored = monitoredTypesProvider()
        let electrumUrl = electrumUrlProvider()

        var seen = Set<String>()
        var specs: [WatcherSpec] = []
        for device in knownDevices {
            guard let walletId = walletId(for: device.xpubs) else { continue }
            for (addressType, xpub) in device.xpubs where monitored.contains(addressType) {
                guard seen.insert(dedupKey(addressType: addressType, xpub: xpub)).inserted else { continue }
                specs.append(WatcherSpec(deviceId: device.id, walletId: walletId, addressType: addressType, xpub: xpub, electrumUrl: electrumUrl))
            }
        }
        return specs
    }

    /// Identity for deduping watchers across devices that share an (addressType, xpub). Uses a
    /// control-character separator that can't appear in either component.
    private func dedupKey(addressType: String, xpub: String) -> String {
        "\(addressType)\u{1}\(xpub)"
    }

    /// Derive (and memoize) the wallet id for a device's xpubs. Returns nil when derivation fails
    /// (e.g. no captured xpubs — `HwWalletId.derive` throws on empty), so callers skip the device.
    private func walletId(for xpubs: [String: String]) -> String? {
        let signature = xpubsSignature(xpubs)
        if let cached = walletIdCache[signature] { return cached }
        guard let derived = try? HwWalletId.derive(xpubs: xpubs) else { return nil }
        walletIdCache[signature] = derived
        return derived
    }

    private func xpubsSignature(_ xpubs: [String: String]) -> String {
        xpubs.sorted { $0.key < $1.key }
            .map { dedupKey(addressType: $0.key, xpub: $0.value) }
            .joined(separator: "\u{1f}")
    }

    /// Drop cache entries for devices no longer in the snapshot, so the caches stay bounded to
    /// live devices.
    private func pruneCaches() {
        let liveSignatures = Set(knownDevices.filter { !$0.xpubs.isEmpty }.map { xpubsSignature($0.xpubs) })
        walletIdCache = walletIdCache.filter { liveSignatures.contains($0.key) }
        lastPersisted = lastPersisted.filter { hwWalletIds.contains($0.key) }
    }

    private func startWatcher(_ spec: WatcherSpec) {
        guard let addressType = AddressScriptType.from(string: spec.addressType) else { return }
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
                activeWatcherXpubs[spec.watcherId] = spec.xpub
                retryingWatcherStarts.remove(spec.watcherId)
                syncWatchers()
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
            activeWatcherXpubs[watcherId] = nil
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
        guard case let .transactionsChanged(activities, transactionDetails, balance, _, _, _) = event else { return }
        let deviceId = deviceId(fromWatcherId: watcherId)
        let previous = watcherData[watcherId]
        watcherData[watcherId] = HwWatcherData(
            deviceId: deviceId,
            balanceSats: balance.total,
            activities: activities,
            transactionDetails: transactionDetails
        )
        let groups = deviceGroups()
        recomputeDerivedState(groups: groups)
        persistGroupSnapshot(forDevice: deviceId, groups: groups)
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

    private func persistGroupSnapshot(forDevice deviceId: String, groups: [DeviceGroup]? = nil) {
        let groups = groups ?? deviceGroups()
        guard let group = groups.first(where: { $0.ids.contains(deviceId) }) else { return }

        let missing = missingWatcherIds(for: group)
        let snapshot = mergedSnapshot(for: group, isComplete: missing.isEmpty)
        // Skip the core write + activity-list reload when nothing meaningful changed for this group.
        let cacheKey = snapshotCacheKey(for: snapshot)
        guard lastPersisted[group.walletId] != cacheKey else { return }
        lastPersisted[group.walletId] = cacheKey

        if !missing.isEmpty {
            Logger.debug(
                "Partial HW snapshot for '\(group.walletId)': deletions deferred until \(missing.sorted()) report",
                context: "HwWalletManager"
            )
        }
        persist(snapshot)
    }

    private func persist(_ snapshot: HwWalletSnapshot) {
        let cacheKey = snapshotCacheKey(for: snapshot)
        persistQueue.enqueue(walletId: snapshot.walletId) { [weak self] in
            guard let self else { return }
            do {
                try await persistSnapshot(snapshot)
            } catch {
                // `persistGroupSnapshot` recorded this snapshot as persisted before the write was
                // queued, so leaving the entry in place would dedupe away every identical retry and
                // strand the wallet — including a complete snapshot's pending deletions.
                invalidatePersistCache(walletId: snapshot.walletId, ifStill: cacheKey)
                Logger.error("Failed to persist HW snapshot for '\(snapshot.walletId)': \(error)", context: "HwWalletManager")
            }
        }
    }

    private func delete(walletId: String) {
        persistQueue.enqueue(walletId: walletId) { [weak self] in
            do {
                try await self?.deleteActivities(walletId)
            } catch {
                Logger.error("Failed to delete activities for HW wallet '\(walletId)': \(error)", context: "HwWalletManager")
            }
        }
    }

    /// Drop a failed write's dedupe entry so an identical watcher snapshot retries instead of being
    /// skipped. Only when a later snapshot has not already replaced it: that one supersedes this
    /// failure, so clearing its key would just force a redundant re-write.
    private func invalidatePersistCache(walletId: String, ifStill cacheKey: HwWalletSnapshot) {
        guard lastPersisted[walletId] == cacheKey else { return }
        lastPersisted[walletId] = nil
    }

    /// Await every queued write. Test seam — assertions on persisted state would otherwise race the
    /// per-wallet chain.
    func drainPendingPersists() async {
        await persistQueue.drainAll()
    }

    /// Watcher ids the current device/settings snapshot wants for this group that have not reported
    /// yet. Non-empty means a merged snapshot covers only part of the wallet, so it must not prune:
    /// deleting a row the silent watcher owns would take its tags with it (core cascades the delete
    /// into `activity_tags`, and hardware tags are left out of the backup payload).
    ///
    /// Deliberately `desiredWatcherSpecs()` and not `activeWatchers`: on cold start the sibling
    /// watcher is still mid-`startWatcher`, and a not-yet-active watcher still owns stored rows.
    /// A watcher that never manages to start therefore suspends pruning for its wallet — a lingering
    /// replaced row is cosmetic and self-heals on the first successful sync, which is the cheaper
    /// failure than destroying tags.
    private func missingWatcherIds(for group: DeviceGroup) -> Set<String> {
        Set(desiredWatcherSpecs().lazy.filter { $0.walletId == group.walletId }.map(\.watcherId))
            .subtracting(watcherData.keys)
    }

    /// An unconfirmed activity's timestamp is "now" from the watcher's perspective, so it ticks on
    /// every poll even when nothing about the transaction changed. Zeroing it keeps a mempool
    /// transaction from re-writing the whole group to core on each event.
    private func snapshotCacheKey(for snapshot: HwWalletSnapshot) -> HwWalletSnapshot {
        HwWalletSnapshot(
            walletId: snapshot.walletId,
            activities: snapshot.activities.map { activity in
                guard case var .onchain(onchain) = activity, !onchain.confirmed else { return activity }
                onchain.timestamp = 0
                return .onchain(onchain)
            },
            transactionDetails: snapshot.transactionDetails,
            isComplete: snapshot.isComplete
        )
    }

    /// Aggregate what core emitted across a device-group's watchers, scoping each activity and
    /// transaction-details row to the group's wallet id and deduping (so the same tx seen by two
    /// address-type watchers persists once). Watchers are walked in sorted `watcherId` order and the
    /// results are sorted by id, so a tx observed by multiple address-type watchers (which can carry
    /// different wallet-perspective directions) resolves to a deterministic winner — the
    /// highest-ordered watcherId — rather than depending on dictionary iteration order.
    private func mergedSnapshot(for group: DeviceGroup, isComplete: Bool) -> HwWalletSnapshot {
        let watchers = watcherData
            .filter { group.ids.contains($0.value.deviceId) }
            .sorted { $0.key < $1.key }
            .map(\.value)

        var activitiesById: [String: Activity] = [:]
        for activity in watchers.flatMap(\.activities) {
            let scoped = scopedToWallet(activity, walletId: group.walletId)
            activitiesById[scoped.activityId] = scoped
        }

        var detailsByTxId: [String: TransactionDetails] = [:]
        for var details in watchers.flatMap(\.transactionDetails) {
            details.walletId = group.walletId
            detailsByTxId[details.txId] = details
        }

        return HwWalletSnapshot(
            walletId: group.walletId,
            activities: activitiesById.values.sorted { $0.activityId < $1.activityId },
            transactionDetails: detailsByTxId.values.sorted { $0.txId < $1.txId },
            isComplete: isComplete
        )
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

    // MARK: - Aggregation

    private func recomputeDerivedState(groups: [DeviceGroup]? = nil) {
        let groups = groups ?? deviceGroups()

        wallets = groups.map { group in
            let connectedDevice = group.devices.first { $0.id == connectedDeviceId }
            let device = connectedDevice ?? group.representative
            let deviceWatchers = watcherData.values.filter { group.ids.contains($0.deviceId) }
            return HwWallet(
                id: device.id,
                walletId: group.walletId,
                name: device.displayName,
                model: device.model,
                isConnected: connectedDevice != nil,
                balanceSats: deviceWatchers.reduce(UInt64(0)) { $0.saturatingAdd($1.balanceSats) },
                fundingBalanceSats: fundingBalance(group: group, addressType: hwFundingDefaultAddressType),
                deviceIds: group.ids
            )
        }

        totalSats = wallets.reduce(UInt64(0)) { $0.saturatingAdd($1.balanceSats) }
        hwWalletIds = Set(groups.map(\.walletId))
    }

    /// Group device entries sharing an xpub identity (same physical device over different
    /// transports), preserving first-seen order. Entries without captured xpubs are skipped.
    private func deviceGroups() -> [DeviceGroup] {
        var order: [String] = []
        var grouped: [String: [TrezorKnownDevice]] = [:]
        for device in knownDevices where !device.xpubs.isEmpty {
            guard let walletId = walletId(for: device.xpubs) else { continue }
            if grouped[walletId] == nil { order.append(walletId) }
            grouped[walletId, default: []].append(device)
        }
        return order.compactMap { walletId in
            guard let devices = grouped[walletId] else { return nil }
            return DeviceGroup(walletId: walletId, devices: devices)
        }
    }

    // MARK: - Funding (transfer to spending)

    /// The watch-only balance available to fund a transfer to spending from `deviceId`, sourced from
    /// the given address-type account only (v1: native segwit). Does not require a connected device.
    func fundingBalance(deviceId: String, addressType: AddressScriptType = hwFundingDefaultAddressType) -> UInt64 {
        guard let group = deviceGroups().first(where: { $0.ids.contains(deviceId) }) else { return 0 }
        return fundingBalance(group: group, addressType: addressType)
    }

    private func fundingBalance(group: DeviceGroup, addressType: AddressScriptType) -> UInt64 {
        watcherData
            .filter { group.ids.contains($0.value.deviceId) && self.addressType(fromWatcherId: $0.key) == addressType.stringValue }
            .reduce(UInt64(0)) { $0.saturatingAdd($1.value.balanceSats) }
    }

    /// Resolve the funding account (xpub + watch-only balance) for a paired device. Does not require
    /// a connected device — the xpub is read from the stored known-device record and the balance
    /// from the running watchers.
    func getFundingAccount(
        deviceId: String,
        addressType: AddressScriptType = hwFundingDefaultAddressType
    ) throws -> HwFundingAccount {
        guard let device = knownDevices.first(where: { $0.id == deviceId }) else {
            throw AppError(message: "Unknown hardware wallet", debugMessage: "No known device '\(deviceId)'")
        }
        guard let xpub = device.xpubs[addressType.stringValue] else {
            throw AppError(
                message: "Missing account",
                debugMessage: "Device '\(deviceId)' has no '\(addressType.stringValue)' account xpub"
            )
        }
        return HwFundingAccount(
            xpub: xpub,
            addressType: addressType,
            balanceSats: fundingBalance(deviceId: deviceId, addressType: addressType)
        )
    }

    /// The exact amount spendable from the funding account after the real coin-selection mining fee,
    /// computed offline via a `sendMax` compose. No connected device is needed — `fingerprint` is only
    /// required for signing — so this mirrors the software wallet's max-sendable estimate.
    /// `destinationAddress` is a fee-estimation destination only (never broadcast).
    func maxSpendableFunding(
        deviceId: String,
        destinationAddress: String,
        satsPerVByte: UInt64,
        addressType: AddressScriptType = hwFundingDefaultAddressType
    ) async throws -> UInt64 {
        let account = try getFundingAccount(deviceId: deviceId, addressType: addressType)
        let params = ComposeParams(
            wallet: WalletParams(
                extendedKey: account.xpub,
                electrumUrl: electrumUrlProvider(),
                fingerprint: nil,
                network: networkProvider().coreNetwork,
                accountType: account.accountType
            ),
            outputs: [.sendMax(address: destinationAddress)],
            feeRates: [Float(satsPerVByte)],
            coinSelection: .branchAndBound
        )
        let results = try await OnChainHwService.shared.composeTransaction(params: params)
        for result in results {
            if case let .success(_, fee, _, totalSpent) = result {
                return totalSpent > fee ? totalSpent - fee : 0
            }
        }
        let composeError: String? = results.compactMap {
            if case let .error(error) = $0 { return error } else { return nil }
        }.first
        throw AppError(
            message: "Failed to estimate hardware funding amount",
            debugMessage: composeError ?? "No successful compose result"
        )
    }

    /// Compose the exact on-chain funding payment before prompting for the on-device signature.
    /// Requires the device to be connected (the fingerprint drives the PSBT derivation paths); the
    /// caller must ensure the Trezor is connected first (via `TrezorManager`).
    func composeFundingTransaction(
        deviceId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        addressType: AddressScriptType = hwFundingDefaultAddressType
    ) async throws -> HwFundingTransaction {
        let fingerprint = try await TrezorService.shared.getDeviceFingerprint()
        return try await composeFundingTransactionInternal(
            deviceId: deviceId,
            address: address,
            sats: sats,
            satsPerVByte: satsPerVByte,
            fingerprint: fingerprint,
            addressType: addressType
        )
    }

    /// Offline coin-selection for the exact funding amount; returns the mining fee only.
    func estimateOfflineFundingMiningFee(
        deviceId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        addressType: AddressScriptType = hwFundingDefaultAddressType
    ) async throws -> UInt64 {
        let funding = try await composeFundingTransactionInternal(
            deviceId: deviceId,
            address: address,
            sats: sats,
            satsPerVByte: satsPerVByte,
            fingerprint: nil,
            addressType: addressType
        )
        return funding.miningFeeSats
    }

    private func composeFundingTransactionInternal(
        deviceId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        fingerprint: String?,
        addressType: AddressScriptType
    ) async throws -> HwFundingTransaction {
        let account = try getFundingAccount(deviceId: deviceId, addressType: addressType)
        let network = networkProvider()
        let params = ComposeParams(
            wallet: WalletParams(
                extendedKey: account.xpub,
                electrumUrl: electrumUrlProvider(),
                fingerprint: fingerprint,
                network: network.coreNetwork,
                accountType: account.accountType
            ),
            outputs: [.payment(address: address, amountSats: sats)],
            feeRates: [Float(satsPerVByte)],
            coinSelection: .branchAndBound
        )
        let results = try await OnChainHwService.shared.composeTransaction(params: params)
        for result in results {
            if case let .success(psbt, fee, feeRate, totalSpent) = result {
                return HwFundingTransaction(
                    psbt: psbt,
                    miningFeeSats: fee,
                    feeRate: feeRate,
                    totalSpent: totalSpent,
                    satsPerVByte: satsPerVByte
                )
            }
        }
        let composeError: String? = results.compactMap {
            if case let .error(error) = $0 { return error } else { return nil }
        }.first
        throw AppError(
            message: "Failed to compose hardware transfer",
            debugMessage: composeError ?? "No successful compose result"
        )
    }

    /// Sign a composed funding payment on the device. Requires the device to be connected. On signing
    /// failure the caller is responsible for clearing the stale session (via
    /// `TrezorManager.disconnectStaleSession`). Broadcasting is a separate step so a device-signing
    /// timeout is never conflated with an in-flight broadcast.
    func signFunding(
        deviceId _: String,
        funding: HwFundingTransaction
    ) async throws -> HwFundingSignedTx {
        let network = networkProvider()
        let signed = try await TrezorService.shared.signTxFromPsbt(psbtBase64: funding.psbt, network: network)
        return HwFundingSignedTx(
            serializedTx: signed.serializedTx,
            miningFeeSats: funding.miningFeeSats,
            feeRate: funding.feeRate,
            totalSpent: funding.totalSpent
        )
    }

    /// Broadcast a signed funding transaction and return its txid. Does not require a connected device.
    func broadcastFunding(serializedTx: String) async throws -> String {
        try await OnChainHwService.shared.broadcastRawTx(
            serializedTx: serializedTx,
            electrumUrl: electrumUrlProvider()
        )
    }

    // MARK: - Helpers

    private func deviceId(fromWatcherId watcherId: String) -> String {
        guard let range = watcherId.range(of: Constants.watcherIdSeparator) else { return watcherId }
        return String(watcherId[..<range.lowerBound])
    }

    private func addressType(fromWatcherId watcherId: String) -> String {
        guard let range = watcherId.range(of: Constants.watcherIdSeparator) else { return "" }
        return String(watcherId[range.upperBound...])
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
        let transactionDetails: [TransactionDetails]
    }
}

/// Serialises hardware-wallet writes per wallet id. Each snapshot supersedes the previous one, so a
/// write that lands out of order would resurrect rows a later snapshot pruned — or a whole wallet
/// that `removeDevice` just deleted. MainActor-isolated, so the chaining itself is race-free.
@MainActor
final class SnapshotPersistQueue {
    private var tails: [String: Task<Void, Never>] = [:]

    func enqueue(walletId: String, _ work: @escaping @MainActor () async -> Void) {
        let previous = tails[walletId]
        tails[walletId] = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Await every write queued so far. Test seam — see `HwWalletManager.drainPendingPersists()`.
    func drainAll() async {
        for task in tails.values {
            await task.value
        }
    }
}
