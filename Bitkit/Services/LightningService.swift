import BitkitCore
import Combine
import Foundation
import LDKNode

// TODO: catch all errors and pass a readable error message to the UI

/// A Lightning rail that needs no channels (Breez SDK on Spark). The main app sets it; the notification
/// extension leaves it unset, so only LDK runs there.
protocol ChannelFreeLightningRail: AnyObject {
    @MainActor var isReady: Bool { get }
    @MainActor var balanceSats: UInt64 { get }
    func receive(amountSats: UInt64?, description: String, expirySecs: UInt32) async throws -> String
    /// Refuses before sending when the prepared fee is above `maxFeeSats`, and runs `beforeSubmission` right before the
    /// payment goes out, as the node path does.
    func send(bolt11: String, sats: UInt64?, maxFeeSats: UInt64?, beforeSubmission: @escaping () throws -> Void) async throws -> PaymentHash
    func estimateRoutingFees(bolt11: String, amountSats: UInt64?) async throws -> UInt64
    /// Throws when the rail could not list its payments, so a duplicate-payment check can tell that from none.
    func lightningPayments() async throws -> [ChannelFreeRailPayment]
    /// Whether the rail's last wallet sync reached it, and started after `seconds` since 1970 when given. The rail
    /// finishes an interrupted send only on such a sync, so before one its list can lack a send that went out.
    func hasSynced(after seconds: UInt64?) async -> Bool
}

@MainActor
extension ChannelFreeLightningRail {
    /// The most the rail can send once its fee is paid, so a payment near the full balance isn't offered and then refused.
    var sendableSats: UInt64 {
        ChannelFreeRailFees.sendableSats(balanceSats: balanceSats)
    }
}

enum ChannelFreeRailFees {
    /// Spark keeps 0.25% of a Lightning send as its service fee, on top of routing.
    static let serviceFeePpm: UInt64 = 2500

    static func sendableSats(balanceSats: UInt64) -> UInt64 {
        // The fee on the sent amount, rounded up, must fit beside it: amount + ceil(amount * ppm / 1e6) <= balance.
        let scaled = balanceSats.multipliedFullWidth(by: 1_000_000)
        let sendable = (1_000_000 + serviceFeePpm).dividingFullWidth((scaled.high, scaled.low)).quotient
        let fee = sendable / 1_000_000 * serviceFeePpm + (sendable % 1_000_000 * serviceFeePpm + 999_999) / 1_000_000
        return sendable + fee <= balanceSats || sendable == 0 ? sendable : sendable - 1
    }
}

/// The channel-free rail refused a payment before anything left the wallet: the rail was not connected, could not
/// prepare the payment, or its fee was over the caller's limit. A Paykit request or allowance can then end as failed.
/// The rail runs here but isn't connected, so its payments are unknown rather than none.
struct ChannelFreeRailUnavailable: Error {}

struct ChannelFreeRailSendRefused: LocalizedError {
    let reason: String
    var underlying: Error?
    /// A still-valid invoice created before the restore, as Spark can't show it didn't pay it then.
    var isRestoredInvoiceUnverified = false

    static func restoredInvoiceUnverified() -> ChannelFreeRailSendRefused {
        ChannelFreeRailSendRefused(reason: t("wallet__payment_restored_invoice"), isRestoredInvoiceUnverified: true)
    }

    /// Always the user copy in `reason`; the underlying error is for logs.
    var errorDescription: String? {
        reason
    }
}

/// A Lightning payment the channel-free rail sent or received, for checks that would otherwise read only LDK's payments.
struct ChannelFreeRailPayment: Equatable {
    let paymentHash: String
    let direction: PaymentDirection
    let status: PaymentStatus
    let preimage: String?
    var timestamp: UInt64 = 0
    var feeSats: UInt64 = 0

    /// The attempt that decides an outbound payment of `paymentHash`: a retried invoice is listed once per attempt,
    /// so a pending or settled one wins over failed ones, then the newest.
    static func latestOutboundAttempt(_ payments: [ChannelFreeRailPayment], paymentHash: String) -> ChannelFreeRailPayment? {
        payments
            .filter { $0.direction == .outbound && $0.paymentHash.caseInsensitiveCompare(paymentHash) == .orderedSame }
            .max { ($0.status == .failed ? 0 : 1, $0.timestamp) < ($1.status == .failed ? 0 : 1, $1.timestamp) }
    }
}

/// The rail a Lightning payment attempt went out on.
enum LightningPaymentRail {
    case ldk
    case channelFree
}

/// The node lifecycle `WalletViewModel` drives, apart from the rest of `LightningService` so its ordering can be tested.
protocol NodeLifecycleService: AnyObject {
    var hasNode: Bool { get }
    func setup(walletIndex: Int, electrumServerUrl: String?, rgsServerUrl: String?, channelMigration: ChannelDataMigration?) async throws
    func start(onEvent: ((Event) -> Void)?) async throws
    func stop(clearEventCallback: Bool) async throws
    func isNodeRunning() async -> Bool
    func wipeStorage(walletIndex: Int) async throws
}

class LightningService: NodeLifecycleService {
    private static let watchOnlyAccountHighestPreRevealedAddressIndex: UInt32 = 999

    private var node: Node?
    var onchainDispatchNode: AnyObject? {
        node
    }

    var currentWalletIndex: Int = 0

    func getTransactionDetails(txid: String, walletIndex: Int) async -> LDKNode.TransactionDetails? {
        guard currentWalletIndex == walletIndex, let node else { return nil }
        let details = try? await ServiceQueue.background(.ldk) { () -> LDKNode.TransactionDetails? in
            guard self.currentWalletIndex == walletIndex, self.node === node else { return nil }
            return node.getTransactionDetails(txid: txid)
        }
        guard currentWalletIndex == walletIndex, self.node === node else { return nil }
        return details
    }

    private let syncStatusChangedSubject = PassthroughSubject<UInt64, Never>()

    private var channelCache: [String: ChannelDetails] = [:]

    // Cached values to avoid blocking LDK calls on main thread
    // MainActor isolated to prevent data races between background writes and UI reads
    @MainActor private var cachedStatus: NodeStatus?
    @MainActor private var cachedBalances: BalanceDetails?
    @MainActor private var cachedPeers: [PeerDetails]?
    @MainActor private var cachedChannels: [ChannelDetails]?

    /// Guards the event callback and the rail events waiting for it, which the node and the rail set from different threads.
    private let eventCallbackLock = NSLock()
    private var storedEventCallback: ((Event) -> Void)?
    /// Rail events that arrived before the node's event callback was set, delivered once it is.
    private var pendingChannelFreeRailEvents: [Event] = []
    /// The rail each payment hash's latest attempt went out on, so a stale failure from the other rail can't settle a
    /// retry of the same invoice.
    private var attemptRails: [String: LightningPaymentRail] = [:]
    /// Payment hashes inside a rail send, which Spark lists only once it returns.
    private var railSendsInFlight: Set<String> = []
    /// Counts attempts recorded in this run, so a listing drops a hash just when the hash was recorded before the
    /// listing was read, never a retry recorded while it was read.
    private var attemptRecords = 0
    /// Per store key, the `attemptRecords` count at each hash's latest record.
    private var attemptRecordedAt: [String: [String: Int]] = [:]
    /// Node sends under way, so a listing that shows only an earlier failed attempt doesn't drop their hash.
    private var ldkSendsInFlight: Set<String> = []
    weak var channelFreeRail: ChannelFreeLightningRail?
    /// The rail whose payments the duplicate-payment check reads, kept while an emergency exit takes Spark off
    /// Lightning: an invoice Spark paid or is paying is never paid again over a channel.
    weak var channelFreePaymentHistory: ChannelFreeLightningRail?
    var onchainTransactionConfirmed: (@Sendable (String) async -> Void)?
    var onchainTransactionReceived: (@Sendable (String) async -> Void)?
    typealias OnchainActivityCompletion = @MainActor () async -> Void
    @MainActor var onchainActivityWillPersist: (() -> OnchainActivityCompletion?)?

    var syncStatusChangedPublisher: AnyPublisher<UInt64, Never> {
        syncStatusChangedSubject.eraseToAnyPublisher()
    }

    static var shared = LightningService()

    private static let scoringBasePenaltyMsat: UInt64 = 40000
    private static let scoringLiquidityPenaltyMultiplierMsat: UInt64 = 10000
    private static let scoringLiquidityPenaltyAmountMultiplierMsat: UInt64 = 10000
    private static let scoringHistoricalLiquidityPenaltyAmountMultiplierMsat: UInt64 = 20000
    private static let scoringConsideredImpossiblePenaltyMsat: UInt64 = 1_000_000_000_000

    private static let defaultScoringFeeParameters = ScoringFeeParameters(
        basePenaltyMsat: 1024,
        basePenaltyAmountMultiplierMsat: 131_072,
        liquidityPenaltyMultiplierMsat: 0,
        liquidityPenaltyAmountMultiplierMsat: 0,
        historicalLiquidityPenaltyMultiplierMsat: 10000,
        historicalLiquidityPenaltyAmountMultiplierMsat: 1250,
        antiProbingPenaltyMsat: 250,
        consideredImpossiblePenaltyMsat: 100_000_000_000,
        linearSuccessProbability: false,
        probingDiversityPenaltyMsat: 0
    )

    private init() {}

    /// Flag and lock to prevent concurrent setup calls
    private var isSettingUp = false
    private let setupLock = NSLock()

    func setup(
        walletIndex: Int,
        electrumServerUrl: String? = nil,
        rgsServerUrl: String? = nil,
        channelMigration: ChannelDataMigration? = nil
    ) async throws {
        // Guard against concurrent setup calls
        let shouldProceed: Bool = setupLock.withLock {
            guard !isSettingUp && node == nil else {
                Logger.debug("Node already setting up or already set up, skipping")
                return false
            }
            isSettingUp = true
            return true
        }
        guard shouldProceed else { return }
        defer { setupLock.withLock { isSettingUp = false } }

        Logger.debug("Checking lightning process lock...")
        try await StateLocker.lock(.lightning, wait: 30) // Wait 30 seconds to lock because maybe extension is still running
        // Unlock if setup fails before a node exists. After a successful build the node keeps the lock until stop.
        var shouldReleaseLightningLock = true
        defer {
            if shouldReleaseLightningLock {
                try? StateLocker.unlock(.lightning)
            }
        }

        guard var mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }

        // Normalize empty strings to nil - empty passphrase should be treated as no passphrase
        let passphraseRaw = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        var passphrase = passphraseRaw?.isEmpty == true ? nil : passphraseRaw

        currentWalletIndex = walletIndex

        var config = Self.nodeConfig(walletIndex: walletIndex)
        Logger.debug("Using LDK storage path: \(config.storageDirPath)")

        let (selectedAddressType, monitoredTypes) = Self.addressTypeStateFromUserDefaults()
        config.addressType = selectedAddressType
        config.addressTypesToMonitor = monitoredTypes.filter { $0 != selectedAddressType }
        #if !BITKIT_NOTIFICATION_EXTENSION
            config.onchainWalletAccounts = try Self.watchOnlyAccountConfigs(walletIndex: walletIndex)
        #endif

        let builder = Builder.fromConfig(config: config)
        builder.setCustomLogger(logWriter: LdkLogWriter())

        let resolvedElectrumServerUrl = electrumServerUrl ?? Env.electrumServerUrl

        let electrumConfig = ElectrumSyncConfig(
            backgroundSyncConfig: .init(
                onchainWalletSyncIntervalSecs: Env.walletSyncIntervalSecs,
                lightningWalletSyncIntervalSecs: Env.walletSyncIntervalSecs,
                feeRateCacheUpdateIntervalSecs: Env.walletSyncIntervalSecs
            ),
            connectionTimeoutSecs: 10,
            additionalWalletFullScanBatchSize: 100,
            additionalWalletFullScanStopGap: 1000
        )
        builder.setChainSourceElectrum(serverUrl: resolvedElectrumServerUrl, config: electrumConfig)

        // Set pathfinding scores source from external scorer
        if let scorerUrl = Env.ldkScorerUrl {
            Logger.info("Setting pathfinding scores source from scorer url: \(scorerUrl)")
            builder.setPathfindingScoresSource(url: scorerUrl)
        }

        builder.setScoringFeeParams(params: Self.scoringFeeParameters(config: config))

        // Configure gossip source from current settings
        configureGossipSource(builder: builder, rgsServerUrl: rgsServerUrl)

        Logger.debug("Building node...")
        let storeId = try await VssStoreIdProvider.shared.getVssStoreId(walletIndex: walletIndex)

        let vssUrl = Env.vssServerUrl
        let lnurlAuthServerUrl = Env.lnurlAuthServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.debug("Building ldk-node with vssUrl: '\(vssUrl)'")
        Logger.debug("Building ldk-node with lnurlAuthServerUrl: '\(lnurlAuthServerUrl)'")

        if let channelMigration {
            builder.setChannelDataMigration(migration: channelMigration)
            Logger.info("Applied channel migration: \(channelMigration.channelMonitors.count) monitors", context: "Migration")
        }

        builder.setEntropyBip39Mnemonic(mnemonic: mnemonic, passphrase: passphrase)

        guard !lnurlAuthServerUrl.isEmpty else {
            throw CustomServiceError.vssAuthRequired
        }

        try await ServiceQueue.background(.ldk) {
            self.node = try builder.buildWithVssStore(
                vssUrl: vssUrl,
                storeId: storeId,
                lnurlAuthServerUrl: lnurlAuthServerUrl,
                fixedHeaders: [:]
            )
        }
        shouldReleaseLightningLock = false

        Logger.info("LDK node setup")

