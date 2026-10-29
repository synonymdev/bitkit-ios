import BitkitCore
import Combine
import Foundation
import LDKNode

// TODO: catch all errors and pass a readable error message to the UI

/// A Lightning rail that needs no channels (Arkade). The main app sets it; the notification
/// extension leaves it unset, so only LDK runs there.
protocol ChannelFreeLightningRail: AnyObject {
    @MainActor var isReady: Bool { get }
    @MainActor var balanceSats: UInt64 { get }
    func receive(amountSats: UInt64?, description: String, expirySecs: UInt32) async throws -> String
    func send(bolt11: String, sats: UInt64?) async throws -> PaymentHash
    func estimateRoutingFees(bolt11: String, amountSats: UInt64?) async throws -> UInt64
    func lightningPayments() async -> [ChannelFreeRailPayment]
}

/// A Lightning payment the channel-free rail sent or received, for checks that would otherwise read only LDK's payments.
struct ChannelFreeRailPayment: Equatable {
    let paymentHash: String
    let direction: PaymentDirection
    let status: PaymentStatus
    let preimage: String?
}

class LightningService {
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

    private var storedEventCallback: ((Event) -> Void)?
    /// Rail events that arrived before the node's event callback was set, delivered once it is.
    private var pendingChannelFreeRailEvents: [Event] = []
    weak var channelFreeRail: ChannelFreeLightningRail?
    var onchainTransactionConfirmed: (@Sendable (String) async -> Void)?
    var onchainTransactionReceived: (@Sendable (String) async -> Void)?

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

