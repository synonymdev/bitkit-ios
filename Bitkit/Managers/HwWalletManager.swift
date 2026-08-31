import BitkitCore
import Combine
import Foundation

/// Production hardware-wallet business layer. Tracks paired Trezor wallets as watch-only
/// balances by running one on-chain xpub watcher per (wallet, address type), aggregating the
/// per-wallet balance in memory, and persisting each wallet's on-chain activity into
/// bitkit-core scoped by its `walletId` (core 0.3.x wallet-scoped storage).
///
/// Keyed by wallet identity, not by device: a Trezor with passphrase protection holds its standard
/// wallet plus one identity per hidden wallet, all reached over the same transport id.
///
/// Tile and watcher state come solely from `updateDevices(...)`, fed by the composition root
/// (`AppScene`). The identity-aware session operations — opening a passphrase wallet, proving the
/// live session belongs to the wallet being spent from — additionally read the device through the
/// injected `HwDeviceSessioning` seam, and read the stored entries fresh from it: a connect that
/// just wrote one lands there before the push does. Never references `TrezorManager` concretely.
///
@Observable
@MainActor
final class HwWalletManager {
    private enum Constants {
        static let watcherIdSeparator = "|"
        static let watcherStartRetryDelay: Duration = .seconds(30)
        static let defaultGapLimit: UInt32 = 20
    }

    // MARK: - Published state

    /// Paired hardware wallets, one per wallet identity, with aggregated balance.
    private(set) var wallets: [HwWallet] = []

    /// Sum of every paired wallet's balance.
    private(set) var totalSats: UInt64 = 0

    /// Largest funding-account balance held by one paired hardware wallet. Hardware and software
    /// balances are separate funding sources; fee-adjusted availability is resolved in the send flow.
    var maximumFundingBalanceSats: UInt64 {
        wallets.map(\.fundingBalanceSats).max() ?? 0
    }

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
    private let readTagMetadata: @MainActor (String) async throws -> [PreActivityMetadata]
    private let writeTagMetadata: @MainActor ([PreActivityMetadata]) async throws -> Void

    /// The live device session. Only the identity-aware operations need it; tile and watcher state
    /// still come solely from `updateDevices(...)`. Nil in previews and in tests that don't reach
    /// the device.
    private weak var session: HwDeviceSessioning?

    /// One chain per wallet id, shared by both writes: a snapshot landing after the delete it was
    /// racing would resurrect the wallet `removeDevice` just wiped.
    private let persistQueue = SnapshotPersistQueue()

    // MARK: - Internal state

    private var knownDevices: [TrezorKnownDevice] = []
    private var connectedDeviceId: String?
    private var connectedWalletId: String?
    private var watcherData: [String: HwWatcherData] = [:]
    private var activeWatchers: Set<String> = []
    private var activeWatcherElectrumUrls: [String: String] = [:]
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

    /// Tag metadata a removal asked to keep, re-applied after every delete of its wallet. Read at the
    /// moment each delete runs rather than captured, so a later removal replaces it — or clears it,
    /// when that one keeps nothing.
    ///
    /// Deliberately outlives the removal: a cleanup delete can arrive long afterwards, from a push
    /// that re-added the wallet and then dropped it again, and re-applying is what keeps it from
    /// taking the rows with it.
    private var keptBackupMetadata: [String: [PreActivityMetadata]] = [:]

    private var emittedReceivedTxIds: Set<String> = []
    private var listeners: [String: TrezorEventListener] = [:]
    private var staleSessionCleanupTasks: [String: Task<Void, Never>] = [:]

    init(
        session: HwDeviceSessioning? = nil,
        watcherService: OnChainWatcherServicing = OnChainHwService.shared,
        monitoredTypes: (() -> Set<String>)? = nil,
        electrumUrl: (() -> String)? = nil,
        network: (() -> TrezorCoinType)? = nil,
        persistSnapshot: (@MainActor (HwWalletSnapshot) async throws -> Void)? = nil,
        deleteActivities: (@MainActor (String) async throws -> Void)? = nil,
        readTagMetadata: (@MainActor (String) async throws -> [PreActivityMetadata])? = nil,
        writeTagMetadata: (@MainActor ([PreActivityMetadata]) async throws -> Void)? = nil
    ) {
        self.session = session
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
        self.readTagMetadata = readTagMetadata ?? { walletId in
            try await CoreService.shared.activity.tagMetadata(forWallet: walletId)
        }
        self.writeTagMetadata = writeTagMetadata ?? { records in
            try await CoreService.shared.activity.upsertPreActivityMetadata(records)
        }
    }