        // Clear memory
        mnemonic = ""
        passphrase = nil
    }

    func restart(electrumServerUrl: String? = nil, rgsServerUrl: String? = nil) async throws {
        Logger.info("Restarting node with current configuration")

        // Stop the current node if it exists, ignore errors if already stopped
        if node != nil {
            do {
                try await stop()
            } catch {
                Logger.debug("Node was already stopped or failed to stop: \(error)")
                // Clear the node reference anyway
                node = nil
                try? StateLocker.unlock(.lightning)
            }
        }

        // Restart the node with the current configuration
        do {
            try await setup(walletIndex: currentWalletIndex, electrumServerUrl: electrumServerUrl, rgsServerUrl: rgsServerUrl)
            try await start()
            Logger.info("Node restarted successfully")
        } catch {
            Logger.warn("Failed ldk-node config change, attempting recovery…")
            // Attempt to restart with previous config
            // If recovery fails, log it but still throw the original error
            do {
                try await restartWithPreviousConfig()
            } catch {
                Logger.error("Recovery attempt also failed: \(error)")
            }
            // Always re-throw the original error that caused the restart failure
            throw error
        }
    }

    /// Restarts the node with the previous stored configuration (recovery method)
    /// This is called when a config change fails to restore the node to a working state
    private func restartWithPreviousConfig() async throws {
        Logger.debug("Stopping node for recovery attempt")

        // Stop the current node if it exists
        if node != nil {
            do {
                try await stop()
            } catch {
                Logger.error("Failed to stop node during recovery: \(error)")
                node = nil
                try? StateLocker.unlock(.lightning)
            }
        }

        Logger.debug("Starting node with previous config for recovery")

        do {
            // Restart with nil URLs to use stored/default configuration
            try await setup(walletIndex: currentWalletIndex, electrumServerUrl: nil, rgsServerUrl: nil)
            try await start()
            Logger.debug("Successfully started node with previous config")
        } catch {
            Logger.error("Failed starting node with previous config: \(error)")
            throw error
        }
    }

    /// Pass onEvent when being used in the background to listen for payments, channels, closes, etc
    /// - Parameter onEvent: Triggered on any LDK node event
    func start(onEvent: ((Event) -> Void)? = nil) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        if let onEvent {
            setEventCallback(onEvent)
        }

        listenForEvents(onEvent: eventCallbackLock.withLock { storedEventCallback })

        Logger.debug("Starting node...")
        try await ServiceQueue.background(.ldk) {
            try node.start()
        }

        #if !BITKIT_NOTIFICATION_EXTENSION
            do {
                try await reconcileWatchOnlyAccounts()
            } catch {
                Logger.error(error, context: "Failed to reconcile Paykit Server accounts during startup")
            }
        #endif

        await refreshChannelCache()
        await refreshCache()
        await listNodePaymentsKeepingAttempts()

        Logger.info("Node started")
    }

    private func refreshChannelCache() async {
        guard let node else { return }

        let channels = try? await ServiceQueue.background(.ldk) {
            node.listChannels()
        }

        await MainActor.run {
            let newChannels = Dictionary(uniqueKeysWithValues: (channels ?? []).map { ($0.channelId.description, $0) })
            for (key, value) in newChannels {
                channelCache[key] = value
            }
        }
    }

    func stop(clearEventCallback: Bool = false) async throws {
        defer {
            // Always try to unlock, even if stopping fails
            try? StateLocker.unlock(.lightning)
        }

        guard let node else {
            Logger.warn("Node not started, nothing to stop")
            return
        }

        Logger.debug("Stopping node...")
        try await ServiceQueue.background(.ldk) {
            try Self.stopReleasingFinishedNode(node.stop)
        }
        self.node = nil

        if clearEventCallback {
            self.clearEventCallback()
        }

        await MainActor.run {
            channelCache.removeAll()
        }

        Logger.info("Node stopped")
    }

    /// ldk-node's `stop()` fails with `NotRunning` for a node whose `start()` failed, which leaves it built but not running, so
    /// that releases it. Any other failure keeps the node, and a retried stop then finds it not running.
    static func stopReleasingFinishedNode(_ stop: () throws -> Void) throws {
        do {
            try stop()
        } catch NodeError.NotRunning {
            Logger.info("Node was not running, releasing it", context: "LightningService")
        }
    }

    /// Reads the node itself rather than the cached status, which can lag behind a failed start or stop.
    func isNodeRunning() async -> Bool {
        guard let node else { return false }
        return await (try? ServiceQueue.background(.ldk) { node.status().isRunning }) ?? false
    }

    func wipeStorage(walletIndex: Int) async throws {
        guard node == nil else {
            throw AppError(serviceError: .nodeStillRunning)
        }

        let directory = Env.ldkStorage(walletIndex: walletIndex)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            Logger.warn("No directory found to wipe: \(directory.path)")
            return
        }

        Logger.warn("Wiping on lighting wallet...")
        try FileManager.default.removeItem(at: directory)
        forgetLdkAttempts()

        await MainActor.run {
            clearCache()
            channelCache.removeAll()
        }

        Logger.info("Lightning wallet wiped")
    }

    func deleteNetworkGraph() async throws {
        let graphPath = Env.ldkStorage(walletIndex: currentWalletIndex).appendingPathComponent("network_graph_cache")
        guard FileManager.default.fileExists(atPath: graphPath.path) else {
            Logger.warn("Network graph cache not found at: \(graphPath.path)")
            return
        }
        try FileManager.default.removeItem(at: graphPath)
        Logger.info("Deleted network graph cache at: \(graphPath.path)")
    }

    func networkGraphCacheModificationDate() -> Date? {
        let graphPath = Env.ldkStorage(walletIndex: currentWalletIndex).appendingPathComponent("network_graph_cache")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: graphPath.path),
              let modificationDate = attributes[.modificationDate] as? Date
        else { return nil }

        return modificationDate
    }

    /// Disconnects stored peers we have nothing pending with, which also drops them from the peer store.
    /// Skips the run while any closed channel still awaits its sweep, as a sweep does not name its peer.
    func disconnectIdlePeers() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        try await ServiceQueue.background(.ldk) {
            let balances = node.listBalances()
            let idlePeerIds = Self.idlePeerIds(
                peers: node.listPeers(),
                channels: node.listChannels(),
                lightningBalances: balances.lightningBalances,
                pendingSweeps: balances.pendingBalancesFromChannelClosures
            )
            for nodeId in idlePeerIds {
                do {
                    try node.disconnect(nodeId: nodeId)
                    Logger.info("Disconnected idle peer: \(nodeId)")
                } catch {
                    Logger.warn("Failed to disconnect idle peer: \(nodeId)")
                }
            }
        }
    }

    private static func counterpartyNodeId(of balance: LightningBalance) -> PublicKey {
        switch balance {
        case let .claimableOnChannelClose(_, counterpartyNodeId, _, _, _, _, _, _),
             let .claimableAwaitingConfirmations(_, counterpartyNodeId, _, _, _),
             let .contentiousClaimable(_, counterpartyNodeId, _, _, _, _),
             let .maybeTimeoutClaimableHtlc(_, counterpartyNodeId, _, _, _, _),
             let .maybePreimageClaimableHtlc(_, counterpartyNodeId, _, _, _),
             let .counterpartyRevokedOutputClaimable(_, counterpartyNodeId, _):
            return counterpartyNodeId
        }
    }

    /// Returns the stored peers with no channel and no claimable balance, or none while any sweep is pending.
    static func idlePeerIds(
        peers: [PeerDetails],
        channels: [ChannelDetails],
        lightningBalances: [LightningBalance],
        pendingSweeps: [PendingSweepBalance]
    ) -> [PublicKey] {
        guard pendingSweeps.isEmpty else { return [] }
        let busyPeerIds = Set(channels.map(\.counterpartyNodeId) + lightningBalances.map(counterpartyNodeId(of:)))
        return peers.filter { $0.isPersisted && !busyPeerIds.contains($0.nodeId) }.map(\.nodeId)
    }

    func connectPeer(peer: LnPeer, persist: Bool = true) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        do {
            try await ServiceQueue.background(.ldk) {
                try node.connect(nodeId: peer.nodeId, address: peer.address, persist: persist)
            }
            Logger.info("Connected to peer: \(peer.nodeId)@\(peer.address)")
        } catch {
            Logger.error(error, context: "Failed to connect peer: \(peer.nodeId)@\(peer.address)")
            throw error
        }
    }

    func reconnectPeers() async {
        guard let node else {
            Logger.debug("Node not setup, skipping peer reconnection", context: "LightningService")
            return
        }

        let peers = node.listPeers()
        Logger.debug("Reconnecting to \(peers.count) peers", context: "LightningService")
        for peer in peers {
            do {
                try await ServiceQueue.background(.ldk) {
                    try node.connect(nodeId: peer.nodeId, address: peer.address, persist: true)
                }
                Logger.info("Reconnected to peer: \(peer.nodeId)@\(peer.address)", context: "LightningService")
            } catch {
                Logger.error(error, context: "Failed to reconnect to peer: \(peer.nodeId)@\(peer.address)")
            }
        }

        Logger.debug("Finished peer reconnection attempt", context: "LightningService")
    }

    /// Temp fix for regtest where nodes might not agree on current fee rates
    private func setMaxDustHtlcExposureForCurrentChannels() throws {
        guard Env.network == .regtest else {
            Logger.debug("Not updating channel config for non-regtest network")
            return
        }

        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        for channel in node.listChannels() {
            var config = channel.config
            config.maxDustHtlcExposure = .fixedLimit(limitMsat: 999_999 * 1000)
            try? node.updateChannelConfig(userChannelId: channel.userChannelId, counterpartyNodeId: channel.counterpartyNodeId, channelConfig: config)
            Logger.info("Updated channel config for: \(channel.userChannelId)")
        }
    }

    func sync() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        #if !BITKIT_NOTIFICATION_EXTENSION
            try await reconcileWatchOnlyAccounts()
        #endif

        Logger.debug("Syncing LDK...")
        try await ServiceQueue.background(.ldk) {
            try node.syncWallets()
            // try? self.setMaxDustHtlcExposureForCurrentChannels()
        }
        Logger.info("LDK synced")

        await refreshChannelCache()
        await refreshCache()

        // Emit state change with sync timestamp from node status
        let nodeStatus = node.status()
        if let latestSyncTimestamp = nodeStatus.latestLightningWalletSyncTimestamp {
            let syncTimestamp = UInt64(latestSyncTimestamp)
            syncStatusChangedSubject.send(syncTimestamp)
        } else {
            let syncTimestamp = UInt64(Date().timeIntervalSince1970)
            syncStatusChangedSubject.send(syncTimestamp)
        }
    }

    func exportWatchOnlyAccountXpub(accountIndex: UInt32, addressType: LDKNode.AddressType) async throws -> String {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.exportOnchainWalletAccountXpub(addressType: addressType, accountIndex: accountIndex)
        }
    }

    func setWatchOnlyAccountTracking(
        accountIndex: UInt32,
        addressType: LDKNode.AddressType,
        xpub: String,
        enabled: Bool
    ) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        try await ServiceQueue.background(.ldk) {
            let isTracked = node.listOnchainWalletAccounts().contains {
                $0.addressType == addressType && $0.accountIndex == accountIndex
            }

            if enabled {
                var didAddAccount = false
                do {
                    if !isTracked {
                        try node.addOnchainWalletAccount(addressType: addressType, accountIndex: accountIndex, xpub: xpub)
                        didAddAccount = true
                    }
                    try node.onchainPayment().revealReceiveAddressesToAccount(
                        addressType: addressType,
                        accountIndex: accountIndex,
                        index: Self.watchOnlyAccountHighestPreRevealedAddressIndex
                    )
                    // Registration and address revelation establish tracking locally. LDK's
                    // periodic sync fetches history without making authorization depend on
                    // the network availability of every wallet account.
                } catch {
                    if didAddAccount {
                        do {
                            try node.removeOnchainWalletAccount(addressType: addressType, accountIndex: accountIndex)
                        } catch let cleanupError {
                            Logger.error(cleanupError, context: "Failed to roll back Paykit Server account tracking")
                        }
                    }
                    throw error
                }
            } else if !enabled, isTracked {
                try node.removeOnchainWalletAccount(addressType: addressType, accountIndex: accountIndex)
            }
        }
    }

    #if !BITKIT_NOTIFICATION_EXTENSION
        func reconcileWatchOnlyAccounts() async throws {
            try await WatchOnlyAccountManager.shared.reconcileTracking()
        }

        func reconcileWatchOnlyAccountTracking(
            records: [WatchOnlyAccountRecord],
            managedRecords: [WatchOnlyAccountRecord]
        ) async throws {
            guard let node else {
                throw AppError(serviceError: .nodeNotSetup)
            }
            let walletRecords = records.filter { $0.walletIndex == currentWalletIndex }
            let managedWalletRecords = managedRecords.filter { $0.walletIndex == currentWalletIndex }
            let desiredConfigs = try Self.watchOnlyAccountConfigs(records: walletRecords)

            try await ServiceQueue.background(.ldk) {
                let trackedAccounts = node.listOnchainWalletAccounts()
                let managedKeys = Set(managedWalletRecords.map { "\($0.addressType):\($0.accountIndex)" })
                let desiredKeys = Set(desiredConfigs.map { "\($0.addressType.stringValue):\($0.accountIndex)" })

                for trackedAccount in trackedAccounts {
                    let key = "\(trackedAccount.addressType.stringValue):\(trackedAccount.accountIndex)"
                    if managedKeys.contains(key), !desiredKeys.contains(key) {
                        try node.removeOnchainWalletAccount(
                            addressType: trackedAccount.addressType,
                            accountIndex: trackedAccount.accountIndex
                        )
                    }
                }

                for config in desiredConfigs {
                    let isTracked = trackedAccounts.contains {
                        $0.addressType == config.addressType && $0.accountIndex == config.accountIndex
                    }
                    if !isTracked {
                        try node.addOnchainWalletAccount(
                            addressType: config.addressType,
                            accountIndex: config.accountIndex,
                            xpub: config.xpub
                        )
                    }
                    try node.onchainPayment().revealReceiveAddressesToAccount(
                        addressType: config.addressType,
                        accountIndex: config.accountIndex,
                        index: Self.watchOnlyAccountHighestPreRevealedAddressIndex
                    )
                }
            }
        }

        private static func watchOnlyAccountConfigs(walletIndex: Int) throws -> [OnchainWalletAccountConfig] {
            try watchOnlyAccountConfigs(records: WatchOnlyAccountStore.enabledAccounts(for: walletIndex))
        }

        private static func watchOnlyAccountConfigs(records: [WatchOnlyAccountRecord]) throws -> [OnchainWalletAccountConfig] {
            try records.filter {
                ($0.setupState == .active || $0.setupState == .authorizing) && $0.isTrackingEnabled
            }.map { record in
                guard let addressType = LDKNode.AddressType.from(string: record.addressType) else {
                    throw WatchOnlyAccountError.invalidExtendedPublicKey
                }
                return OnchainWalletAccountConfig(
                    addressType: addressType,
                    accountIndex: record.accountIndex,
                    xpub: record.xpub
                )
            }
        }
    #endif

    func newAddress() async throws -> String {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment().newAddress()
        }
    }

    func newAddressForType(_ addressType: LDKNode.AddressType) async throws -> String {
        let addressInfo = try await newAddressInfoForType(addressType)
        return addressInfo.address
    }

    struct AddressDerivationInfo {
        let address: String
        let index: UInt32
    }

    func newAddressInfoForType(_ addressType: LDKNode.AddressType) async throws -> AddressDerivationInfo {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            let addressInfo = try node.onchainPayment().newAddressInfoForType(addressType: addressType)
            return AddressDerivationInfo(address: addressInfo.address, index: addressInfo.index)
        }
    }

    func addressInfoForType(
        _ addressType: LDKNode.AddressType,
        keychain: LDKNode.KeychainKind = .external,
        atIndex index: UInt32
    ) async throws -> AddressDerivationInfo {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            let addressInfo = try node.onchainPayment().addressInfoForTypeAtIndex(addressType: addressType, keychain: keychain, index: index)
            return AddressDerivationInfo(address: addressInfo.address, index: addressInfo.index)
        }
    }

    func listOnchainWalletAccounts() async throws -> [LDKNode.OnchainWalletAccount] {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            node.listOnchainWalletAccounts()
        }
    }

    func addressInfosForType(
        _ addressType: LDKNode.AddressType,
        keychain: LDKNode.KeychainKind,
        startIndex: UInt32,
        count: UInt32,
        accountIndex: UInt32 = 0
    ) async throws -> [AddressDerivationInfo] {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment()
                .addressInfosForAccount(
                    addressType: addressType, accountIndex: accountIndex, keychain: keychain, startIndex: startIndex, count: count
                )
                .map { AddressDerivationInfo(address: $0.address, index: $0.index) }
        }
    }

    func revealReceiveAddresses(to receiveIndex: UInt32, forType addressType: LDKNode.AddressType) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        try await ServiceQueue.background(.ldk) {
            try node.onchainPayment().revealReceiveAddressesTo(addressType: addressType, index: receiveIndex)
        }
    }

    /// `isPaykitEndpoint` marks the amountless invoice published as a Paykit Lightning endpoint, which contacts pay any
    /// amount: it goes to the channel-free rail unless the channels' inbound covers `paykitEndpointNodeInboundSats`.
    func receive(amountSats: UInt64? = nil, description: String, expirySecs: UInt32 = 3600, isPaykitEndpoint: Bool = false) async throws -> String {
        try await receiveMsats(
            amountMsats: amountSats.map { $0 * 1000 },
            description: description,
            expirySecs: expirySecs,
            isPaykitEndpoint: isPaykitEndpoint
        )
    }

    func receiveMsats(
        amountMsats: UInt64? = nil,
        description: String,
        expirySecs: UInt32 = 3600,
        isPaykitEndpoint: Bool = false
    ) async throws -> String {
        if let rail = channelFreeRail {
            // Judged on the amount rounded up, so channels that can't take the last part of a sat don't get it.
            let railTakes = await shouldReceiveWithRail(rail, amountSats: amountMsats.map { ($0 + 999) / 1000 }, isPaykitEndpoint: isPaykitEndpoint)
            switch Self.receiveRoute(amountMsats: amountMsats, railTakes: railTakes) {
            case let .rail(amountSats):
                return try await rail.receive(amountSats: amountSats, description: description, expirySecs: expirySecs)
            case .refused:
                throw AppError(
                    message: t("other__lnurl_withdr_error_no_capacity"),
                    debugMessage: "Spark invoices are whole sats, and no channel can receive \(amountMsats ?? 0) msat"
                )
            case .node:
                break
            }
        }
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        let bolt11 = try await ServiceQueue.background(.ldk) {
            if let amountMsats {
                try node
                    .bolt11Payment()
                    .receive(
                        amountMsat: amountMsats,
                        description: Bolt11InvoiceDescription.direct(description: description),
                        expirySecs: expirySecs
                    )
            } else {
                try node
                    .bolt11Payment()
                    .receiveVariableAmount(
                        description: Bolt11InvoiceDescription.direct(description: description),
                        expirySecs: expirySecs
                    )
            }
        }

        return bolt11.description
    }

    enum ReceiveRoute: Equatable {
        case rail(amountSats: UInt64?)
        case node
        /// Neither rail can receive the exact amount.
        case refused
    }

    /// Where an invoice for `amountMsats` is made, given whether the channel-free rail takes it. The rail's invoices
    /// are whole sats, so an amount with a part of a sat goes to the channels, or is refused when they can't take it,
    /// rather than invoicing less than asked.
    static func receiveRoute(amountMsats: UInt64?, railTakes: Bool) -> ReceiveRoute {
        guard railTakes else { return .node }
        guard let amountMsats, amountMsats > 0 else { return .rail(amountSats: nil) }
        return amountMsats % 1000 == 0 ? .rail(amountSats: amountMsats / 1000) : .refused
    }

    /// Receives on the channel-free rail when no ready channel has the inbound capacity for the amount.
    @MainActor
    private func shouldReceiveWithRail(_ rail: ChannelFreeLightningRail, amountSats: UInt64?, isPaykitEndpoint: Bool) -> Bool {
        guard rail.isReady else { return false }
        let readyChannels = (channels ?? []).filter(\.isChannelReady)
        let inboundSats: UInt64? = readyChannels.isEmpty ? nil : readyChannels.map(\.inboundCapacityMsat).reduce(0, +) / 1000
        return Self.receivesOnRail(amountSats: amountSats, readyInboundSats: inboundSats, isPaykitEndpoint: isPaykitEndpoint)
    }

    /// Below this channel inbound, a contact's amountless Paykit invoice goes to the channel-free rail, so a small
    /// channel can't cap what contacts can pay.
    static let paykitEndpointNodeInboundSats: UInt64 = 1_000_000

    /// Whether a ready channel-free rail takes an invoice, given the ready channels' total inbound (nil without any).
    /// An amount the channels can't receive goes to the rail; an amountless invoice does only when no channel can
    /// receive at all, except a Paykit endpoint, which does below `paykitEndpointNodeInboundSats`.
    static func receivesOnRail(amountSats: UInt64?, readyInboundSats: UInt64?, isPaykitEndpoint: Bool) -> Bool {
        guard let inboundSats = readyInboundSats else { return true }
        guard let amountSats, amountSats > 0 else {
            return isPaykitEndpoint ? inboundSats < paykitEndpointNodeInboundSats : inboundSats == 0
        }
        return amountSats > inboundSats
    }

    /// Pays on the channel-free rail when no channel has the outbound capacity and the rail's balance covers the amount.
    @MainActor
    private func shouldPayWithRail(_ rail: ChannelFreeLightningRail, bolt11: String, sats: UInt64?) -> Bool {
        guard rail.isReady, let amountSats = Self.paymentAmountSats(bolt11: bolt11, sats: sats) else { return false }
        return !canSendWithChannels(amountSats: amountSats) && rail.sendableSats >= amountSats
    }

    private static func paymentAmountSats(bolt11: String, sats: UInt64?) -> UInt64? {
        sats ?? (try? Bolt11Invoice.fromStr(invoiceStr: bolt11).amountMilliSatoshis()).flatMap { $0 }.map { $0 / 1000 }
    }

    /// LDK's routing fee limit when a caller sets none, 1% + 50 sats, so a send over the rail is capped the same way.
    private static func defaultMaxFeeSats(amountSats: UInt64) -> UInt64 {
        amountSats / 100 + 50
    }

    /// Checks if we have the correct outbound capacity to send the amount
    /// - Parameter amountSats: Amount to send in satoshis
    /// - Returns: True if we can send the amount
    /// Note: Uses cached channels for fast, non-blocking checks
    @MainActor
    func canSend(amountSats: UInt64) -> Bool {
        // An amountless invoice still needs funds on Spark, as the channels need capacity above the amount.
        if let rail = channelFreeRail, rail.isReady, rail.sendableSats >= max(1, amountSats), !canSendWithChannels(amountSats: amountSats) {
            return true
        }
        return canSendWithChannels(amountSats: amountSats)
    }

    @MainActor
    private func canSendWithChannels(amountSats: UInt64) -> Bool {
        guard let channels else {
            return false
        }

        let usableChannels = channels.filter(\.isUsable)
        guard !usableChannels.isEmpty else {
            return false
        }

        let totalNextOutboundHtlcLimitSats = usableChannels
            .map(\.nextOutboundHtlcLimitMsat)
            .reduce(0, +) / 1000

        guard totalNextOutboundHtlcLimitSats > amountSats else {
            Logger.warn("canSend: insufficient capacity: \(totalNextOutboundHtlcLimitSats) < \(amountSats)", context: "LightningService")
            return false
        }

        return true
    }

    private static func convertVByteToKwu(satsPerVByte: UInt32) -> FeeRate {
        // 1 vbyte = 4 weight units, so 1 sats/vbyte = 250 sats/kwu
        let satPerKwu = UInt64(satsPerVByte) * 250
        // Ensure we're above the minimum relay fee
        return .fromSatPerKwu(satKwu: max(satPerKwu, 253)) // FEERATE_FLOOR_SATS_PER_KW is 253 in LDK
    }

    func send(
        address: String,
        sats: UInt64,
        satsPerVbyte: UInt32,
        utxosToSpend: [SpendableUtxo]? = nil,
        isMaxAmount: Bool = false,
        expectedWalletIndex: Int? = nil,
        expectedNode: AnyObject? = nil,
        beforeSubmission: @escaping () throws -> Void = {}
    ) async throws -> OnchainSendResult {
        guard let node else {
            throw NodeError.NotRunning(message: "Node not set up")
        }

        Logger.info("Sending \(sats) sats to \(address) with fee rate \(satsPerVbyte) sats/vbyte (isMaxAmount: \(isMaxAmount))")

        do {
            return try await ServiceQueue.background(.ldk, wrapErrors: false) {
                if let expectedWalletIndex {
                    guard self.currentWalletIndex == expectedWalletIndex, self.node === node, expectedNode === node else {
                        throw NodeError.NotRunning(message: "Wallet or node changed before on-chain dispatch")
                    }
                }
                try beforeSubmission()
                if isMaxAmount {
                    return try node.onchainPayment().sendAllToAddressWithBroadcastResult(
                        address: address,
                        retainReserves: true,
                        feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVbyte)
                    )
                } else {
                    return try node.onchainPayment().sendToAddressWithBroadcastResult(
                        address: address,
                        amountSats: sats,
                        feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVbyte),
                        utxosToSpend: utxosToSpend
                    )
                }
            }
        } catch {
            dumpLdkLogs()
            throw error
        }
    }

    /// `channelsOnly` keeps a payment quoted against the channels on them, never falling back to the channel-free rail.
    func send(
        bolt11: String,
        sats: UInt64? = nil,
        params: RouteParametersConfig? = nil,
        channelsOnly: Bool = false,
        beforeSubmission: @escaping () throws -> Void = {}
    ) async throws -> PaymentHash {
        let invoice = try? Bolt11Invoice.fromStr(invoiceStr: bolt11)
        let paymentHash = invoice.map { String($0.paymentHash()) }
        let expiresAt = invoice.map { Int(clamping: min($0.secondsSinceEpoch(), .max - $0.expiryTimeSeconds()) + $0.expiryTimeSeconds()) }
        // Read before the checks, so a send on the other rail admitted after them refuses this one at submission.
        let mark = attemptMark
        if !channelsOnly, let rail = channelFreeRail, await shouldPayWithRail(rail, bolt11: bolt11, sats: sats) {
            // LDK refuses its own repeats; Spark doesn't, so a Spark send checks both rails.
            if let paid = try await settledEarlierAttempt(
                paymentHash: paymentHash,
                on: [.ldk, .channelFree],
                invoiceCreatedAt: invoice?.secondsSinceEpoch(),
                invoiceExpiresAt: expiresAt
            ) {
                return paid
            }
            guard beginRailSend(paymentHash: paymentHash) else { throw Self.pendingDuplicate(paymentHash: paymentHash) }
            defer { endRailSend(paymentHash: paymentHash) }
            // Spark takes no route parameters, so a caller's routing fee cap is checked against its estimate instead.
            if let maxFeeMsat = params?.maxTotalRoutingFeeMsat {
                let feeSats: UInt64
                do {
                    feeSats = try await rail.estimateRoutingFees(bolt11: bolt11, amountSats: sats)
                } catch {
                    Logger.warn("Spark fee estimate failed: \(error)", context: "LightningService")
                    throw error as? ChannelFreeRailSendRefused ?? ChannelFreeRailSendRefused(
                        reason: t("wallet__payment_failed_description"),
                        underlying: error
                    )
                }
                guard feeSats * 1000 <= maxFeeMsat else {
                    Logger.info("Spark routing fee of \(feeSats) sats exceeds the limit of \(maxFeeMsat / 1000) sats", context: "LightningService")
                    throw ChannelFreeRailSendRefused(reason: t("wallet__max_possible_fee_rate"))
                }
            }
            do {
                let sent = try await rail.send(
                    bolt11: bolt11,
                    sats: sats,
                    maxFeeSats: params?.maxTotalRoutingFeeMsat.map { $0 / 1000 }
                        ?? Self.paymentAmountSats(bolt11: bolt11, sats: sats).map(Self.defaultMaxFeeSats),
                    beforeSubmission: { [weak self] in
                        try beforeSubmission()
                        try self?.admitSend(paymentHash: paymentHash, on: .channelFree, since: mark)
                        // Noted once admitted, so a refused attempt never takes the place of the one that went out.
                        self?.noteAttempt(on: .channelFree, bolt11: bolt11)
                        self?.recordRailAttempt(paymentHash: paymentHash, expiresAt: expiresAt)
                        // Kept until the call returns, so a send cut off by process death stays held after a relaunch.
                        if let paymentHash {
                            self?.markRailSendUncertain(paymentHash: paymentHash, since: mark)
                        }
                    }
                )
                if let paymentHash {
                    endRailSendUncertainty(paymentHash: paymentHash)
                }
                return sent
            } catch let refusal as ChannelFreeRailSendRefused {
                // Nothing left the wallet, and the checks above leave no earlier live attempt under this hash.
                if let paymentHash {
                    endRailSendUncertainty(paymentHash: paymentHash)
                    releaseRailAttempt(paymentHash: paymentHash, unlessInFlight: false)
                }
                throw refusal
            } catch {
                // A send that failed once submitted may still go out, so its outcome waits for a later sync.
                if let paymentHash {
                    markRailSendUncertain(paymentHash: paymentHash, since: mark)
                }
                throw error
            }
        }
        if let paid = try await settledEarlierAttempt(
            paymentHash: paymentHash,
            on: [.channelFree],
            invoiceCreatedAt: invoice?.secondsSinceEpoch(),
            invoiceExpiresAt: expiresAt
        ) {
            return paid
        }
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        Logger.info("Paying bolt11: \(bolt11)")

        let sendKey = paymentHash?.lowercased()
        defer { endLdkSend(paymentHash: sendKey) }
        do {
            return try await Self.submitPayment(beforeSubmission: { [weak self] in
                try beforeSubmission()
                guard let self else { return }
                try admitSend(paymentHash: sendKey, on: .ldk, since: mark)
                noteAttempt(on: .ldk, bolt11: bolt11)
                recordLdkAttempt(paymentHash: paymentHash, expiresAt: expiresAt)
            }) {
                if let sats {
                    try node.bolt11Payment().sendUsingAmount(
                        invoice: .fromStr(invoiceStr: bolt11), amountMsat: sats * 1000, routeParameters: params
                    )
                } else {
                    try node.bolt11Payment().send(invoice: .fromStr(invoiceStr: bolt11), routeParameters: params)
                }
            }
        } catch {
            dumpLdkLogs()
            dumpNetworkGraphInfo(bolt11: bolt11)
            throw error
        }
    }

    /// The node's payment list; tests replace it, as they run without a node.
    lazy var nodePayments: () async -> [PaymentDetails]? = { [unowned self] in await listPayments() }

    /// Whether this build runs the channel-free rail, so a rail that isn't connected may still hold payments; the app
    /// sets it, as extensions build this service without the rail.
    var channelFreeRailSupported: () async -> Bool = { false }

    /// Payment hashes sent over the rail, kept across launches: while the rail can't list its payments, only these may
    /// have an attempt there that a node payment would repeat.
    var railAttemptsStore: UserDefaults = .standard
    /// The clock a trim checks invoice expiries against; tests set it.
    var now: () -> Date = Date.init
    private static let railAttemptsKey = "channelFreeRailAttemptedPaymentHashes"
    /// Rail sends submitted but not returned, or that failed after they were submitted, by hash, with the time they
    /// were submitted or failed in seconds since 1970. Kept across launches, as Spark may still resume one after a
    /// relaunch while its list shows an earlier failed attempt.
    private static let uncertainRailSendsKey = "channelFreeRailUncertainSendFailedAt"
    /// A listing drops the hashes it shows failed only, or paid once the invoice has expired, so the other rail can't
    /// pay it again, and ones it doesn't show once the invoice expired `unlistedAttemptSettleSeconds` ago. Paid or
    /// unlisted hashes with no known expiry (kept before expiries were, or whose invoice can't be parsed) are dropped
    /// oldest first only past this many per key. A hash whose payment may still be pending always stays.
    private static let railAttemptsLimit = 500
    /// No send starts after its invoice expires, and one settles within its HTLC timeout, which LDK caps at 1008
    /// blocks (about a week). Spark's routes are shorter, so twice that cap leaves room for slow blocks.
    private static let unlistedAttemptSettleSeconds = 14 * 24 * 60 * 60

    /// Payment hashes sent over the node, kept across launches: while the node can't list its payments (stopped or not
    /// started yet), only these may have an attempt there that a Spark payment would repeat.
    private static let ldkAttemptsKey = "ldkAttemptedPaymentHashes"
    /// Set once the node's own list has filled `ldkAttemptsKey`, as node payments made before it was kept carry no hash
    /// there. Until then an unlistable node refuses every Spark payment.
    static let ldkAttemptsSeededKey = "ldkAttemptedPaymentHashesSeeded"
    /// When the wallet was restored, in seconds since 1970, until Spark lists its sends after a sync since. No backup
    /// keeps `railAttemptsKey`, so until then an invoice made before the restore may be one Spark already paid.
    static let sparkHistoryUnseededSinceKey = "sparkHistoryUnseededSince"

    /// Called as a wallet is restored, before Spark starts.
    func markSparkHistoryUnseeded() {
        let since = Int(now().timeIntervalSince1970)
        eventCallbackLock.withLock {
            railAttemptsStore.set(since, forKey: Self.sparkHistoryUnseededSinceKey)
            railAttemptsStore.set(since, forKey: Self.sparkRestoredAtKey)
        }
    }

    /// When the wallet was restored, in seconds since 1970. Spark can report a sync while its payment history failed to
    /// sync, so its list can lack a send it made before then, and a still-valid invoice created before it that Spark
    /// hasn't listed as pending or paid is refused on either rail until it expires.
    static let sparkRestoredAtKey = "sparkRestoredAt"

    var sparkRestoredAt: Int? {
        eventCallbackLock.withLock { railAttemptsStore.object(forKey: Self.sparkRestoredAtKey) as? Int }
    }

    /// Called when a restore fails before the wallet exists, so nothing stays held for it.
    func clearSparkRestore() {
        clearSparkHistoryUnseeded()
        eventCallbackLock.withLock { railAttemptsStore.removeObject(forKey: Self.sparkRestoredAtKey) }
    }

    func clearSparkHistoryUnseeded() {
        eventCallbackLock.withLock { railAttemptsStore.removeObject(forKey: Self.sparkHistoryUnseededSinceKey) }
    }

    var sparkHistoryUnseededSince: Int? {
        eventCallbackLock.withLock { railAttemptsStore.object(forKey: Self.sparkHistoryUnseededSinceKey) as? Int }
    }

    /// Reads Spark's sends after its sync, which ends the hold on invoices made before a restore.
    func listRailSendsIfUnseeded() async {
        guard sparkHistoryUnseededSince != nil else { return }
        _ = try? await channelFreeRailPayments()
    }

    /// `expiresAt` is the invoice's expiry in seconds since 1970, kept beside each key's hashes.
    func recordRailAttempt(paymentHash: String?, expiresAt: Int? = nil) {
        recordAttempt(paymentHash: paymentHash, expiresAt: expiresAt, key: Self.railAttemptsKey)
    }

    func recordLdkAttempt(paymentHash: String?, expiresAt: Int? = nil) {
        recordAttempt(paymentHash: paymentHash, expiresAt: expiresAt, key: Self.ldkAttemptsKey)
    }

    private static func expiriesKey(_ key: String) -> String {
        key + "Expiries"
    }

    /// Callers hold `eventCallbackLock`.
    private func attemptExpiries(key: String) -> [String: Int] {
        railAttemptsStore.dictionary(forKey: Self.expiriesKey(key)) as? [String: Int] ?? [:]
    }

    /// A retry of a kept hash moves it to the newest end, so a trim working from a listing read before the retry
    /// drops older hashes first.
    private func recordAttempt(paymentHash: String?, expiresAt: Int?, key: String) {
        guard let paymentHash = paymentHash?.lowercased() else { return }
        eventCallbackLock.withLock {
            var hashes = railAttemptsStore.stringArray(forKey: key) ?? []
            hashes.removeAll { $0 == paymentHash }
            hashes.append(paymentHash)
            railAttemptsStore.set(hashes, forKey: key)
            attemptRecords += 1
            attemptRecordedAt[key, default: [:]][paymentHash] = attemptRecords
            var expiries = attemptExpiries(key: key)
            expiries[paymentHash] = expiresAt
            railAttemptsStore.set(expiries, forKey: Self.expiriesKey(key))
        }
    }

    /// Drops the hashes a listing showed as `failed` only, or as `paid` with an expired invoice, ones it didn't show
    /// (`listed` is every hash it shows) whose invoice expired past `unlistedAttemptSettleSeconds`, and past the limit
    /// the oldest paid or unlisted ones with no known expiry. A hash whose payment may still be pending (`live`) keeps
    /// holding the other rail, as does a paid one whose invoice can still be paid. Callers hold `eventCallbackLock`.
    private func trimSettledAttempts(paid: Set<String>, failed: Set<String>, listed: Set<String>, live: Set<String>, key: String) {
        guard let hashes = railAttemptsStore.stringArray(forKey: key) else { return }
        let expiries = attemptExpiries(key: key)
        let nowSeconds = Int(now().timeIntervalSince1970)
        // Against now minus the window, as an invoice that never expires is kept at Int.max.
        let isExpired = { (hash: String, settleSeconds: Int) in expiries[hash].map { $0 <= nowSeconds - settleSeconds } == true }
        let live = key == Self.railAttemptsKey ? live.union(uncertainRailSendFailedAt().keys) : live
        let unsettled = hashes.filter { hash in
            live.contains(hash) || !(failed.contains(hash) || paid.contains(hash) && isExpired(hash, 0)
                || !listed.contains(hash) && isExpired(hash, Self.unlistedAttemptSettleSeconds))
        }
        var excess = unsettled.count - Self.railAttemptsLimit
        var kept: [String] = []
        for hash in unsettled {
            if excess > 0, !live.contains(hash), expiries[hash] == nil, paid.contains(hash) || !listed.contains(hash) {
                excess -= 1
            } else {
                kept.append(hash)
            }
        }
        guard kept.count < hashes.count else { return }
        let keptSet = Set(kept)
        railAttemptsStore.set(kept, forKey: key)
        railAttemptsStore.set(expiries.filter { keptSet.contains($0.key) }, forKey: Self.expiriesKey(key))
        attemptRecordedAt[key] = attemptRecordedAt[key]?.filter { keptSet.contains($0.key) }
    }

    /// Called once the rail reports the attempt failed or lists none, so a channel retry isn't held while it can't list.
    /// With `unlessInFlight`, skipped while a rail send of the invoice is in flight, as that retry holds it again.
    /// With `since`, skipped too when the hash was in flight when `attemptMark` was read, or recorded after it, as a
    /// retry that ended or was recorded while a listing was read holds it again.
    func releaseRailAttempt(paymentHash: String, unlessInFlight: Bool = true, since mark: AttemptMark? = nil) {
        let hash = paymentHash.lowercased()
        eventCallbackLock.withLock {
            guard !unlessInFlight || !railSendsInFlight.contains(hash) else { return }
            // A send whose outcome is unknown may still go out, whatever an earlier attempt's state.
            guard uncertainRailSendFailedAt()[hash] == nil else { return }
            if let mark, attemptsLive(since: mark, key: Self.railAttemptsKey).contains(hash) {
                return
            }
            removeAttempt(paymentHash: hash, key: Self.railAttemptsKey)
        }
    }

    /// The attempts recorded so far and the sends in flight, read before a listing so a trim or release from it skips
    /// the retries recorded since, and the ones in flight then that ended while it was read.
    var attemptMark: AttemptMark {
        eventCallbackLock.withLock { AttemptMark(records: attemptRecords, railInFlight: railSendsInFlight, ldkInFlight: ldkSendsInFlight) }
    }

    private func releaseLdkAttempt(paymentHash: String) {
        eventCallbackLock.withLock { removeAttempt(paymentHash: paymentHash.lowercased(), key: Self.ldkAttemptsKey) }
    }

    /// Callers hold `eventCallbackLock`.
    private func removeAttempt(paymentHash hash: String, key: String) {
        removeAttempts([hash], key: key)
    }

    /// Callers hold `eventCallbackLock`.
    private func removeAttempts(_ removed: Set<String>, key: String) {
        guard var hashes = railAttemptsStore.stringArray(forKey: key), hashes.contains(where: removed.contains) else { return }
        hashes.removeAll { removed.contains($0) }
        railAttemptsStore.set(hashes, forKey: key)
        railAttemptsStore.set(attemptExpiries(key: key).filter { !removed.contains($0.key) }, forKey: Self.expiriesKey(key))
        removed.forEach { attemptRecordedAt[key]?[$0] = nil }
    }

    /// The hashes recorded under `key` after `attemptRecords` read `records`. Callers hold `eventCallbackLock`.
    private func attemptsRecorded(since records: Int, key: String) -> Set<String> {
        Set((attemptRecordedAt[key] ?? [:]).filter { $0.value > records }.keys)
    }

    /// The hashes under `key` that may still be pending since `mark`: in flight now or then, or recorded after it.
    /// Callers hold `eventCallbackLock`.
    private func attemptsLive(since mark: AttemptMark, key: String) -> Set<String> {
        let inFlight = key == Self.railAttemptsKey ? railSendsInFlight.union(mark.railInFlight) : ldkSendsInFlight.union(mark.ldkInFlight)
        return inFlight.union(attemptsRecorded(since: mark.records, key: key))
    }

    private func hasRailAttempt(paymentHash: String) -> Bool {
        hasAttempt(paymentHash: paymentHash, key: Self.railAttemptsKey)
    }

    private func hasAttempt(paymentHash: String, key: String) -> Bool {
        eventCallbackLock.withLock {
            railAttemptsStore.stringArray(forKey: key)?.contains(paymentHash.lowercased()) ?? false
        }
    }

    /// Called when the rail's wallet is wiped, as its payments go with it.
    func forgetRailAttempts() {
        eventCallbackLock.withLock {
            railAttemptsStore.removeObject(forKey: Self.uncertainRailSendsKey)
            railAttemptsStore.removeObject(forKey: Self.railAttemptsKey)
            railAttemptsStore.removeObject(forKey: Self.expiriesKey(Self.railAttemptsKey))
            attemptRecordedAt[Self.railAttemptsKey] = nil
        }
    }

    /// Called when the node's wallet is wiped, as its payments go with it.
    func forgetLdkAttempts() {
        eventCallbackLock.withLock {
            railAttemptsStore.removeObject(forKey: Self.ldkAttemptsKey)
            railAttemptsStore.removeObject(forKey: Self.expiriesKey(Self.ldkAttemptsKey))
            attemptRecordedAt[Self.ldkAttemptsKey] = nil
            railAttemptsStore.set(true, forKey: Self.ldkAttemptsSeededKey)
        }
    }

    /// The node's payments, after keeping its attempts from them, with the hashes still holding Spark (`live`); nil
    /// while the node can't list them.
    @discardableResult
    private func listNodePaymentsKeepingAttempts() async -> (payments: [PaymentDetails], live: Set<String>)? {
        let mark = attemptMark
        guard let payments = await nodePayments() else { return nil }
        let live = keepLdkAttempts(from: payments, since: mark)
        return (payments, live)
    }

    /// Keeps the hashes of the node's pending and paid outbound payments, once, so those made before hashes were kept
    /// hold Spark while the node can't list them. Then drops the ones listed only as failed that were recorded before
    /// the listing was read (`mark`), and trims paid ones past the limit. Returns the hashes still live.
    private func keepLdkAttempts(from payments: [PaymentDetails], since mark: AttemptMark) -> Set<String> {
        let outbound = payments.filter { $0.direction == .outbound }
        let sends = outbound
            .filter { $0.status != .failed }
            .sorted { $0.latestUpdateTimestamp < $1.latestUpdateTimestamp }
        let hashes = { (status: PaymentStatus) in Set(outbound.filter { $0.status == status }.map { $0.id.lowercased() }) }
        return eventCallbackLock.withLock {
            if !railAttemptsStore.bool(forKey: Self.ldkAttemptsSeededKey) {
                let kept = railAttemptsStore.stringArray(forKey: Self.ldkAttemptsKey) ?? []
                let seeded = sends.map { $0.id.lowercased() }.filter { !kept.contains($0) }
                railAttemptsStore.set(seeded + kept, forKey: Self.ldkAttemptsKey)
                railAttemptsStore.set(true, forKey: Self.ldkAttemptsSeededKey)
            }
            let live = hashes(.pending).union(attemptsLive(since: mark, key: Self.ldkAttemptsKey))
            let paid = hashes(.succeeded).subtracting(live)
            let listed = Set(outbound.map { $0.id.lowercased() })
            trimSettledAttempts(
                paid: paid, failed: hashes(.failed).subtracting(paid).subtracting(live), listed: listed, live: live, key: Self.ldkAttemptsKey
            )
            return live
        }
    }

    /// Trims the rail's settled hashes, so a payment that may still be pending, a send in flight when the listing was
    /// read (`mark`) or since, or one recorded after it keeps holding the node. Returns those live hashes.
    private func keepRailAttempts(from payments: [ChannelFreeRailPayment], since mark: AttemptMark) -> Set<String> {
        let outbound = payments.filter { $0.direction == .outbound }
        let hashes = { (status: PaymentStatus) in Set(outbound.filter { $0.status == status }.map { $0.paymentHash.lowercased() }) }
        return eventCallbackLock.withLock {
            let live = hashes(.pending).union(attemptsLive(since: mark, key: Self.railAttemptsKey))
            let paid = hashes(.succeeded).subtracting(live)
            let listed = Set(outbound.map { $0.paymentHash.lowercased() })
            trimSettledAttempts(
                paid: paid, failed: hashes(.failed).subtracting(paid).subtracting(live), listed: listed, live: live, key: Self.railAttemptsKey
            )
            return live
        }
    }

    private var hasSeededLdkAttempts: Bool {
        eventCallbackLock.withLock { railAttemptsStore.bool(forKey: Self.ldkAttemptsSeededKey) }
    }

    /// An invoice must never go out on both rails: an earlier attempt still pending on `rails` refuses the payment as a
    /// duplicate, as LDK does its own, and a settled one returns its hash as paid. A failed or unknown one lets the
    /// payment go. While either rail can't list its payments, an invoice it was sent over is refused as pending too, and
    /// while Spark hasn't listed its sends since a restore, one created (`invoiceCreatedAt`) before it is refused, as
    /// is one Spark's list doesn't show pending or paid until it expires (`refuseUnverifiedRestoredInvoice`).
    private func settledEarlierAttempt(
        paymentHash: String?,
        on rails: [LightningPaymentRail],
        invoiceCreatedAt: UInt64?,
        invoiceExpiresAt: Int?
    ) async throws -> PaymentHash? {
        guard let paymentHash else { return nil }
        var statuses: [PaymentStatus] = rails.contains(.channelFree) && isRailSendInFlight(paymentHash: paymentHash) ? [.pending] : []
        if rails.contains(.ldk) {
            if let (payments, live) = await listNodePaymentsKeepingAttempts() {
                let payment = payments.first {
                    $0.direction == .outbound && $0.id.caseInsensitiveCompare(paymentHash) == .orderedSame
                }
                if let payment {
                    statuses.append(payment.status)
                }
                // A retry in flight, or one recorded while the listing was read, holds the invoice as pending.
                if payment == nil || payment?.status == .failed {
                    if live.contains(paymentHash.lowercased()) {
                        statuses.append(.pending)
                    } else {
                        releaseLdkAttempt(paymentHash: paymentHash)
                    }
                }
            } else if hasAttempt(paymentHash: paymentHash, key: Self.ldkAttemptsKey) {
                Logger.warn("Refused paying '\(paymentHash)', the node can't list the earlier attempt now", context: "LightningService")
                throw Self.pendingDuplicate(paymentHash: paymentHash)
            } else if !hasSeededLdkAttempts {
                Logger.warn("Refused paying '\(paymentHash)' until the node lists its earlier payments once", context: "LightningService")
                throw AppError(serviceError: .nodeNotStarted)
            }
        }
        // The node's paid row is final, so no uncertainty about Spark's pre-restore sends refuses it.
        let isPaidOverTheNode = statuses.contains(.succeeded)
        if rails.contains(.channelFree) {
            let mark = attemptMark
            if let payments = await readableRailPayments() {
                let live = keepRailAttempts(from: payments, since: mark)
                let payment = ChannelFreeRailPayment.latestOutboundAttempt(payments, paymentHash: paymentHash)
                if let payment {
                    statuses.append(payment.status)
                }
                if payment == nil || payment?.status == .failed {
                    if live.contains(paymentHash.lowercased()) || isRailSendInFlight(paymentHash: paymentHash) {
                        statuses.append(.pending)
                    } else if await !railSyncedSinceUncertainSend(paymentHash: paymentHash) {
                        Logger.info("Held '\(paymentHash)' until Spark syncs after its unknown send", context: "LightningService")
                        statuses.append(.pending)
                    } else {
                        releaseRailAttempt(paymentHash: paymentHash)
                        if !isPaidOverTheNode {
                            try await refuseUnverifiedRestoredInvoice(
                                paymentHash: paymentHash, invoiceCreatedAt: invoiceCreatedAt, invoiceExpiresAt: invoiceExpiresAt
                            )
                        }
                    }
                } else if payment?.status == .succeeded {
                    // Only a settled row ends the unknown send: a pending one may be the synthetic row it is listed as.
                    endRailSendUncertainty(paymentHash: paymentHash)
                }
            } else if hasRailAttempt(paymentHash: paymentHash) {
                Logger.warn("Refused paying '\(paymentHash)', Spark can't list the earlier attempt now", context: "LightningService")
                throw Self.pendingDuplicate(paymentHash: paymentHash)
            } else if isPaidOverTheNode {
                Logger.info("Skipped Spark's restore checks of '\(paymentHash)', the node already paid it", context: "LightningService")
            } else if let invoiceCreatedAt, let since = sparkHistoryUnseededSince, Int(clamping: invoiceCreatedAt) < since {
                // Nothing left the wallet, and an invoice made after the restore can't be one Spark paid before it.
                Logger.warn("Refused paying '\(paymentHash)' until Spark lists its sends since the restore", context: "LightningService")
                throw ChannelFreeRailSendRefused.restoredInvoiceUnverified()
            } else {
                try await refuseUnverifiedRestoredInvoice(
                    paymentHash: paymentHash, invoiceCreatedAt: invoiceCreatedAt, invoiceExpiresAt: invoiceExpiresAt
                )
            }
        }
        if statuses.contains(.succeeded) {
            Logger.info("Skipped paying '\(paymentHash)', an earlier attempt already paid it", context: "LightningService")
            return paymentHash
        }
        if statuses.contains(.pending) {
            Logger.info("Refused paying '\(paymentHash)', an earlier attempt is still pending", context: "LightningService")
            throw Self.pendingDuplicate(paymentHash: paymentHash)
        }
        return nil
    }

    /// After a restore, refuses a still-valid invoice created before it, whatever Spark's sync said, until it expires.
    private func refuseUnverifiedRestoredInvoice(paymentHash: String, invoiceCreatedAt: UInt64?, invoiceExpiresAt: Int?) async throws {
        guard let restoredAt = sparkRestoredAt, Self.holdsRestoredInvoice(
            restoredAt: restoredAt,
            invoiceCreatedAt: invoiceCreatedAt,
            invoiceExpiresAt: invoiceExpiresAt,
            now: Int(now().timeIntervalSince1970)
        ) else { return }
        let sparkRuns = channelFreeRail != nil ? true : await channelFreeRailSupported()
        guard sparkRuns else { return }
        Logger.warn("Refused paying '\(paymentHash)', a pre-restore invoice Spark hasn't listed", context: "LightningService")
        throw ChannelFreeRailSendRefused.restoredInvoiceUnverified()
    }

    /// An unknown time counts as before the restore and never expiring.
    static func holdsRestoredInvoice(restoredAt: Int, invoiceCreatedAt: UInt64?, invoiceExpiresAt: Int?, now: Int) -> Bool {
        Int(clamping: invoiceCreatedAt ?? 0) < restoredAt && invoiceExpiresAt.map { now < $0 } ?? true
    }

    /// Nil while the rail's payments can't be read: listing them failed, or the rail runs here but isn't connected.
    private func readableRailPayments() async -> [ChannelFreeRailPayment]? {
        try? await channelFreeRailPayments()
    }

    /// Callers hold `eventCallbackLock`.
    private func uncertainRailSendFailedAt() -> [String: Int] {
        railAttemptsStore.dictionary(forKey: Self.uncertainRailSendsKey) as? [String: Int] ?? [:]
    }

    /// A rail send about to be submitted, or that failed after it was, until a sync after it and its invoice's expiry
    /// settle it. The expiry is the one kept beside the hash.
    private func markRailSendUncertain(paymentHash: String, since mark: AttemptMark) {
        let hash = paymentHash.lowercased()
        let failedAt = Int(max(0, now().timeIntervalSince1970))
        eventCallbackLock.withLock {
            guard attemptsRecorded(since: mark.records, key: Self.railAttemptsKey).contains(hash) else { return }
            var uncertain = uncertainRailSendFailedAt()
            uncertain[hash] = failedAt
            railAttemptsStore.set(uncertain, forKey: Self.uncertainRailSendsKey)
        }
    }

    /// Rail sends whose outcome stayed unknown, listed as pending until a sync after them reaches the rail: Spark may
    /// still finish one, while its own list shows only an earlier attempt, or nothing.
    private func unsettledUncertainRailSends() async -> [ChannelFreeRailPayment] {
        let hashes = eventCallbackLock.withLock { Array(uncertainRailSendFailedAt().keys) }
        var pending: [ChannelFreeRailPayment] = []
        for hash in hashes {
            if await !railSyncedSinceUncertainSend(paymentHash: hash) {
                pending.append(ChannelFreeRailPayment(paymentHash: hash, direction: .outbound, status: .pending, preimage: nil))
            }
        }
        return pending
    }

    /// Spark's kept sends whose invoice is unexpired. A sync can still resume one Spark committed but lists no row for,
    /// also after a relaunch, so it is pending until its invoice expires, the rule `railSyncedSinceUncertainSend` holds.
    private func unexpiredRailAttempts() -> Set<String> {
        let seconds = Int(now().timeIntervalSince1970)
        return eventCallbackLock.withLock {
            let expiries = attemptExpiries(key: Self.railAttemptsKey)
            let hashes = railAttemptsStore.stringArray(forKey: Self.railAttemptsKey) ?? []
            return Set(hashes.filter { hash in expiries[hash].map { $0 > seconds } ?? false })
        }
    }

    private func endRailSendUncertainty(paymentHash: String) {
        eventCallbackLock.withLock {
            var uncertain = uncertainRailSendFailedAt()
            guard uncertain.removeValue(forKey: paymentHash.lowercased()) != nil else { return }
            railAttemptsStore.set(uncertain, forKey: Self.uncertainRailSendsKey)
        }
    }

    /// True unless the hash's last rail send failed after it was submitted and may still go out: no sync has reached the
    /// rail since, or its invoice hasn't expired.
    private func railSyncedSinceUncertainSend(paymentHash: String) async -> Bool {
        let hash = paymentHash.lowercased()
        let uncertain = eventCallbackLock.withLock {
            uncertainRailSendFailedAt()[hash].map { (failedAt: UInt64($0), expiresAt: attemptExpiries(key: Self.railAttemptsKey)[hash]) }
        }
        guard let uncertain else { return true }
        guard let rail = channelFreeRail, await rail.hasSynced(after: uncertain.failedAt) else { return false }
        // Spark keeps a send it committed but didn't finish in a cache no call exposes, and a sync that reached Spark
        // can still fail to resume it, so only an expired invoice shows a missing send will never go out.
        guard let expiresAt = uncertain.expiresAt, Int(now().timeIntervalSince1970) >= expiresAt else { return false }
        endRailSendUncertainty(paymentHash: hash)
        return true
    }

    private static func pendingDuplicate(paymentHash: String?) -> NodeError {
        .DuplicatePayment(message: "An earlier attempt to pay '\(paymentHash ?? "")' is still pending")
    }

    func beginRailSend(paymentHash: String?) -> Bool {
        guard let paymentHash else { return true }
        return eventCallbackLock.withLock { railSendsInFlight.insert(paymentHash.lowercased()).inserted }
    }

    /// The last check before a send leaves on `rail`, under the same lock that marks the other rail's sends in flight,
    /// so of two sends of one invoice only the first admitted goes out. Refuses while the other rail has one in flight,
    /// or recorded one since `mark`. An admitted node send stays in flight until `endLdkSend`; a Spark send already is.
    func admitSend(paymentHash: String?, on rail: LightningPaymentRail, since mark: AttemptMark) throws {
        guard let hash = paymentHash?.lowercased() else { return }
        try eventCallbackLock.withLock {
            let otherInFlight = rail == .ldk ? railSendsInFlight : ldkSendsInFlight
            let otherKey = rail == .ldk ? Self.railAttemptsKey : Self.ldkAttemptsKey
            if otherInFlight.contains(hash) || attemptsRecorded(since: mark.records, key: otherKey).contains(hash) {
                Logger.warn("Refused paying '\(hash)', the other rail sent it meanwhile", context: "LightningService")
                throw Self.pendingDuplicate(paymentHash: hash)
            }
            if rail == .ldk {
                ldkSendsInFlight.insert(hash)
            }
        }
    }

    func beginLdkSend(paymentHash: String?) {
        guard let paymentHash else { return }
        _ = eventCallbackLock.withLock { ldkSendsInFlight.insert(paymentHash.lowercased()) }
    }

    func endLdkSend(paymentHash: String?) {
        guard let paymentHash else { return }
        _ = eventCallbackLock.withLock { ldkSendsInFlight.remove(paymentHash.lowercased()) }
    }

    func endRailSend(paymentHash: String?) {
        guard let paymentHash else { return }
        _ = eventCallbackLock.withLock { railSendsInFlight.remove(paymentHash.lowercased()) }
    }

    private func isRailSendInFlight(paymentHash: String) -> Bool {
        eventCallbackLock.withLock { railSendsInFlight.contains(paymentHash.lowercased()) }
    }

    static func submitPayment<Result>(
        beforeSubmission: @escaping () throws -> Void,
        send: @escaping () throws -> Result
    ) async throws -> Result {
        try await ServiceQueue.background(.ldk) {
            // Authorization can precede a queue wait; only the actual submission time is relevant here.
            try beforeSubmission()
            return try send()
        }
    }

    func closeChannel(userChannelId: ChannelId, counterpartyNodeId: PublicKey, force: Bool = false, forceCloseReason: String? = nil) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }

        return try await ServiceQueue.background(.ldk) {
            Logger.debug("Initiating channel close (force=\(force)): userChannelId=\(userChannelId)", context: "LightningService")

            if force {
                try node.forceCloseChannel(
                    userChannelId: userChannelId,
                    counterpartyNodeId: counterpartyNodeId,
                    reason: forceCloseReason ?? ""
                )
            } else {
                try node.closeChannel(
                    userChannelId: userChannelId,
                    counterpartyNodeId: counterpartyNodeId
                )
            }
        }
    }

    func closeChannel(_ channel: ChannelDetails, force: Bool = false, forceCloseReason: String? = nil) async throws {
        guard node != nil else {
            throw AppError(serviceError: .nodeNotStarted)
        }

        Logger.debug("closeChannel called to channel=\(channel), force=\(force)", context: "LightningService")

        return try await closeChannel(
            userChannelId: channel.userChannelId,
            counterpartyNodeId: channel.counterpartyNodeId,
            force: force,
            forceCloseReason: forceCloseReason
        )
    }

    func disconnectPeer(peer: PeerDetails) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        let uri = "\(peer.nodeId)@\(peer.address)"
        Logger.debug("Disconnecting peer: \(uri)")

        do {
            try await ServiceQueue.background(.ldk) {
                try node.disconnect(nodeId: peer.nodeId)
            }
            Logger.info("Peer disconnected: \(uri)")
        } catch {
            Logger.warn("Peer disconnect error: \(uri)")
            throw error
        }
    }

    func sign(message: String) async throws -> String {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        guard let msg = message.data(using: .utf8) else {
            throw AppError(serviceError: .invalidNodeSigningMessage)
        }

        return try await ServiceQueue.background(.ldk) {
            node.signMessage(msg: [UInt8](msg))
        }
    }

    func openChannel(peer: LnPeer, channelAmountSats: UInt64, pushToCounterpartySats: UInt64? = nil, channelConfig: ChannelConfig? = nil) async throws
        -> UserChannelId
    {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.openChannel(
                nodeId: peer.nodeId,
                address: peer.address,
                channelAmountSats: channelAmountSats,
                pushToCounterpartyMsat: pushToCounterpartySats == nil ? nil : pushToCounterpartySats! * 1000,
                channelConfig: channelConfig
            )
        }
    }

    func dumpLdkLogs() {
        let logFilePath = Logger.sessionLogFile
        let fileURL = URL(fileURLWithPath: logFilePath)

        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            print("*****LDK-NODE LOG******")
            for line in lines.suffix(20) {
                print(line)
            }
        } catch {
            Logger.error(error, context: "failed to load ldk log file: \(logFilePath)")
        }
    }

    func dumpNetworkGraphInfo(bolt11: String) {
        guard let node else {
            Logger.error("Node not available for network graph dump", context: "LightningService")
            return
        }

        let nodeIdPreviewLength = 20
        var sb = ""

        sb += "\n\n=== NETWORK GRAPH DUMP ===\n"

        // 1. Invoice Info
        do {
            let invoice = try Bolt11Invoice.fromStr(invoiceStr: bolt11)
            sb += "\nInvoice Info:\n"
            sb += "  - Payment Hash: \(invoice.paymentHash())\n"
            sb += "  - Invoice: \(bolt11)\n"
        } catch {
            sb += "\nFailed to parse bolt11 invoice: \(error)\n"
        }

        // 2. Our Node Info
        sb += "\nOur Node Info:\n"
        sb += "  - Node ID: \(node.nodeId())\n"

        // 3. Our Channels
        sb += "\nOur Channels:\n"
        let channels = node.listChannels()
        sb += "  Total channels: \(channels.count)\n"

        var totalOutboundMsat: UInt64 = 0
        var totalInboundMsat: UInt64 = 0
        var usableChannels = 0
        var announcedChannels = 0

        for (index, channel) in channels.enumerated() {
            totalOutboundMsat += channel.outboundCapacityMsat
            totalInboundMsat += channel.inboundCapacityMsat
            if channel.isUsable {
                usableChannels += 1
            }
            if channel.isAnnounced {
                announcedChannels += 1
            }

            sb += "  Channel \(index + 1):\n"
            sb += "    - Channel ID: \(channel.channelId)\n"
            sb += "    - Counterparty: \(channel.counterpartyNodeId)\n"
            sb += "    - Ready: \(channel.isChannelReady), Usable: \(channel.isUsable), Announced: \(channel.isAnnounced)\n"
            sb += "    - Outbound: \(channel.outboundCapacityMsat) msat, Inbound: \(channel.inboundCapacityMsat) msat\n"
        }

        sb += "\n  Channel Summary:\n"
        sb += "    - Usable channels: \(usableChannels)/\(channels.count)\n"
        sb += "    - Announced channels: \(announcedChannels)/\(channels.count)\n"
        sb += "    - Total Outbound: \(totalOutboundMsat) msat\n"
        sb += "    - Total Inbound: \(totalInboundMsat) msat\n"

        // 4. Our Peers
        sb += "\nOur Peers:\n"
        let peers = node.listPeers()
        sb += "  Total peers: \(peers.count)\n"

        for (index, peer) in peers.enumerated() {
            let nodeIdPreview = String(peer.nodeId.prefix(nodeIdPreviewLength))
            sb += "  Peer \(index + 1): \(nodeIdPreview)... @ \(peer.address)\n"
        }

        // 5. RGS Configuration
        sb += "\nRGS Configuration:\n"
        sb += "  - RGS Server URL: \(Env.ldkRgsServerUrl ?? "Not configured")\n"

        let nodeStatus = node.status()
        if let rgsTimestamp = nodeStatus.latestRgsSnapshotTimestamp {
            let date = Date(timeIntervalSince1970: TimeInterval(rgsTimestamp))
            let timeAgo = Date().timeIntervalSince(date)
            let hoursAgo = Int(timeAgo / 3600)
            let minutesAgo = Int((timeAgo.truncatingRemainder(dividingBy: 3600)) / 60)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.timeZone = TimeZone(abbreviation: "UTC")

            sb += "  - Last RGS Snapshot: \(formatter.string(from: date))\n"
            if hoursAgo > 0 {
                sb += "  - Time since update: \(hoursAgo)h \(minutesAgo)m ago\n"
            } else {
                sb += "  - Time since update: \(minutesAgo)m ago\n"
            }
            sb += "  - Timestamp: \(rgsTimestamp)\n"
        } else {
            sb += "  - Last RGS Snapshot: Never synced\n"
            sb += "  - WARNING: Network graph may be empty or stale!\n"
        }

        // 6. Network Graph Data
        sb += "\nRGS Network Graph Data:\n"
        let networkGraph = node.networkGraph()
        let allNodes = networkGraph.listNodes()
        let allChannels = networkGraph.listChannels()

        sb += "  Total nodes: \(allNodes.count)\n"
        sb += "  Total channels: \(allChannels.count)\n"

        // Show first 10 nodes
        let nodesToShow = min(10, allNodes.count)
        sb += "\n  First \(nodesToShow) nodes:\n"
        for (index, nodeId) in allNodes.prefix(nodesToShow).enumerated() {
            sb += "    \(index + 1). \(nodeId.description)\n"
        }
        if allNodes.count > nodesToShow {
            sb += "    ... and \(allNodes.count - nodesToShow) more nodes\n"
        }

        sb += "\n=== END NETWORK GRAPH DUMP ===\n"

        Logger.info(sb, context: "LightningService")
    }

    func logNetworkGraphInfo() async throws -> String {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        let nodeStatus = node.status()
        let networkGraph = node.networkGraph()
        let allNodes = networkGraph.listNodes()
        let lastRgsSync = nodeStatus.latestRgsSnapshotTimestamp

        var lastRgsSyncString = "Never"
        if let lastRgsSync {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
            lastRgsSyncString = dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(lastRgsSync)))
        }

        return "Nodes: \(allNodes.count), Last Synced: \(lastRgsSyncString)"
    }

    // MARK: - Configuration Helpers

    private func configureGossipSource(builder: Builder, rgsServerUrl: String?) {
        let rgsUrl = rgsServerUrl ?? Env.ldkRgsServerUrl
        if let rgsUrl, !rgsUrl.isEmpty {
            Logger.info("Using gossip source rgs url: \(rgsUrl)")
            builder.setGossipSourceRgs(rgsServerUrl: rgsUrl)
        } else {
            Logger.info("Using gossip source p2p")
            builder.setGossipSourceP2p()
        }
    }
}