        listenForEvents(onEvent: storedEventCallback)

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
            try node.stop()
        }
        self.node = nil

        if clearEventCallback {
            storedEventCallback = nil
            pendingChannelFreeRailEvents = []
        }

        await MainActor.run {
            channelCache.removeAll()
        }

        Logger.info("Node stopped")
    }

    func wipeStorage(walletIndex: Int) async throws {
        guard node == nil else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        let directory = Env.ldkStorage(walletIndex: walletIndex)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            Logger.warn("No directory found to wipe: \(directory.path)")
            return
        }

        Logger.warn("Wiping on lighting wallet...")
        try FileManager.default.removeItem(at: directory)

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

    func receive(amountSats: UInt64? = nil, description: String, expirySecs: UInt32 = 3600) async throws -> String {
        try await receiveMsats(amountMsats: amountSats.map { $0 * 1000 }, description: description, expirySecs: expirySecs)
    }

    func receiveMsats(amountMsats: UInt64? = nil, description: String, expirySecs: UInt32 = 3600) async throws -> String {
        if let rail = channelFreeRail, await shouldReceiveWithRail(rail, amountSats: amountMsats.map { $0 / 1000 }) {
            let amountSats = amountMsats.map { $0 / 1000 }.flatMap { $0 > 0 ? $0 : nil }
            return try await rail.receive(amountSats: amountSats, description: description, expirySecs: expirySecs)
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

    /// Receives on the channel-free rail when no ready channel has the inbound capacity for the amount.
    @MainActor
    private func shouldReceiveWithRail(_ rail: ChannelFreeLightningRail, amountSats: UInt64?) -> Bool {
        guard rail.isReady else { return false }
        let readyChannels = (channels ?? []).filter(\.isChannelReady)
        guard !readyChannels.isEmpty else { return true }
        let inboundSats = readyChannels.map(\.inboundCapacityMsat).reduce(0, +) / 1000
        guard let amountSats, amountSats > 0 else { return inboundSats == 0 }
        return amountSats > inboundSats
    }

    /// Pays on the channel-free rail when no channel has the outbound capacity and the rail's balance covers the amount.
    @MainActor
    private func shouldPayWithRail(_ rail: ChannelFreeLightningRail, bolt11: String, sats: UInt64?) -> Bool {
        guard rail.isReady else { return false }
        let invoiceSats = (try? Bolt11Invoice.fromStr(invoiceStr: bolt11).amountMilliSatoshis()).flatMap { $0 }.map { $0 / 1000 }
        guard let amountSats = sats ?? invoiceSats else { return false }
        return !canSendWithChannels(amountSats: amountSats) && rail.balanceSats >= amountSats
    }

    /// Checks if we have the correct outbound capacity to send the amount
    /// - Parameter amountSats: Amount to send in satoshis
    /// - Returns: True if we can send the amount
    /// Note: Uses cached channels for fast, non-blocking checks
    @MainActor
    func canSend(amountSats: UInt64) -> Bool {
        if let rail = channelFreeRail, rail.isReady, rail.balanceSats >= amountSats, !canSendWithChannels(amountSats: amountSats) {
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

    func send(
        bolt11: String,
        sats: UInt64? = nil,
        params: RouteParametersConfig? = nil,
        beforeSubmission: @escaping () throws -> Void = {}
    ) async throws -> PaymentHash {
        if let rail = channelFreeRail, await shouldPayWithRail(rail, bolt11: bolt11, sats: sats) {
            // Arkade takes no route parameters, so a caller's routing fee cap is checked against its estimate instead.
            if let maxFeeMsat = params?.maxTotalRoutingFeeMsat {
                let feeSats = try await rail.estimateRoutingFees(bolt11: bolt11, amountSats: sats)
                guard feeSats * 1000 <= maxFeeMsat else {
                    throw AppError(
                        message: "Arkade routing fee exceeds the limit",
                        debugMessage: "Fee \(feeSats) sats, limit \(maxFeeMsat / 1000) sats"
                    )
                }
            }
            try beforeSubmission()
            return try await rail.send(bolt11: bolt11, sats: sats)
        }
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }

        Logger.info("Paying bolt11: \(bolt11)")

        do {
            return try await Self.submitPayment(beforeSubmission: beforeSubmission) {
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
        storedEventCallback = onEvent
        let pending = pendingChannelFreeRailEvents
        pendingChannelFreeRailEvents = []
        pending.forEach(onEvent)
    }

    /// Arkade runs before the node starts, so its events wait until the node's event callback is set rather than being lost.
    func emitChannelFreeRailEvent(_ event: Event) {
        guard let storedEventCallback else {
            pendingChannelFreeRailEvents.append(event)
            return
        }
        storedEventCallback(event)
    }

    func channelFreeRailPayments() async -> [ChannelFreeRailPayment] {
        await channelFreeRail?.lightningPayments() ?? []
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

                onEvent?(event)

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
                            try await CoreService.shared.activity.handleOnchainTransactionReceived(txid: txid, details: details)
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
                            try await CoreService.shared.activity.handleOnchainTransactionConfirmed(
                                txid: txid,
                                details: details
                            )
                        } catch {
                            Logger.error("Failed to handle transaction confirmed for \(txid): \(error)", context: "LightningService")
                        }
                    }
                case let .onchainTransactionReplaced(txid, conflicts):
                    Logger.info("🔄 Onchain transaction replaced (RBF): txid=\(txid) by \(conflicts.count) conflict(s)")
                    Task {
                        do {
                            try await CoreService.shared.activity.handleOnchainTransactionReplaced(txid: txid, conflicts: conflicts)
                        } catch {
                            Logger.error("Failed to handle transaction replaced for \(txid): \(error)", context: "LightningService")
                        }
                    }
                case let .onchainTransactionReorged(txid):
                    Logger.warn("⚠️ Onchain transaction reorged (unconfirmed): txid=\(txid)")
                    Task {
                        do {
                            try await CoreService.shared.activity.handleOnchainTransactionReorged(txid: txid)
                        } catch {
                            Logger.error("Failed to handle transaction reorged for \(txid): \(error)", context: "LightningService")
                        }
                    }
                case let .onchainTransactionEvicted(txid):
                    Logger.warn("🗑️ Onchain transaction removed from mempool: txid=\(txid)")
                    Task {
                        do {
                            try await CoreService.shared.activity.handleOnchainTransactionEvicted(txid: txid)
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