    // MARK: - Device input

    /// Update the device snapshot and reconcile watchers. This is the manager's sole input: the
    /// composition root (`AppScene`) feeds it the current Trezor device list, so this type stays
    /// fully decoupled from `TrezorManager`. Also the test seam — tests drive it directly.
    ///
    /// `connectedWalletId` is the identity the live session opened. A device holds one wallet open
    /// at a time, so it is what decides which tile shows as connected.
    func updateDevices(
        knownDevices: [TrezorKnownDevice],
        connectedDeviceId: String?,
        connectedWalletId: String? = nil
    ) {
        let previousWalletIds = hwWalletIds
        self.knownDevices = knownDevices
        self.connectedDeviceId = connectedDeviceId
        self.connectedWalletId = connectedWalletId
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

    /// Stop watching a paired hardware wallet and delete its stored activities. Other wallets on the
    /// same physical device are left untouched. The caller is responsible for forgetting the stored
    /// entries (via `TrezorManager`).
    ///
    /// - Parameter keptMetadata: tag metadata to re-apply after each delete of this wallet, or empty
    /// to keep nothing. Passed on every call so a removal that keeps nothing clears what an earlier
    /// one left behind.
    func removeDevice(walletId: String, keptMetadata: [PreActivityMetadata] = []) {
        keptBackupMetadata[walletId] = keptMetadata.isEmpty ? nil : keptMetadata
        for watcherId in activeWatchers where self.walletId(fromWatcherId: watcherId) == walletId {
            _ = stopActiveWatcher(watcherId)
        }
        delete(walletId: walletId)
        lastPersisted[walletId] = nil
        for device in knownDevices where device.resolvedWalletId == walletId {
            walletIdCache[xpubsSignature(device.xpubs)] = nil
        }
        // Dropped here rather than left to the next `updateDevices(...)` push. Until the wallet leaves
        // `hwWalletIds`, the push's own cleanup deletes its activities a second time — after any kept
        // metadata was written back — and `deviceGroups()` still yields the group, so a watcher event
        // arriving in that window re-persists the activities this just deleted.
        knownDevices.removeAll { $0.resolvedWalletId == walletId }
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

    /// Removes a hardware wallet and forgets every stored entry that belongs to its wallet identity.
    /// Other wallets of the same physical device stay paired.
    ///
    /// - Parameter keepBackupData: whether to carry the wallet's name and tags in the backup, so
    /// re-pairing the device restores them. Core deletes a wallet's activities, its activity tags and
    /// its pre-activity metadata in one cascade, which is both of the sources the metadata envelope
    /// draws hardware tags from, so without this a removal silently empties the backup of them.
    func removeWallet(walletId: String, keepBackupData: Bool) async throws {
        // Everything here reads; nothing has been deleted yet, so a failure leaves the wallet whole.
        var keptName: String?
        var keptMetadata: [PreActivityMetadata] = []
        if keepBackupData {
            keptName = entries(for: walletId)
                .lazy
                .compactMap { $0.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            do {
                keptMetadata = try await readTagMetadata(walletId)
            } catch {
                // Refused rather than reported as a failed removal: the wallet is untouched, so the
                // choice stays with the user — retry, or remove it without keeping the data.
                Logger.error("Failed to read tag metadata of HW wallet '\(walletId)': \(error)", context: "HwWalletManager")
                throw HwWalletRemovalError.backupDataUnreadable
            }
        }

        removeDevice(walletId: walletId, keptMetadata: keptMetadata)
        // The name rides the same store write that forgets the entries carrying it. A nil name is
        // passed deliberately when keeping nothing: it drops a name an earlier removal kept.
        await session?.forgetWallet(
            walletId: walletId,
            pendingName: PendingHwWalletName(walletId: walletId, name: keptName)
        )
    }

    // MARK: - Wallet identity & the device session

    /// Stored entries tracking one wallet identity, read fresh: a connect that just wrote one lands
    /// there before the `updateDevices(...)` push does.
    private func entries(for walletId: String) -> [TrezorKnownDevice] {
        (session?.storedDevices ?? knownDevices).filter { $0.resolvedWalletId == walletId }
    }

    /// Transport id to reach `walletId` with: the connected entry, else the most recently used one.
    private func transportDeviceId(for walletId: String) -> String? {
        let entries = entries(for: walletId)
        if let connected = entries.first(where: { $0.id == session?.connectedDeviceId }) { return connected.id }
        return entries.max(by: { $0.lastConnectedAt < $1.lastConnectedAt })?.id
    }

    private func requireTransportDeviceId(for walletId: String) throws -> String {
        guard let deviceId = transportDeviceId(for: walletId) else {
            throw AppError(message: "Unknown hardware wallet", debugMessage: "No paired device for wallet '\(walletId)'")
        }
        return deviceId
    }

    /// Fails unless the live session is provably `walletId`'s.
    ///
    /// A session reports no identity precisely when its accounts could not be read, which says
    /// nothing about which seed it holds — a device that opened a hidden wallet and then failed the
    /// read looks exactly like one that opened nothing. So an unresolved session is refused rather
    /// than tolerated, and the caller either reopens the wallet or reports that it is out of reach.
    ///
    /// Only the passphrase reopens a hidden wallet, so that is what a hidden target asks for. For any
    /// other wallet the device is simply not holding it, which no passphrase can fix.
    private func requireIdentity(of walletId: String) throws {
        let opened = session?.connectedWalletId
        guard opened != walletId else { return }
        guard !entries(for: walletId).contains(where: \.passphraseProtected) else {
            throw HwPassphraseError.required
        }
        throw AppError(
            message: "Reconnect Hardware Device",
            debugMessage: "The live session holds '\(opened ?? "no resolved wallet")', not '\(walletId)'"
        )
    }

    private func watchedWalletIds() -> Set<String> {
        Set((session?.storedDevices ?? knownDevices).compactMap(\.resolvedWalletId))
    }

    /// Opens the passphrase (hidden) wallet of an already paired device and starts watching it as
    /// its own identity, returning its wallet id. The passphrase is bound to a fresh Trezor session
    /// and is never persisted; re-entering it is what makes the wallet reachable again.
    func connectWithPassphrase(deviceId: String, passphrase: String) async throws -> String {
        guard let session else {
            throw AppError(message: "Unavailable", debugMessage: "No device session to open a passphrase wallet with")
        }
        await waitForStaleSessionCleanup(deviceId: deviceId)
        // Absent features mean there is nothing to read the setting from — a session that dropped
        // between pairing and this call — which is a reconnect problem and not a device that refuses
        // hidden wallets.
        guard let features = session.connectedFeatures else {
            throw AppError(
                message: "Reconnect Hardware Device",
                debugMessage: "No live session on '\(deviceId)' to open a passphrase wallet with"
            )
        }
        // A device with passphrase protection turned off ignores the passphrase and simply reopens
        // the standard wallet, which would surface as "already added" and leave the user retyping a
        // passphrase that can never take effect. A device that does not report the setting at all is
        // treated the same way, since attempting the open would fail just as silently.
        guard features.passphraseProtection == true else {
            throw HwPassphraseError.protectionDisabled
        }

        let watchedBefore = watchedWalletIds()
        try await session.connectWithWalletMode(deviceId: deviceId, mode: .passphraseHost, passphrase: passphrase)
        guard let opened = session.connectedWalletId else {
            throw AppError(
                message: "Couldn't read the passphrase wallet",
                debugMessage: "No accounts resolved for the passphrase wallet on '\(deviceId)'"
            )
        }
        guard !watchedBefore.contains(opened) else { throw HwPassphraseError.alreadyAdded }
        return opened
    }

    /// Makes the device session belong to `walletId`, not merely to its transport. A device holds one
    /// identity open at a time, so a session opened for another wallet on the same device would
    /// otherwise be accepted and sign with the wrong seed. The standard wallet needs no secret to
    /// reopen; a passphrase wallet does, which the caller has to collect.
    func ensureConnected(walletId: String) async throws {
        guard let session else {
            throw AppError(message: "Unavailable", debugMessage: "No device session for wallet '\(walletId)'")
        }
        let deviceId = try requireTransportDeviceId(for: walletId)
        await waitForStaleSessionCleanup(deviceId: deviceId)
        try await session.ensureConnected(deviceId: deviceId)
        if session.connectedWalletId == walletId { return }

        Logger.info("Reopening '\(walletId)': the session is not provably this wallet's", context: "HwWalletManager")
        guard !entries(for: walletId).contains(where: \.passphraseProtected) else {
            throw HwPassphraseError.required
        }
        // A wallet that needs no secret can simply be reopened, including when the session reported
        // no identity at all — reopening is what makes it provable, and it re-reads the accounts that
        // failed to resolve in the first place.
        try await session.connectWithWalletMode(deviceId: deviceId, mode: .standard, passphrase: "")
        try requireIdentity(of: walletId)
    }

    /// Whether reaching `walletId` needs the passphrase again. The device only holds one hidden
    /// wallet open at a time and forgets the passphrase with the session, so a passphrase wallet that
    /// is not the live session cannot be reconnected — or signed with — without it.
    func needsPassphrase(walletId: String) -> Bool {
        entries(for: walletId).contains(where: \.passphraseProtected) && session?.connectedWalletId != walletId
    }

    func disconnectStaleSession(walletId: String) async {
        guard let deviceId = transportDeviceId(for: walletId) else { return }
        if let cleanup = staleSessionCleanupTasks[deviceId] {
            await cleanup.value
            return
        }
        await performStaleSessionCleanup(deviceId: deviceId)
    }

    /// Starts timeout recovery without blocking the current UI operation. Any subsequent connect
    /// for the same physical device waits for this task before opening a new session.
    func scheduleStaleSessionCleanup(walletId: String) {
        guard let deviceId = transportDeviceId(for: walletId) else { return }
        guard staleSessionCleanupTasks[deviceId] == nil else { return }

        staleSessionCleanupTasks[deviceId] = Task { @MainActor [weak self] in
            guard let self else { return }
            await performStaleSessionCleanup(deviceId: deviceId)
            staleSessionCleanupTasks[deviceId] = nil
        }
    }

    private func waitForStaleSessionCleanup(deviceId: String) async {
        await staleSessionCleanupTasks[deviceId]?.value
    }

    private func performStaleSessionCleanup(deviceId: String) async {
        await session?.disconnectStaleSession(deviceId: deviceId)
    }

    func isKnownBluetoothDevice(walletId: String) -> Bool {
        guard let deviceId = transportDeviceId(for: walletId) else { return false }
        return session?.isKnownBluetoothDevice(deviceId: deviceId) ?? false
    }

    func warmUpConnection(walletId: String) {
        // There is nothing to warm up for a hidden wallet whose session is gone: opening it needs the
        // passphrase, which a warm-up has no way to ask for, and connecting without one opens the
        // standard wallet instead — a session the user did not ask for, on the device the transfer is
        // about to need. The prompt reopens it properly a moment later.
        guard !needsPassphrase(walletId: walletId) else { return }
        guard let deviceId = transportDeviceId(for: walletId) else { return }
        guard staleSessionCleanupTasks[deviceId] == nil else { return }
        session?.warmUpConnection(deviceId: deviceId)
    }

    /// Reopens a watched passphrase wallet for signing. A wrong passphrase is not rejected by the
    /// device — it silently derives a different wallet — so the reopened session is only accepted when
    /// its accounts resolve back to `walletId`; anything else is torn down again and reported as
    /// `HwPassphraseError.mismatch` rather than signing from the wrong wallet.
    func reconnectWithPassphrase(walletId: String, passphrase: String) async throws {
        guard let session else {
            throw AppError(message: "Unavailable", debugMessage: "No device session for wallet '\(walletId)'")
        }
        let deviceId = try requireTransportDeviceId(for: walletId)
        await waitForStaleSessionCleanup(deviceId: deviceId)
        let watchedBefore = watchedWalletIds()
        // Not `ensureConnected`: the session this reopens is usually already gone, either because the
        // app restarted or because a wrong passphrase closed it.
        try await session.connectWithWalletMode(deviceId: deviceId, mode: .passphraseHost, passphrase: passphrase)

        let opened = session.connectedWalletId
        if opened == walletId { return }

        guard let opened else {
            // Not a mismatch: the session opened but its accounts could not be read, so nothing is
            // known about which wallet it holds. Reporting a wrong passphrase would send the user to
            // re-enter one that may well have been right.
            await session.disconnectStaleSession(deviceId: deviceId)
            throw AppError(
                message: "Couldn't read the passphrase wallet",
                debugMessage: "No accounts resolved for the wallet reopened on '\(deviceId)'"
            )
        }

        Logger.warn("Rejected hardware session for '\(walletId)': opened wallet '\(opened)'", context: "HwWalletManager")
        // Reading the accounts of the wrong wallet already stored it; a mistyped passphrase must not
        // leave a stray watch-only wallet behind.
        if !watchedBefore.contains(opened) {
            // The wallet is a real one the user owns, and reading its accounts already stored it —
            // consuming any name restored for it into the entry about to be forgotten. Keeping its
            // data puts that name back where re-pairing will find it. Failing here must not replace
            // the mismatch the caller is waiting for.
            try? await removeWallet(walletId: opened, keepBackupData: true)
        }
        await session.disconnectStaleSession(deviceId: deviceId)
        throw HwPassphraseError.mismatch
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
            if isActive, activeWatcherElectrumUrls[spec.watcherId] == spec.electrumUrl { continue }
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
    /// (wallet identity, monitored address type). Deduped by watcher id, which is what collapses the
    /// same wallet stored more than once into a single watcher. Entries without xpubs are skipped.
    private func desiredWatcherSpecs() -> [WatcherSpec] {
        let monitored = monitoredTypesProvider()
        let electrumUrl = electrumUrlProvider()

        var seen = Set<String>()
        var specs: [WatcherSpec] = []
        for device in knownDevices {
            guard let walletId = resolvedWalletId(for: device) else { continue }
            for (addressType, xpub) in device.xpubs where monitored.contains(addressType) {
                let spec = WatcherSpec(walletId: walletId, addressType: addressType, xpub: xpub, electrumUrl: electrumUrl)
                guard seen.insert(spec.watcherId).inserted else { continue }
                specs.append(spec)
            }
        }
        return specs
    }

    /// Identity for deduping watchers across devices that share an (addressType, xpub). Uses a
    /// control-character separator that can't appear in either component.
    private func dedupKey(addressType: String, xpub: String) -> String {
        "\(addressType)\u{1}\(xpub)"
    }

    /// The wallet identity a stored entry belongs to: the id it was saved with, or one derived from
    /// its xpubs for entries written before the id was persisted. Returns nil when neither is
    /// available (no captured xpubs), so callers skip the entry.
    private func resolvedWalletId(for device: TrezorKnownDevice) -> String? {
        if let walletId = device.walletId, !walletId.isEmpty { return walletId }
        return walletId(for: device.xpubs)
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
    /// stores, aggregates, and scopes them to the wallet.
    func handleWatcherEvent(watcherId: String, event: WatcherEvent) {
        guard case let .transactionsChanged(activities, transactionDetails, balance, _, _, _) = event else { return }
        let walletId = walletId(fromWatcherId: watcherId)
        let previous = watcherData[watcherId]
        watcherData[watcherId] = HwWatcherData(
            walletId: walletId,
            balanceSats: balance.total,
            activities: activities,
            transactionDetails: transactionDetails
        )
        let groups = deviceGroups()
        recomputeDerivedState(groups: groups)
        persistGroupSnapshot(forWallet: walletId, groups: groups)
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

    private func persistGroupSnapshot(forWallet walletId: String, groups: [DeviceGroup]? = nil) {
        let groups = groups ?? deviceGroups()
        guard let group = groups.first(where: { $0.walletId == walletId }) else { return }

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
            guard let self else { return }
            do {
                try await deleteActivities(walletId)
            } catch {
                Logger.error("Failed to delete activities for HW wallet '\(walletId)': \(error)", context: "HwWalletManager")
            }
            await restoreKeptMetadata(walletId: walletId)
        }
    }

    /// Re-apply the tag metadata a removal asked to keep, as the tail of the delete that took it.
    /// Core drops a wallet's pre-activity metadata along with its activities whether or not any
    /// matched, so this belongs to every delete of the wallet rather than to the removal alone — a
    /// later cleanup pass then repairs itself instead of destroying the kept rows. Core re-attaches
    /// them once a watcher recreates the activities, so re-pairing the device brings the tags back.
    private func restoreKeptMetadata(walletId: String) async {
        guard let kept = keptBackupMetadata[walletId], !kept.isEmpty else { return }
        do {
            try await writeTagMetadata(kept)
        } catch {
            // The activities are already gone and the watchers already stopped, so there is nothing
            // to roll back to and reporting a failed removal would be false. The tags are lost.
            Logger.error("Failed to keep tag metadata of HW wallet '\(walletId)': \(error)", context: "HwWalletManager")
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
            .filter { $0.value.walletId == group.walletId }
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
            let walletWatchers = watcherData.values.filter { $0.walletId == group.walletId }
            return HwWallet(
                id: group.walletId,
                walletId: group.walletId,
                name: device.displayName,
                model: device.model,
                // A device holding several passphrase wallets only has a session for one of them,
                // and only that identity can sign; mark the others disconnected. A session opened
                // before its identity was resolved reports none and stays inclusive.
                isConnected: connectedDevice != nil && (connectedWalletId == nil || connectedWalletId == group.walletId),
                balanceSats: walletWatchers.reduce(UInt64(0)) { $0.saturatingAdd($1.balanceSats) },
                fundingBalanceSats: fundingBalance(group: group, addressType: hwFundingDefaultAddressType),
                deviceIds: group.ids,
                passphraseProtected: group.devices.contains { $0.passphraseProtected }
            )
        }

        totalSats = wallets.reduce(UInt64(0)) { $0.saturatingAdd($1.balanceSats) }
        hwWalletIds = Set(groups.map(\.walletId))
    }

    /// Group stored entries by wallet identity, preserving first-seen order. A passphrase wallet
    /// derives different xpubs from its device's standard wallet, so it groups on its own. Entries
    /// without captured xpubs are skipped.
    private func deviceGroups() -> [DeviceGroup] {
        var order: [String] = []
        var grouped: [String: [TrezorKnownDevice]] = [:]
        for device in knownDevices where !device.xpubs.isEmpty {
            guard let walletId = resolvedWalletId(for: device) else { continue }
            if grouped[walletId] == nil { order.append(walletId) }
            grouped[walletId, default: []].append(device)
        }
        return order.compactMap { walletId in
            guard let devices = grouped[walletId] else { return nil }
            return DeviceGroup(walletId: walletId, devices: devices)
        }
    }

    // MARK: - Funding (transfer to spending)

    /// The watch-only balance available to fund a transfer to spending from `walletId`, sourced from
    /// the given address-type account only (v1: native segwit). Does not require a connected device.
    func fundingBalance(walletId: String, addressType: AddressScriptType = hwFundingDefaultAddressType) -> UInt64 {
        watcherData
            .filter { $0.value.walletId == walletId && self.addressType(fromWatcherId: $0.key) == addressType.stringValue }
            .reduce(UInt64(0)) { $0.saturatingAdd($1.value.balanceSats) }
    }

    private func fundingBalance(group: DeviceGroup, addressType: AddressScriptType) -> UInt64 {
        fundingBalance(walletId: group.walletId, addressType: addressType)
    }

    /// Resolve the funding account (xpub + watch-only balance) for a paired wallet. Does not require
    /// a connected device — the xpub is read from the stored entry and the balance from the running
    /// watchers. On a device holding several wallets, the entry that actually carries the requested
    /// account wins.
    func getFundingAccount(
        walletId: String,
        addressType: AddressScriptType = hwFundingDefaultAddressType
    ) throws -> HwFundingAccount {
        let entries = knownDevices.filter { $0.resolvedWalletId == walletId }
        guard !entries.isEmpty else {
            throw AppError(message: "Unknown hardware wallet", debugMessage: "No known wallet '\(walletId)'")
        }
        guard let xpub = entries.compactMap({ $0.xpubs[addressType.stringValue] }).first else {
            throw AppError(
                message: "Missing account",
                debugMessage: "Wallet '\(walletId)' has no '\(addressType.stringValue)' account xpub"
            )
        }
        return HwFundingAccount(
            xpub: xpub,
            addressType: addressType,
            balanceSats: fundingBalance(walletId: walletId, addressType: addressType)
        )
    }

    /// The exact amount spendable from the funding account after the real coin-selection mining fee,
    /// computed offline via a `sendMax` compose. No connected device is needed — `fingerprint` is only
    /// required for signing — so this mirrors the software wallet's max-sendable estimate.
    /// `destinationAddress` is a fee-estimation destination only (never broadcast).
    func maxSpendableFunding(
        walletId: String,
        destinationAddress: String,
        satsPerVByte: UInt64,
        addressType: AddressScriptType = hwFundingDefaultAddressType
    ) async throws -> UInt64 {
        let account = try getFundingAccount(walletId: walletId, addressType: addressType)
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
        walletId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        addressType: AddressScriptType = hwFundingDefaultAddressType
    ) async throws -> HwFundingTransaction {
        let fingerprint = try await TrezorService.shared.getDeviceFingerprint()
        return try await composeFundingTransactionInternal(
            walletId: walletId,
            address: address,
            sats: sats,
            satsPerVByte: satsPerVByte,
            fingerprint: fingerprint,
            addressType: addressType
        )
    }

    /// Offline coin-selection for the exact funding amount; returns the mining fee only.
    func estimateOfflineFundingMiningFee(
        walletId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        addressType: AddressScriptType = hwFundingDefaultAddressType
    ) async throws -> UInt64 {
        let funding = try await composeFundingTransactionInternal(
            walletId: walletId,
            address: address,
            sats: sats,
            satsPerVByte: satsPerVByte,
            fingerprint: nil,
            addressType: addressType
        )
        return funding.miningFeeSats
    }

    private func composeFundingTransactionInternal(
        walletId: String,
        address: String,
        sats: UInt64,
        satsPerVByte: UInt64,
        fingerprint: String?,
        addressType: AddressScriptType
    ) async throws -> HwFundingTransaction {
        let account = try getFundingAccount(walletId: walletId, addressType: addressType)
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
        walletId: String,
        funding: HwFundingTransaction
    ) async throws -> HwFundingSignedTx {
        // The session can change between connecting and signing, and signing from the wrong seed
        // would produce signatures that do not match the inputs being spent.
        try requireIdentity(of: walletId)
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

    private func walletId(fromWatcherId watcherId: String) -> String {
        guard let range = watcherId.range(of: Constants.watcherIdSeparator) else { return watcherId }
        return String(watcherId[..<range.lowerBound])
    }

    private func addressType(fromWatcherId watcherId: String) -> String {
        guard let range = watcherId.range(of: Constants.watcherIdSeparator) else { return "" }
        return String(watcherId[range.upperBound...])
    }

    // MARK: - Supporting types

    private struct WatcherSpec {
        let walletId: String
        let addressType: String
        let xpub: String
        let electrumUrl: String

        /// Keyed by wallet, not by device: a device holding several passphrase wallets would
        /// otherwise collide on one watcher id per address type.
        var watcherId: String {
            "\(walletId)\(Constants.watcherIdSeparator)\(addressType)"
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
        let walletId: String
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

/// Failures of a hardware-wallet removal the user can act on.
enum HwWalletRemovalError: Error, Equatable {
    /// The removal asked to keep the wallet's backup data, but its tags could not be read. Raised
    /// before anything is deleted, so the wallet is untouched and the removal can be retried or
    /// repeated without keeping the data.
    case backupDataUnreadable
}

/// Failures specific to passphrase (hidden) wallets, mirroring bitkit-android's `HwPassphrase*Error`
/// types. The passphrase itself never appears in any of them.
enum HwPassphraseError: Error, Equatable {
    /// The device has passphrase protection turned off, so it cannot open a hidden wallet at all.
    case protectionDisabled
    /// The entered passphrase resolves to a wallet Bitkit already watches.
    case alreadyAdded
    /// The session belongs to another identity, and only this wallet's passphrase reopens it.
    case required
    /// The entered passphrase opened a different wallet than the one being signed from.
    case mismatch
}