// MARK: UI Helpers (Published via WalletViewModel)

extension LightningService {
    struct ProbeDispatch {
        let paymentIds: Set<PaymentId>
    }

    var nodeId: String? {
        node?.nodeId()
    }

    var hasNode: Bool {
        node != nil
    }

    /// Use cached values to avoid blocking LDK calls on main thread
    @MainActor var balances: BalanceDetails? {
        cachedBalances
    }

    @MainActor var status: NodeStatus? {
        cachedStatus
    }

    @MainActor var peers: [PeerDetails]? {
        cachedPeers
    }

    @MainActor var channels: [ChannelDetails]? {
        cachedChannels
    }

    func listPayments() async -> [PaymentDetails]? {
        try? await ServiceQueue.background(.ldk) { [self] in
            node?.listPayments()
        }
    }

    /// Refresh all cached values asynchronously
    /// Fetches from LDK on background queue, updates cache on main actor
    func refreshCache() async {
        // Skip if node isn't set up yet - don't block on the LDK queue
        guard node != nil else { return }

        do {
            // Fetch all values in a single background queue call
            let (newStatus, newBalances, newPeers, newChannels) = try await ServiceQueue.background(.ldk) { [self] in
                (
                    node?.status(),
                    node?.listBalances(),
                    node?.listPeers(),
                    node?.listChannels()
                )
            }

            // Update cache on main actor
            await MainActor.run {
                cachedStatus = newStatus
                cachedBalances = newBalances
                cachedPeers = newPeers
                cachedChannels = newChannels
            }
        } catch {
            Logger.error("Failed to refresh cache: \(error)", context: "LightningService")
        }
    }

    /// Clear cached values - only call when wiping storage or resetting the wallet.
    @MainActor
    func clearCache() {
        cachedStatus = nil
        cachedBalances = nil
        cachedPeers = nil
        cachedChannels = nil
    }

    /// Get balance for a specific address in satoshis
    /// - Parameter address: The Bitcoin address to check
    /// - Returns: The current balance in satoshis
    /// - Throws: AppError if node is not setup
    func getAddressBalance(address: String) async throws -> UInt64 {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.getAddressBalance(addressStr: address)
        }
    }

    func getBalanceForAddressType(_ addressType: LDKNode.AddressType) async throws -> AddressTypeBalance {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.getBalanceForAddressType(addressType: addressType)
        }
    }

    func addAddressTypeToMonitor(_ addressType: LDKNode.AddressType) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: currentWalletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphraseRaw = try? Keychain.loadString(key: .bip39Passphrase(index: currentWalletIndex))
        let passphrase = passphraseRaw?.isEmpty == true ? nil : passphraseRaw

        try await ServiceQueue.background(.ldk) {
            try node.addAddressTypeToMonitorWithMnemonic(addressType: addressType, mnemonic: mnemonic, passphrase: passphrase)
        }
    }

    func removeAddressTypeFromMonitor(_ addressType: LDKNode.AddressType) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        try await ServiceQueue.background(.ldk) {
            try node.removeAddressTypeFromMonitor(addressType: addressType)
        }
    }

    func listMonitoredAddressTypes() -> [LDKNode.AddressType] {
        guard let node else { return [] }
        return node.listMonitoredAddressTypes()
    }

    func setPrimaryAddressType(_ addressType: LDKNode.AddressType) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: currentWalletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphraseRaw = try? Keychain.loadString(key: .bip39Passphrase(index: currentWalletIndex))
        let passphrase = passphraseRaw?.isEmpty == true ? nil : passphraseRaw

        try await ServiceQueue.background(.ldk) {
            try node.setPrimaryAddressTypeWithMnemonic(addressType: addressType, mnemonic: mnemonic, passphrase: passphrase)
        }
    }

    /// Sum of spendable on-chain balance for non-legacy address types (selected + monitored), for channel funding.
    /// - Parameters:
    ///   - selectedType: Current primary address type.
    ///   - monitoredTypes: Address types currently monitored (from settings).
    func getChannelFundableBalance(selectedType: LDKNode.AddressType, monitoredTypes: [LDKNode.AddressType]) async throws -> UInt64 {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        var typesToSum = Set<LDKNode.AddressType>()
        if selectedType != .legacy {
            typesToSum.insert(selectedType)
        }
        for type in monitoredTypes where type != .legacy {
            typesToSum.insert(type)
        }

        var totalFundable: UInt64 = 0

        for addressType in typesToSum {
            do {
                let balance = try await ServiceQueue.background(.ldk) {
                    try node.getBalanceForAddressType(addressType: addressType)
                }
                totalFundable += balance.spendableSats
            } catch {
                Logger.warn("Failed to get balance for \(addressType) when calculating channel fundable balance: \(error)")
            }
        }

        return totalFundable
    }

    /// Builds the node config. LSP peers are not trusted for zero-conf channels or to broadcast our force
    /// closes: Blocktank no longer serves channels, so our node must broadcast and fee-bump its own closes.
    static func nodeConfig(walletIndex: Int) -> Config {
        var config = defaultConfig()
        config.storageDirPath = Env.ldkStorage(walletIndex: walletIndex).path
        config.network = Env.network
        config.probingLiquidityLimitMultiplier = 1
        config.trustedPeers0conf = []
        config.anchorChannelsConfig = .init(
            trustedPeersNoReserve: [],
            perChannelReserveSats: 1
        )
        config.includeUntrustedPendingInSpendable = true
        return config
    }

    /// Reads selected and monitored address types from UserDefaults and keeps native SegWit enabled
    /// so delayed Blocktank refund payments remain detectable.
    static func addressTypeStateFromUserDefaults(_ defaults: UserDefaults = .standard)
        -> (selectedType: LDKNode.AddressType, monitoredTypes: [LDKNode.AddressType])
    {
        let selectedType = LDKNode.AddressType.fromStorage(defaults.string(forKey: "selectedAddressType"))
        let monitoredString = defaults.string(forKey: "addressTypesToMonitor") ?? "nativeSegwit"
        var monitoredTypes = LDKNode.AddressType.parseCommaSeparated(monitoredString)
        if !monitoredTypes.contains(.nativeSegwit) {
            monitoredTypes.append(.nativeSegwit)
            defaults.set(monitoredTypes.map(\.stringValue).joined(separator: ","), forKey: "addressTypesToMonitor")
        }
        return (selectedType, monitoredTypes)
    }

    /// Get a channel by ID from the channel cache
    /// This is more reliable than using the cachedChannels array when handling events,
    /// as the channelCache is updated immediately when channel events occur
    func getChannelFromCache(channelId: ChannelId) async -> ChannelDetails? {
        let channelIdString = channelId.description
        return await MainActor.run {
            channelCache[channelIdString]
        }
    }

    @MainActor var channelCacheCount: Int {
        channelCache.count
    }
}

// MARK: Events

extension LightningService {
    /// Delivers a channel-free rail's payment as an LDK event, so flows that wait on node events cover both rails.
    /// Sets the callback node and rail events are delivered to, and delivers the rail events that arrived before it.
    func setEventCallback(_ onEvent: @escaping (Event) -> Void) {
        let pending = eventCallbackLock.withLock {
            storedEventCallback = onEvent
            defer { pendingChannelFreeRailEvents = [] }
            return pendingChannelFreeRailEvents
        }
        pending.forEach(onEvent)
    }

    /// Drops the event callback and the rail events waiting for it.
    func clearEventCallback() {
        eventCallbackLock.withLock {
            storedEventCallback = nil
            pendingChannelFreeRailEvents = []
        }
    }

    /// Spark runs before the node starts, so its events wait until the node's event callback is set rather than being lost.
    func emitChannelFreeRailEvent(_ event: Event) {
        switch event {
        case let .paymentFailed(_, paymentHash?, _):
            // The event settles a send whose outcome was unknown, so retries of its invoice are no longer held.
            endRailSendUncertainty(paymentHash: paymentHash)
            // The failure of the send itself, which may arrive while its send call is still returning.
            releaseRailAttempt(paymentHash: paymentHash, unlessInFlight: false)
        case let .paymentSuccessful(_, paymentHash, _, _):
            endRailSendUncertainty(paymentHash: paymentHash)
        default:
            break
        }
        if isStaleFailure(event, from: .channelFree) {
            Logger.info("Ignored a Spark failure for a payment retried over a channel: \(event)", context: "LightningService")
            return
        }
        let callback = eventCallbackLock.withLock {
            if storedEventCallback == nil {
                pendingChannelFreeRailEvents.append(event)
            }
            return storedEventCallback
        }
        callback?(event)
    }

    func noteAttempt(on rail: LightningPaymentRail, paymentHash: String) {
        eventCallbackLock.withLock { attemptRails[paymentHash.lowercased()] = rail }
    }

    private func noteAttempt(on rail: LightningPaymentRail, bolt11: String) {
        guard let hash = try? Bolt11Invoice.fromStr(invoiceStr: bolt11).paymentHash() else { return }
        noteAttempt(on: rail, paymentHash: String(hash))
    }

    /// The rail the latest attempt to pay `paymentHash` went out on, nil when none went out since launch.
    func attemptRail(paymentHash: String) -> LightningPaymentRail? {
        eventCallbackLock.withLock { attemptRails[paymentHash.lowercased()] }
    }

    /// A failure `rail` reports for a payment whose latest attempt went out on the other rail: it ended an earlier
    /// attempt, so it must not settle the retry.
    func isStaleFailure(paymentHash: String, from rail: LightningPaymentRail) -> Bool {
        guard let current = attemptRail(paymentHash: paymentHash) else { return false }
        return current != rail
    }

    func isStaleFailure(_ event: Event, from rail: LightningPaymentRail) -> Bool {
        guard case let .paymentFailed(paymentId, paymentHash, _) = event, let hash = paymentHash ?? paymentId else { return false }
        return isStaleFailure(paymentHash: hash, from: rail)
    }

    /// The rail's Lightning payments, none where the rail doesn't run; throws when the rail could not list them, runs
    /// here but isn't connected, or no sync has reached it yet, so a payment it may hold is never read as one it never
    /// made.
    func channelFreeRailPayments() async throws -> [ChannelFreeRailPayment] {
        // During an emergency exit Spark is off the rail but still lists the payments it made.
        if let rail = channelFreeRail ?? channelFreePaymentHistory {
            // A restored wallet fills its list on its first sync, so before a sync reaches Spark a missing send proves
            // nothing.
            guard await rail.hasSynced(after: nil) else { throw ChannelFreeRailUnavailable() }
            // Read before the listing, so a sync that ends while it is read can't settle a send the listing predates.
            let unsettled = await unsettledUncertainRailSends()
            let kept = unexpiredRailAttempts()
            let payments = try await rail.lightningPayments()
            if let since = sparkHistoryUnseededSince, await rail.hasSynced(after: UInt64(clamping: since)) {
                // Kept, so after a relaunch the sends Spark listed hold the node until Spark syncs again.
                let seeded = payments.filter { $0.direction == .outbound && $0.status != .failed }.map { $0.paymentHash.lowercased() }
                eventCallbackLock.withLock {
                    let hashes = railAttemptsStore.stringArray(forKey: Self.railAttemptsKey) ?? []
                    let added = Array(Set(seeded).subtracting(hashes)).sorted()
                    railAttemptsStore.set(added + hashes, forKey: Self.railAttemptsKey)
                }
                clearSparkHistoryUnseeded()
            }
            let listed = Set((payments + unsettled).filter { $0.direction == .outbound }.map { $0.paymentHash.lowercased() })
            let unlisted = kept.subtracting(listed).sorted()
                .map { ChannelFreeRailPayment(paymentHash: $0, direction: .outbound, status: .pending, preimage: nil) }
            return payments + unsettled + unlisted
        }
        if await channelFreeRailSupported() {
            throw ChannelFreeRailUnavailable()
        }
        return []
    }

    func deliverEvent(_ event: Event, onEvent: ((Event) -> Void)?) async -> OnchainActivityCompletion? {
        let completion: OnchainActivityCompletion? = switch event {
        case .onchainTransactionReceived, .onchainTransactionConfirmed, .onchainTransactionReplaced,
             .onchainTransactionReorged, .onchainTransactionEvicted:
            // Capture ownership before raw delivery or asynchronous activity processing can replace the session.
            await MainActor.run { onchainActivityWillPersist?() }
        default:
            nil
        }
        onEvent?(event)
        return completion
    }

    func persistOnchainActivity(completion: OnchainActivityCompletion?, operation: () async throws -> Void) async throws {
        try await operation()
        await completion?()
    }

    func listenForEvents(onEvent: ((Event) -> Void)? = nil) {
        Task {
            while true {
                guard let node = self.node else {
                    Logger.error("LDK node not started")
                    return
                }

                let event = await node.nextEventAsync()

                do {
                    try node.eventHandled()
                } catch {
                    Logger.error(error, context: "node.eventHandled()")
                }

                if case .channelReady = event {
                    await refreshChannelCache()
                }

                if self.isStaleFailure(event, from: .ldk) {
                    Logger.info("Ignored an LDK failure for a payment retried over Spark: \(event)", context: "LightningService")
                    continue
                }

                let onchainActivityCompletion = await deliverEvent(event, onEvent: onEvent)

                switch event {
                case let .paymentSuccessful(paymentId, paymentHash, _, feePaidMsat):
                    Logger.info("✅ Payment successful: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash) feePaidMsat: \(feePaidMsat ?? 0)")
                    Task {
                        let hash = paymentId ?? paymentHash
                        do {
                            try await CoreService.shared.activity.handlePaymentEvent(paymentHash: hash)
                        } catch {
                            Logger.error("Failed to handle payment success for \(hash): \(error)", context: "LightningService")
                        }
                    }
                case let .paymentFailed(paymentId, paymentHash, reason):
                    Logger.info(
                        "❌ Payment failed: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash ?? "") reason: \(reason.debugDescription)"
                    )
                    Task {
                        if let hash = paymentId ?? paymentHash {
                            do {
                                try await CoreService.shared.activity.handlePaymentEvent(paymentHash: hash)
                            } catch {
                                Logger.error("Failed to handle payment failure for \(hash): \(error)", context: "LightningService")
                            }
                        } else {
                            Logger.warn("No paymentId or paymentHash available for failed payment", context: "LightningService")
                        }
                    }
                case let .paymentReceived(paymentId, paymentHash, amountMsat, _):
                    Logger.info("🤑 Payment received: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash) amountMsat: \(amountMsat)")
                    Task {
                        let hash = paymentId ?? paymentHash
                        do {
                            try await CoreService.shared.activity.handlePaymentEvent(paymentHash: hash)
                        } catch {
                            Logger.error("Failed to handle payment received for \(hash): \(error)", context: "LightningService")
                        }
                    }
                case let .paymentClaimable(paymentId, paymentHash, claimableAmountMsat, _, _):
                    Logger.info(
                        "🫰 Payment claimable: paymentId: \(paymentId) paymentHash: \(paymentHash) claimableAmountMsat: \(claimableAmountMsat)"
                    )
                case let .probeSuccessful(paymentId, paymentHash, _):
                    Logger.info("🤑 Probe successful: paymentId: \(paymentId) paymentHash: \(paymentHash)")
                case let .probeFailed(paymentId, paymentHash, shortChannelId, _):
                    Logger
                        .info(
                            "❌ Probe failed: paymentId: \(paymentId) paymentHash: \(paymentHash) shortChannelId: \(String(describing: shortChannelId))"
                        )
                // Payment claimable doesn't need activity update - it's still pending
                // The payment will be updated when it succeeds or fails via paymentSuccessful/paymentFailed events
                case let .channelPending(channelId, userChannelId, formerTemporaryChannelId, counterpartyNodeId, fundingTxo):
                    Logger.info(
                        "⏳ Channel pending: channelId: \(channelId) userChannelId: \(userChannelId) formerTemporaryChannelId: \(formerTemporaryChannelId) counterpartyNodeId: \(counterpartyNodeId) fundingTxo: \(fundingTxo)"
                    )
                    await refreshChannelCache()
                case let .channelReady(channelId, userChannelId, counterpartyNodeId, fundingTxo):
                    Logger.info(
                        "👐 Channel ready: channelId: \(channelId) userChannelId: \(userChannelId) counterpartyNodeId: \(counterpartyNodeId ?? "?") fundingTxo: \(fundingTxo != nil ? "\(fundingTxo!.txid):\(fundingTxo!.vout)" : "nil")"
                    )
                case let .channelClosed(channelId, userChannelId, counterpartyNodeId, reason):
                    let reasonString = reason.map { String(describing: $0) } ?? ""
                    Logger.info(
                        "⛔ Channel closed: channelId: \(channelId) userChannelId: \(userChannelId) counterpartyNodeId: \(counterpartyNodeId ?? "?") reason: \(reasonString)"
                    )

                    let channelIdString = channelId.description
                    let channel = await MainActor.run {
                        channelCache[channelIdString]
                    }

                    if let channel {
                        await registerClosedChannel(channel: channel, reason: reasonString)
                        _ = await MainActor.run {
                            channelCache.removeValue(forKey: channelIdString)
                        }
                    } else {
                        Logger.error(
                            "Could not find channel details for closed channel: channelId=\(channelIdString) userChannelId=\(userChannelId) in cache",
                            context: "LightningService"
                        )
                    }
                case .paymentForwarded:
                    break

                // MARK: New Onchain Transaction Events

                case let .onchainTransactionReceived(txid, details):
                    Logger.info("📥 Onchain transaction received: txid=\(txid) amountSats=\(details.amountSats)")
                    Task {
                        await self.onchainTransactionReceived?(txid)
                        do {
                            try await self.persistOnchainActivity(completion: onchainActivityCompletion) {
                                try await CoreService.shared.activity.handleOnchainTransactionReceived(txid: txid, details: details)
                            }
                        } catch {
                            Logger.error("Failed to handle transaction received for \(txid): \(error)", context: "LightningService")
                        }
                    }
                case let .onchainTransactionConfirmed(txid, _, blockHeight, _, details):
                    Logger.info("✅ Onchain transaction confirmed: txid=\(txid) blockHeight=\(blockHeight) amountSats=\(details.amountSats)")
                    Task {
                        if let onchainTransactionConfirmed = self.onchainTransactionConfirmed {
                            await onchainTransactionConfirmed(txid)
                        }
                        do {
                            try await self.persistOnchainActivity(completion: onchainActivityCompletion) {
                                try await CoreService.shared.activity.handleOnchainTransactionConfirmed(
                                    txid: txid,
                                    details: details
                                )
                            }
                        } catch {
                            Logger.error("Failed to handle transaction confirmed for \(txid): \(error)", context: "LightningService")
                        }
                    }
                case let .onchainTransactionReplaced(txid, conflicts):
                    Logger.info("🔄 Onchain transaction replaced (RBF): txid=\(txid) by \(conflicts.count) conflict(s)")
                    Task {
                        do {
                            try await self.persistOnchainActivity(completion: onchainActivityCompletion) {
                                try await CoreService.shared.activity.handleOnchainTransactionReplaced(txid: txid, conflicts: conflicts)
                            }
                        } catch {
                            Logger.error("Failed to handle transaction replaced for \(txid): \(error)", context: "LightningService")
                        }
                    }
                case let .onchainTransactionReorged(txid):
                    Logger.warn("⚠️ Onchain transaction reorged (unconfirmed): txid=\(txid)")
                    Task {
                        do {
                            try await self.persistOnchainActivity(completion: onchainActivityCompletion) {
                                try await CoreService.shared.activity.handleOnchainTransactionReorged(txid: txid)
                            }
                        } catch {
                            Logger.error("Failed to handle transaction reorged for \(txid): \(error)", context: "LightningService")
                        }
                    }
                case let .onchainTransactionEvicted(txid):
                    Logger.warn("🗑️ Onchain transaction removed from mempool: txid=\(txid)")
                    Task {
                        do {
                            try await self.persistOnchainActivity(completion: onchainActivityCompletion) {
                                try await CoreService.shared.activity.handleOnchainTransactionEvicted(txid: txid)
                            }
                        } catch {
                            Logger.error("Failed to handle transaction evicted for \(txid): \(error)", context: "LightningService")
                        }
                    }

                // MARK: Sync Events

                case let .syncProgress(syncType, progressPercent, currentBlockHeight, targetBlockHeight):
                    Logger
                        .debug(
                            "🔄 Sync progress: type=\(syncType) progress=\(progressPercent)% current=\(currentBlockHeight) target=\(targetBlockHeight)"
                        )
                case let .syncCompleted(syncType, syncedBlockHeight):
                    Logger.info("✅ Sync completed: type=\(syncType) height=\(syncedBlockHeight)")
                    // Send sync status update - PassthroughSubject is thread-safe
                    syncStatusChangedSubject.send(UInt64(Date().timeIntervalSince1970))

                // MARK: Balance Events

                case let .balanceChanged(oldSpendableOnchain, newSpendableOnchain, _, _, oldLightning, newLightning):
                    Logger
                        .info("💰 Balance changed: onchain=\(oldSpendableOnchain)->\(newSpendableOnchain) lightning=\(oldLightning)->\(newLightning)")

                // MARK: Splice Events

                case let .splicePending(channelId, userChannelId, counterpartyNodeId, newFundingTxo):
                    Logger
                        .info(
                            "🔀 Splice pending: channelId=\(channelId) userChannelId=\(userChannelId) counterpartyNodeId=\(counterpartyNodeId) newFundingTxo=\(newFundingTxo)"
                        )
                    await refreshChannelCache()
                case let .spliceFailed(channelId, userChannelId, counterpartyNodeId, abandonedFundingTxo):
                    Logger
                        .warn(
                            "❌ Splice failed: channelId=\(channelId) userChannelId=\(userChannelId) counterpartyNodeId=\(counterpartyNodeId) abandonedFundingTxo=\(abandonedFundingTxo != nil ? "\(abandonedFundingTxo!.txid):\(abandonedFundingTxo!.vout)" : "nil")"
                        )
                }
            }
        }
    }

    private func registerClosedChannel(
        channel: ChannelDetails,
        reason: String
    ) async {
        do {
            let channelName: String
            if let scidAlias = channel.inboundScidAlias {
                channelName = String(scidAlias)
            } else {
                let channelIdString = channel.channelId.description
                let prefix = String(channelIdString.prefix(10))
                channelName = "\(prefix)…"
            }

            guard let fundingTxo = channel.fundingTxo else {
                Logger.error("Channel has no funding transaction", context: "LightningService")
                return
            }

            let closedChannel = ClosedChannelDetails(
                channelId: channel.channelId.description,
                counterpartyNodeId: channel.counterpartyNodeId.description,
                fundingTxoTxid: fundingTxo.txid.description,
                fundingTxoIndex: fundingTxo.vout,
                channelValueSats: channel.channelValueSats,
                closedAt: UInt64(Date().timeIntervalSince1970),
                outboundCapacityMsat: channel.outboundCapacityMsat,
                inboundCapacityMsat: channel.inboundCapacityMsat,
                counterpartyUnspendablePunishmentReserve: channel.counterpartyUnspendablePunishmentReserve,
                unspendablePunishmentReserve: channel.unspendablePunishmentReserve ?? 0,
                forwardingFeeProportionalMillionths: channel.config.forwardingFeeProportionalMillionths,
                forwardingFeeBaseMsat: channel.config.forwardingFeeBaseMsat,
                channelName: channelName,
                channelClosureReason: reason
            )

            try await CoreService.shared.activity.upsertClosedChannel(closedChannel)
            Logger.info("Registered closed channel: \(channel.userChannelId)", context: "LightningService")
        } catch {
            Logger.error("Failed to register closed channel: \(error)", context: "LightningService")
        }
    }
}

// MARK: UTXO selection

extension LightningService {
    func listSpendableOutputs() async throws -> [SpendableUtxo] {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment().listSpendableOutputs()
        }
    }

    func selectUtxosWithAlgorithm(
        targetAmountSats: UInt64, satsPerVbyte: UInt32, coinSelectionAlgorythm: CoinSelectionAlgorithm, utxos: [SpendableUtxo]?
    ) async throws -> [SpendableUtxo] {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment()
                .selectUtxosWithAlgorithm(
                    targetAmountSats: targetAmountSats,
                    feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVbyte),
                    algorithm: coinSelectionAlgorythm,
                    utxos: utxos
                )
        }
    }
}

// MARK: Boost txs

extension LightningService {
    func bumpFeeByRbf(txid: String, satsPerVbyte: UInt32) async throws -> Txid {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment()
                .bumpFeeByRbf(
                    txid: txid,
                    feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVbyte)
                )
        }
    }

    func accelerateByCpfp(txid: String, satsPerVbyte: UInt32? = nil, destinationAddress: String? = nil) async throws -> Txid {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment()
                .accelerateByCpfp(
                    txid: txid,
                    feeRate: satsPerVbyte != nil ? Self.convertVByteToKwu(satsPerVByte: satsPerVbyte!) : nil,
                    destinationAddress: destinationAddress
                )
        }
    }

    func calculateCpfpFeeRate(parentTxid: String, urgent: Bool) async throws -> FeeRate {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment()
                .calculateCpfpFeeRate(
                    parentTxid: parentTxid,
                    urgent: urgent
                )
        }
    }
}

// MARK: Fees

extension LightningService {
    /// Calculates the total fee for a transaction
    /// - Parameters:
    ///   - address: The destination address
    ///   - amountSats: The amount to send in satoshis
    ///   - satsPerVByte: The fee rate in satoshis per virtual byte
    ///   - utxosToSpend: Optional specific UTXOs to spend
    /// - Returns: The total fee in satoshis
    /// - Throws: ServiceError if node is not setup or calculation fails
    func calculateTotalFee(
        address: String,
        amountSats: UInt64,
        satsPerVByte: UInt32,
        utxosToSpend: [SpendableUtxo]? = nil
    ) async throws -> UInt64 {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            return try node.onchainPayment().calculateTotalFee(
                address: address,
                amountSats: amountSats,
                feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVByte),
                utxosToSpend: utxosToSpend
            )
        }
    }

    /// Estimates the mining fee for a send-all (drain) transaction.
    func estimateSendAllFee(
        address: String,
        satsPerVByte: UInt32
    ) async throws -> UInt64 {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment().calculateSendAllFee(
                address: address,
                retainReserves: true,
                feeRate: Self.convertVByteToKwu(satsPerVByte: satsPerVByte)
            )
        }
    }

    func estimateRoutingFees(bolt11: String, amountSats: UInt64? = nil) async throws -> UInt64 {
        if let rail = channelFreeRail, await shouldPayWithRail(rail, bolt11: bolt11, sats: amountSats) {
            return try await rail.estimateRoutingFees(bolt11: bolt11, amountSats: amountSats)
        }
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            let invoice = try Bolt11Invoice.fromStr(invoiceStr: bolt11)
            let feesMsat: UInt64

            if let amountSats {
                let amountMsat = amountSats * 1000
                feesMsat = try node.bolt11Payment().estimateRoutingFeesUsingAmount(invoice: invoice, amountMsat: amountMsat)
            } else {
                feesMsat = try node.bolt11Payment().estimateRoutingFees(invoice: invoice)
            }

            return feesMsat / 1000
        }
    }

    // MARK: - Probing

    private static func scoringFeeParameters(config: Config) -> ScoringFeeParameters {
        let defaultParameters = config.scoringFeeParams ?? defaultScoringFeeParameters

        return ScoringFeeParameters(
            basePenaltyMsat: scoringBasePenaltyMsat,
            basePenaltyAmountMultiplierMsat: defaultParameters.basePenaltyAmountMultiplierMsat,
            liquidityPenaltyMultiplierMsat: scoringLiquidityPenaltyMultiplierMsat,
            liquidityPenaltyAmountMultiplierMsat: scoringLiquidityPenaltyAmountMultiplierMsat,
            historicalLiquidityPenaltyMultiplierMsat: defaultParameters.historicalLiquidityPenaltyMultiplierMsat,
            historicalLiquidityPenaltyAmountMultiplierMsat: scoringHistoricalLiquidityPenaltyAmountMultiplierMsat,
            antiProbingPenaltyMsat: defaultParameters.antiProbingPenaltyMsat,
            consideredImpossiblePenaltyMsat: scoringConsideredImpossiblePenaltyMsat,
            linearSuccessProbability: defaultParameters.linearSuccessProbability,
            probingDiversityPenaltyMsat: defaultParameters.probingDiversityPenaltyMsat
        )
    }

    /// Sends a probe to test if a payment route exists for the given invoice.
    /// - Parameters:
    ///   - bolt11: The Lightning invoice string (BOLT 11)
    ///   - amountSats: Optional amount in sats for variable-amount invoices
    func sendProbe(bolt11: String, amountSats: UInt64? = nil) async throws -> ProbeDispatch {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            let invoice = try Bolt11Invoice.fromStr(invoiceStr: bolt11)
            let handles: [ProbeHandle]
            if let amountSats {
                let amountMsat = amountSats * 1000
                handles = try node.bolt11Payment().sendProbesUsingAmount(invoice: invoice, amountMsat: amountMsat, routeParameters: nil)
            } else {
                handles = try node.bolt11Payment().sendProbes(invoice: invoice, routeParameters: nil)
            }

            return ProbeDispatch(paymentIds: Set(handles.map(\.paymentId)))
        }
    }

    /// Sends payment probes over all paths of a route that would be used to pay the given
    /// amount to the given nodeId.
    /// - Parameters:
    ///   - nodeId: The ID of the node to send the probe to
    ///   - amountSats: Amount in sats to send
    func sendProbesSpontaneous(nodeId: String, amountSats: UInt64) async throws -> ProbeDispatch {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        return try await ServiceQueue.background(.ldk) {
            let amountMsat = amountSats * 1000
            let handles = try node.spontaneousPayment().sendProbes(amountMsat: amountMsat, nodeId: nodeId)

            return ProbeDispatch(paymentIds: Set(handles.map(\.paymentId)))
        }
    }
}

/// The attempts recorded and the sends in flight on each rail when a listing was about to be read.
struct AttemptMark {
    let records: Int
    let railInFlight: Set<String>
    let ldkInFlight: Set<String>
}
