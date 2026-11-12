import BigNumber
import BitkitCore
import BreezSdkSpark
import Combine
import Foundation
import LDKNode
import Observation

/// Lightning without channels, through the Breez SDK on Spark. Savings to Spending funds this wallet,
/// receives fall back to it when no channel has the inbound capacity, and sends fall back to it when no
/// channel has the outbound capacity. Its keys derive from the Bitkit seed on Spark's own path (`m/8797555'`).
/// Its payments reach the app as LDK events through `LightningService.emitChannelFreeRailEvent`, so the
/// receive and send flows built on node events work for both rails.
@Observable @MainActor
final class SparkManager: ChannelFreeLightningRail {
    static let shared = SparkManager()
    nonisolated static let routeService = "spark"
    private nonisolated static let routeAtomicity = "trusted"
    private nonisolated(unsafe) static let exitStateChanged = PassthroughSubject<Void, Never>()
    private nonisolated static let exitStateLock = NSLock()
    private nonisolated(unsafe) static var exitStateGenerationValue = 0

    /// Bumped on every connect and exit data change, kept outside the backup observers, which stop while the node does,
    /// so a change they missed is still backed up once they start again.
    nonisolated static var exitStateGeneration: Int {
        exitStateLock.withLock { exitStateGenerationValue }
    }

    nonisolated static func notifyExitStateChanged() {
        exitStateLock.withLock { exitStateGenerationValue += 1 }
        exitStateChanged.send()
    }

    private nonisolated(unsafe) static let contactWithdrawalResolutionSubject = PassthroughSubject<SparkContactWithdrawalResolution, Never>()
    /// How each contact withdrawal's journal closes, which a pending send screen waits on.
    static var contactWithdrawalResolutionPublisher: AnyPublisher<SparkContactWithdrawalResolution, Never> {
        contactWithdrawalResolutionSubject.eraseToAnyPublisher()
    }

    /// The latest journal close in this process, for a pending screen that opens after it; a new journal clears it.
    private(set) static var lastContactWithdrawalResolution: SparkContactWithdrawalResolution?

    /// Fires once Spark connects and whenever its unilateral exit data changes, so the exit data backup is redone.
    nonisolated static var exitStateChangedPublisher: AnyPublisher<Void, Never> {
        exitStateChanged.eraseToAnyPublisher()
    }

    private nonisolated static let depositClaimFeeLeewaySatPerVbyte: UInt64 = 2
    private nonisolated static let depositClaimFeePpm: UInt32 = 2000

    private(set) var isReady = false
    /// The last start failed; the next start clears it when it begins.
    private(set) var hasStartFailed = false
    private(set) var walletIndex = 0
    /// What Spark read, which sends and withdrawals use.
    private(set) var balanceSats: UInt64 = 0
    /// The last balance shown, kept while Spark reads 0 after a failed withdrawal or a failed sync; display only.
    private(set) var keptBalanceSats: UInt64?
    /// The kept balance when an exit started, shown again should the exit be cancelled.
    @ObservationIgnored private var keptBeforeExit: UInt64?
    /// The balance Home and the Spark connection show.
    var shownBalanceSats: UInt64 {
        keptBalanceSats ?? balanceSats
    }

    /// The balance Spending and its connections show: 0 during an emergency exit, whose amount shows in transfer to
    /// savings instead.
    var shownSpendingSats: UInt64 {
        Self.shownSpendingSats(isExiting: isExiting, shownBalanceSats: shownBalanceSats)
    }

    nonisolated static func shownSpendingSats(isExiting: Bool, shownBalanceSats: UInt64) -> UInt64 {
        isExiting ? 0 : shownBalanceSats
    }

    /// Deposits seen on-chain that Spark claims into `balanceSats` after 3 confirmations.
    private(set) var pendingDepositSats: UInt64 = 0
    /// Funds an emergency exit can still recover, as Spark reports them.
    private(set) var recoverableFundsSats: UInt64 = 0
    /// On-chain deposits into Spark, pending ones first, for the Lightning Connections screens.
    private(set) var deposits: [SparkDeposit] = []
    private(set) var withdrawals: [SparkWithdrawal] = []
    /// Called after the Spark balance or readiness was read again, so balances and the receive invoice can follow.
    var onStateChanged: (() -> Void)?

    /// Deposits this app broadcast that Spark hasn't listed yet, by txid, so they show as pending at once.
    @ObservationIgnored private var broadcastDeposits: [String: UInt64] = [:]
    /// Sends recorded before Spark knew their fee; its completion event reports 0 until a later sync.
    @ObservationIgnored private var sendsRecordedWithoutFee: Set<String> = []
    /// Payments whose activity failed to save, written again at the next refresh.
    @ObservationIgnored private var unsavedPayments: Set<String> = []
    @ObservationIgnored private var sdk: BreezSdk?
    /// Whether a wallet sync ended since this run connected, so the SDK's sync error describes this run.
    @ObservationIgnored private var syncedThisRun = false
    /// The last withdrawal quote, which the withdrawal reuses while it holds.
    @ObservationIgnored private var preparedWithdrawal: (quote: SparkWithdrawalQuote, response: PrepareSendPaymentResponse)?
    /// Withdrawals this app sent, known before Spark lists them.
    @ObservationIgnored private var sentWithdrawalTxIds: Set<String> = []
    /// When a withdrawal last failed, in seconds since 1970, until Spark reads a balance again or syncs after it
    /// (`keptBalanceSats`).
    @ObservationIgnored private var withdrawalFailedAt: UInt64?
    /// When a withdrawal moved the whole balance, in seconds since 1970, so a read of 0 is real until a sync after it
    /// reads a balance again (`withdrewAllAt(_:read:lastSyncedAt:)`).
    @ObservationIgnored private var withdrewAllAt: UInt64?
    @ObservationIgnored private var listenerId: String?
    @ObservationIgnored private var connectTask: Task<Void, Error>?
    /// A leaf optimization is running, as its events tell.
    @ObservationIgnored private var isOptimizing = false
    /// Sends and withdrawals past their exit check, which an exit starting waits for.
    let spends = SparkSpends { SparkExitManager.shared.isExiting }
    /// Waiting before an exit quote for value an interrupted leaf optimization still owes the wallet.
    private(set) var isSettlingForExit = false
    /// When a leaf optimization last moved without completing, so a counter-swap it left may still be unclaimed.
    private nonisolated static let optimizationActivityKey = "sparkOptimizationActivityAt"
    /// The SDK claims a counter-swap left by an interrupted optimization only after this long
    /// (spark-wallet `COUNTER_SWAP_CLAIM_GRACE_PERIOD_SECS`), plus a margin for the round that created it.
    static let counterSwapClaimGraceSeconds: TimeInterval = 300 + 30
    /// The longest an exit waits for a running optimization before going ahead.
    private static let optimizationWaitSeconds: TimeInterval = 120
    /// Bumped by `wipe`, so a connect that started before it disconnects instead of keeping the wiped wallet.
    @ObservationIgnored private var connectGeneration = 0
    /// Set for the whole wipe: no connect, start or exit reconnect is admitted, so nothing brings the wiped wallet's
    /// Spark identity back while its mnemonic still exists.
    @ObservationIgnored private var isWiping = false
    /// The refresh in flight; callers during it wait for it, and it reads once more for them.
    @ObservationIgnored private var refreshTask: Task<Void, Error>?
    @ObservationIgnored private var refreshAgain = false
    /// A contact withdrawal is being sent, so its journal entry isn't settled from a list that can't show it yet.
    @ObservationIgnored private var isWithdrawingToContact = false
    /// Set once a full activity sync succeeded in this process; `wipe` clears it.
    @ObservationIgnored private var activitiesSynced = false

    private init() {}

    var isSupported: Bool {
        Self.sparkNetwork != nil
    }

    /// Whether savings or a hardware wallet can fund Spark: its deposit goes out on Bitkit's chain, which Spark must read.
    var canFundFromChain: Bool {
        isReady && Self.readsBitkitChain(network: Env.network, chainServiceUrl: Env.sparkChainServiceUrl(for: Env.network))
    }

    /// On mainnet both read Bitcoin; Spark's default regtest is its own chain, so a regtest deposit reaches Spark only
    /// when Spark reads Bitkit's chain through `chainServiceUrl`.
    nonisolated static func readsBitkitChain(network: LDKNode.Network, chainServiceUrl: String?) -> Bool {
        network == .bitcoin || chainServiceUrl != nil
    }

    var isConnected: Bool {
        sdk != nil
    }

    /// An emergency exit is moving the Spark balance on-chain: Spark then neither sends nor receives, and its
    /// balance counts as in transfer to savings.
    var isExiting: Bool {
        SparkExitManager.shared.isExiting
    }

    /// Takes Spark off the Lightning rail for an emergency exit, so no payment moves leaves the exit is spending.
    func detachForExit() {
        if LightningService.shared.channelFreeRail === self {
            LightningService.shared.channelFreeRail = nil
        }
    }

    /// Saves the kept balance as an exit starts, before a refresh reads Spark as exiting and drops it: a cancelled
    /// exit shows it again.
    func holdKeptBalanceForExit() {
        keptBeforeExit = keptBalanceSats ?? keptBeforeExit
        keptBalanceSats = nil
    }

    /// Connects Spark again so its leaf optimization follows whether an exit runs: off when one starts, back on
    /// once it ends. An exit cancelled before it paid anything (`isCancel`) shows the kept balance again.
    func reconnectForExit(isCancel: Bool = false) async {
        guard let network = Self.sparkNetwork, !isWiping else { return }
        if isExiting {
            holdKeptBalanceForExit()
        } else {
            keptBalanceSats = Self.keptBalanceSats(afterExitKept: keptBeforeExit, read: balanceSats, isCancel: isCancel)
                ?? keptBalanceSats
            keptBeforeExit = nil
        }
        // A connect still running, such as the launch's, builds an SDK on the same storage: it ends first and is
        // disconnected below, so no second SDK keeps running.
        if let connecting = connectTask {
            _ = try? await connecting.value
        }
        noteOptimizationCutShort()
        if let sdk {
            if let listenerId {
                _ = await sdk.removeEventListener(id: listenerId)
            }
            try? await sdk.disconnect()
        }
        sdk = nil
        listenerId = nil
        do {
            let generation = connectGeneration
            let walletIndex = walletIndex
            let connecting = Task { try await connect(walletIndex: walletIndex, network: network, generation: generation) }
            connectTask = connecting
            defer {
                if connectTask == connecting {
                    connectTask = nil
                }
            }
            try await connecting.value
            try await refresh()
        } catch {
            Logger.error("Failed to reconnect Spark for the exit: \(error)", context: "SparkManager")
        }
    }

    /// Connects the Spark SDK alone for a background exit run, never the node: no refresh, no activity sync and no
    /// Lightning rail. Returns nil when it does not connect within `timeout`; the connect keeps going, and a later
    /// `start` picks it up.
    /// `operation`'s result, or nil once `timeout` passes first. Returns at the timeout without waiting for `operation`,
    /// which a task group would do; the operation carries on, unstructured, and its late result is dropped.
    nonisolated static func firstOf<T: Sendable>(timeout: TimeInterval, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let resumed = SparkFirstResume()
            Task {
                let value = await operation()
                if resumed.claim() {
                    continuation.resume(returning: value)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if resumed.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func connectForExit(walletIndex: Int, timeout: TimeInterval) async -> SparkExitRecovering? {
        guard let network = Self.sparkNetwork else { return nil }
        if sdk == nil {
            self.walletIndex = walletIndex
            if connectTask == nil {
                let generation = connectGeneration
                connectTask = Task { try await connect(walletIndex: walletIndex, network: network, generation: generation) }
            }
            let connecting = connectTask
            // nil while still connecting at the timeout; the connect itself keeps running for `start`.
            let didConnect: Bool? = await Self.firstOf(timeout: timeout) { await (try? connecting?.value) != nil }
            // A finished connect is forgotten, so a failed one is tried again; one still running is kept for `start`.
            if didConnect != nil {
                connectTask = nil
            }
            guard didConnect == true else {
                Logger.warn("Spark did not connect within \(Int(timeout))s for the exit", context: "SparkManager")
                return nil
            }
        }
        return exitRecovering
    }

    /// Waits until no leaf optimization runs and no counter-swap one left behind is still inside the SDK's claim
    /// grace, then syncs, which claims it. An optimization swaps leaves with the operators; one cut short (by a
    /// disconnect or the app closing) leaves its counter-swap unclaimed for 5 minutes, and a quote taken meanwhile
    /// would leave that value out of the exit.
    func settleForExit() async {
        isSettlingForExit = true
        defer { isSettlingForExit = false }
        await waitForOptimization()
        let activity = UserDefaults.standard.object(forKey: Self.optimizationActivityKey) as? TimeInterval
        if let activity {
            let wait = Self.counterSwapClaimGraceSeconds - Date().timeIntervalSince1970 + activity
            if wait > 0 {
                Logger.info("Waiting \(Int(wait))s for an interrupted Spark optimization before the exit quote", context: "SparkManager")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        guard !Task.isCancelled, let sdk else { return }
        do {
            _ = try await sdk.syncWallet(request: SyncWalletRequest())
            if activity != nil, !isOptimizing {
                UserDefaults.standard.removeObject(forKey: Self.optimizationActivityKey)
            }
        } catch {
            Logger.warn("Failed to sync Spark before the exit quote: \(error)", context: "SparkManager")
        }
        await refreshState()
    }

    /// Waits for a running leaf optimization to finish, for up to two minutes.
    func waitForOptimization() async {
        let deadline = Date().addingTimeInterval(Self.optimizationWaitSeconds)
        while isOptimizing, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Waits for the sends and withdrawals that passed their exit check before the exit held Spark, for up to two
    /// minutes, so the exit quotes the leaves they leave.
    func holdSpendsForExit() async throws {
        try await spends.holdForExit(timeout: Self.optimizationWaitSeconds)
    }

    func releaseSpendsHold() {
        spends.release()
    }

    private func noteOptimization(_ event: AutoOptimizationEvent) {
        switch event {
        case .started, .roundCompleted:
            isOptimizing = true
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.optimizationActivityKey)
        case .cancelled, .failed:
            isOptimizing = false
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.optimizationActivityKey)
        case .completed, .skipped:
            isOptimizing = false
            UserDefaults.standard.removeObject(forKey: Self.optimizationActivityKey)
        }
    }

    private func noteOptimizationCutShort() {
        guard isOptimizing else { return }
        isOptimizing = false
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.optimizationActivityKey)
    }

    /// The SDK calls of an emergency exit, or nil while Spark is not connected.
    var exitRecovering: SparkExitRecovering? {
        sdk.map(BreezSparkExitRecovering.init)
    }

    /// The fee rate an exit is built at: the fastest the SDK's chain service recommends, at least 1 sat/vB.
    func exitFeeRate() async throws -> UInt64 {
        try await max(1, requireSdk().recommendedFees().fastestFee)
    }

    /// The SDK's recommended rates for an exit's fee bump.
    func exitNetworkFees() async throws -> SparkExitNetworkFees {
        let fees = try await requireSdk().recommendedFees()
        return SparkExitNetworkFees(fastest: max(1, fees.fastestFee), halfHour: max(1, fees.halfHourFee))
    }

    nonisolated static var exitNetwork: BreezSdkSpark.Network? {
        switch Env.network {
        case .bitcoin: .mainnet
        case .regtest: .regtest
        default: nil
        }
    }

    /// The exit data's generation while connected, nil while disconnected, so a backup can tell a change from observing
    /// that restarted while Spark stayed connected.
    var exitStateVersion: Int? {
        sdk == nil ? nil : Self.exitStateGeneration
    }

    /// On regtest, an invoice that carries a Spark address is paid as a Spark transfer. Bitkit's own invoices carry none,
    /// so two dev builds pay each other over Lightning through Spark's provider, as on mainnet.
    nonisolated static var prefersSpark: Bool {
        Env.network == .regtest
    }

    /// Returns as soon as the payment starts, like LDK, so its completion reaches callers as an event they are already
    /// watching for; waiting for completion here fired that event before they watched.
    nonisolated static var bolt11SendOptions: SendPaymentOptions {
        .bolt11Invoice(preferSpark: prefersSpark, completionTimeoutSecs: nil)
    }

    private static var sparkNetwork: BreezSdkSpark.Network? {
        switch Env.network {
        case .bitcoin: Env.breezApiKey == nil ? nil : .mainnet
        case .regtest: .regtest
        default: nil
        }
    }

    func start(walletIndex: Int) async {
        guard let network = Self.sparkNetwork, !isWiping else { return }
        // A retry reads as connecting until it fails again.
        hasStartFailed = false
        self.walletIndex = walletIndex
        SparkExitManager.shared.load(walletIndex: walletIndex)
        do {
            if sdk == nil {
                if connectTask == nil {
                    let generation = connectGeneration
                    connectTask = Task { try await connect(walletIndex: walletIndex, network: network, generation: generation) }
                }
                let task = connectTask
                // A reconnect may have replaced the task while this one was awaited: only the task it awaited is cleared.
                defer {
                    if connectTask == task {
                        connectTask = nil
                    }
                }
                try await task?.value
            }
            // Registered before the first refresh marks Spark ready, so Lightning calls never see it ready while they
            // still go to LDK, even when that refresh or the activity sync fails. An emergency exit keeps it out.
            LightningService.shared.channelFreePaymentHistory = self
            if !isExiting {
                LightningService.shared.channelFreeRail = self
            }
            activitiesSynced = try await Self.startConnected(
                activitiesSynced: activitiesSynced,
                refresh: { try await refresh() },
                syncWallet: {
                    _ = try await requireSdk().syncWallet(request: SyncWalletRequest())
                    syncedThisRun = true
                },
                syncActivities: { try await syncActivities() }
            )
            await settleContactWithdrawal(allowClear: false)
        } catch {
            hasStartFailed = true
            Logger.error("Failed to start Spark wallet: \(error)", context: "SparkManager")
        }
    }

    /// A start reads the balance every time, but rewrites every Spark activity only until that has succeeded once, so
    /// each foreground doesn't redo it; a start whose refresh failed leaves the sync to the next one. Returns whether
    /// the activities are synced.
    /// Spark lists a send that was still in flight when the app was killed only once its own sync reaches it, so the
    /// first activity sync waits for one.
    static func startConnected(
        activitiesSynced: Bool,
        refresh: () async throws -> Void,
        syncWallet: () async throws -> Void = {},
        syncActivities: () async throws -> Void
    ) async throws -> Bool {
        try await refresh()
        guard !activitiesSynced else { return true }
        do {
            try await syncWallet()
        } catch {
            Logger.warn("Failed to sync Spark before recording its activities: \(error)", context: "SparkManager")
        }
        try await syncActivities()
        return true
    }

    private func connect(walletIndex: Int, network: BreezSdkSpark.Network, generation: Int) async throws {
        guard !isWiping else { throw CancellationError() }
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        let config = Self.sdkConfig(network: network, apiKey: Env.breezApiKey, isExiting: isExiting)
        let storageDir = Env.sparkStorage(walletIndex: walletIndex)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        // What `BreezSdkSpark.connect` builds, plus our own chain service where Env names one.
        let builder = SdkBuilder(config: config, seed: .mnemonic(mnemonic: mnemonic, passphrase: passphrase))
        await builder.withDefaultStorage(storageDir: storageDir.path)
        if let chainServiceUrl = Env.sparkChainServiceUrl(for: Env.network) {
            await builder.withRestChainService(url: chainServiceUrl, apiType: .esplora, credentials: nil)
        }
        syncedThisRun = false
        let connected = try await builder.build()
        guard generation == connectGeneration, !isWiping else {
            try? await connected.disconnect()
            throw CancellationError()
        }
        listenerId = await connected.addEventListener(listener: SparkEventListener { [weak self] event in
            await self?.onSdkEvent(event)
        })
        sdk = connected
        Logger.info("Connected Spark wallet on '\(network)'", context: "SparkManager")
        await importRestoredExitState(walletIndex: walletIndex)
        Self.notifyExitStateChanged()
    }

    /// The SDK config Bitkit connects with.
    nonisolated static func sdkConfig(network: BreezSdkSpark.Network, apiKey: String?, isExiting: Bool) -> BreezSdkSpark.Config {
        var config = defaultConfig(network: network)
        config.apiKey = apiKey
        // No Breez data sync server, no Lightning address server and no third-party input lookups: Bitkit uses none.
        config.realTimeSyncServerUrl = nil
        config.lnurlDomain = nil
        config.useDefaultExternalInputParsers = false
        // Lowering it below the spread keeps the deposit from being claimed early, and does not hold back its claim at
        // maturity. An early claim is made only when the user chose Instant (`claimEarly`).
        config.maxDepositClaimFee = MaxFee(
            onchain: .networkRecommended(leewaySatPerVbyte: depositClaimFeeLeewaySatPerVbyte),
            proportionalPpm: nil
        )
        // Optimizing swaps leaves with the operators, which would hand the leaves an exit is spending to someone
        // else, whose refunds then confirm first. Off for as long as an emergency exit runs.
        config.leafOptimizationConfig.autoEnabled = !isExiting
        return config
    }

    /// Disconnects and deletes this wallet's Spark data. A connect still running is waited for first, so it can't
    /// keep the wiped wallet; throws when the data could not be deleted, so the wipe is retried.
    func wipe(walletIndex: Int) async throws {
        defer { isWiping = false }
        var disconnectError: Error?
        try await Self.wipeInOrder(
            closeAdmission: {
                isWiping = true
                connectGeneration += 1
                syncedThisRun = false
            },
            drainExitWork: { await SparkExitManager.shared.wipe() },
            disconnect: { disconnectError = await disconnectForWipe() },
            deleteData: { try deleteWipedData(walletIndex: walletIndex) }
        )
        if let disconnectError {
            throw disconnectError
        }
    }

    /// The wipe's steps, in the order that keeps the wiped wallet's identity from coming back.
    static func wipeInOrder(
        closeAdmission: () -> Void,
        drainExitWork: () async -> Void,
        disconnect: () async -> Void,
        deleteData: () throws -> Void
    ) async throws {
        closeAdmission()
        // An exit tick finishing now may reconnect; with admission closed it can't, and it is done before the SDK goes.
        await drainExitWork()
        await disconnect()
        try deleteData()
    }

    private func disconnectForWipe() async -> Error? {
        if let connectTask {
            _ = try? await connectTask.value
        }
        connectTask = nil
        UserDefaults.standard.removeObject(forKey: Self.optimizationActivityKey)
        isOptimizing = false
        if LightningService.shared.channelFreeRail === self {
            LightningService.shared.channelFreeRail = nil
        }
        if LightningService.shared.channelFreePaymentHistory === self {
            LightningService.shared.channelFreePaymentHistory = nil
        }
        LightningService.shared.forgetRailAttempts()
        var disconnectError: Error?
        if let sdk {
            if let listenerId {
                _ = await sdk.removeEventListener(id: listenerId)
            }
            do {
                try await sdk.disconnect()
            } catch {
                Logger.error("Failed to disconnect Spark before wipe: \(error)", context: "SparkManager")
                disconnectError = error
            }
        }
        sdk = nil
        listenerId = nil
        refreshAgain = false
        activitiesSynced = false
        isReady = false
        hasStartFailed = false
        return disconnectError
    }

    private func deleteWipedData(walletIndex: Int) throws {
        balanceSats = 0
        keptBalanceSats = nil
        keptBeforeExit = nil
        withdrawalFailedAt = nil
        withdrewAllAt = nil
        pendingDepositSats = 0
        recoverableFundsSats = 0
        deposits = []
        withdrawals = []
        broadcastDeposits = [:]
        sendsRecordedWithoutFee = []
        unsavedPayments = []
        sentWithdrawalTxIds = []
        preparedWithdrawal = nil
        Self.pendingContactWithdrawal = nil
        Self.contactWithdrawalTxIds = []
        onStateChanged?()
        try Self.removeIfPresent(Env.sparkStorage(walletIndex: walletIndex))
        try Self.removeIfPresent(Env.sparkExitRestore(walletIndex: walletIndex))
        // The exit's own wipe only logs a failed delete: here it throws, so the wipe is retried, and covers the wiped
        // wallet's index even when the exit manager holds another one.
        try SparkExitStore(walletIndex: walletIndex).deleteWithCopies()
        try Self.removeIfPresent(Env.sparkExitLostLeaves(walletIndex: walletIndex))
        try Self.removeIfPresent(Env.sparkExitEarlierAddresses(walletIndex: walletIndex))
    }

    nonisolated static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: ChannelFreeLightningRail

    nonisolated func receive(amountSats: UInt64?, description: String, expirySecs: UInt32) async throws -> String {
        let method = ReceivePaymentMethod.bolt11Invoice(
            description: description,
            amountSats: amountSats,
            expirySecs: expirySecs,
            paymentHash: nil,
            receiverIdentityPublicKey: nil,
            preimage: nil
        )
        return try await requireSdk().receivePayment(request: ReceivePaymentRequest(paymentMethod: method)).paymentRequest
    }

    /// Errors before `sendPayment` are `ChannelFreeRailSendRefused`, since nothing left the wallet; a failure inside it
    /// stays uncertain, as the payment may have been dispatched, unless it is one raised before dispatch
    /// (`sendPaymentFailure`).
    nonisolated func send(
        bolt11: String,
        sats: UInt64?,
        maxFeeSats: UInt64?,
        beforeSubmission: @escaping () throws -> Void
    ) async throws -> PaymentHash {
        let prepared: PrepareSendPaymentResponse
        let sdk: BreezSdk
        do {
            sdk = try await requireSdk()
            prepared = try await prepareSend(paymentRequest: bolt11, amountSats: sats)
        } catch {
            Logger.warn("Spark could not prepare the payment: \(error)", context: "SparkManager")
            throw Self.expiredInvoiceRefusal(error) ?? ChannelFreeRailSendRefused(
                reason: SparkErrorCopy.message(for: error, fallback: t("wallet__payment_failed_description")),
                underlying: error
            )
        }
        guard case let .bolt11Invoice(invoiceDetails, sparkTransferFeeSats, lightningFeeSats) = prepared.paymentMethod else {
            Logger.error("Unexpected Spark payment method: \(prepared.paymentMethod)", context: "SparkManager")
            throw ChannelFreeRailSendRefused(reason: t("wallet__payment_failed_description"))
        }
        let feeSats = Self.prefersSpark ? sparkTransferFeeSats ?? lightningFeeSats : lightningFeeSats
        let amountSats = sats ?? invoiceDetails.amountMsat.map { $0 / 1000 } ?? 0
        let balanceSats = await balanceSats
        guard Self.fitsBalance(amountSats: amountSats, feeSats: feeSats, balanceSats: balanceSats) else {
            Logger.info("Spark balance can't cover \(amountSats) sats plus its quoted fee of \(feeSats) sats", context: "SparkManager")
            throw ChannelFreeRailSendRefused(reason: t("other__pay_insufficient_spending_description"))
        }
        // The fee limit is checked on the quote that is sent, not only on the earlier estimate.
        try Self.checkSendFee(feeSats, maxFeeSats: maxFeeSats)
        // An exit that started while the quote was prepared refuses it here, before its hash is recorded.
        let response: SendPaymentResponse = try await spends.run {
            // A deadline that passed while the quote was prepared stops the payment here, before anything leaves.
            try beforeSubmission()
            do {
                return try await sdk.sendPayment(request: SendPaymentRequest(
                    prepareResponse: prepared,
                    options: Self.bolt11SendOptions
                ))
            } catch {
                throw Self.sendPaymentFailure(error)
            }
        }
        Logger.info("Sent Spark payment '\(response.payment.id)' with status '\(response.payment.status)'", context: "SparkManager")
        return invoiceDetails.paymentHash
    }

    nonisolated static func checkSendFee(_ feeSats: UInt64, maxFeeSats: UInt64?) throws {
        guard let maxFeeSats, feeSats > maxFeeSats else { return }
        Logger.info("Spark fee of \(feeSats) sats exceeds the limit of \(maxFeeSats) sats", context: "SparkManager")
        throw ChannelFreeRailSendRefused(reason: t("wallet__max_possible_fee_rate"))
    }

    /// Whether the balance covers the amount and the fee `prepareSendPayment` quoted, the real sendable check behind
    /// the estimate in `ChannelFreeRailFees`.
    nonisolated static func fitsBalance(amountSats: UInt64, feeSats: UInt64, balanceSats: UInt64) -> Bool {
        let (total, overflow) = amountSats.addingReportingOverflow(feeSats)
        return !overflow && total <= balanceSats
    }

    /// What a failure inside `sendPayment` means for the caller.
    nonisolated static func sendPaymentFailure(_ error: Error) -> Error {
        // The SDK checks the expiry again before sending, so an invoice that expired on the confirm screen left nothing.
        if let refusal = expiredInvoiceRefusal(error) {
            return refusal
        }
        // Spark selects the leaves to spend before anything goes to the operators, so a balance short of the payment
        // left nothing, for instance when an earlier send spent it after the cached balance was read.
        if case SdkError.InsufficientFunds = error {
            return ChannelFreeRailSendRefused(reason: t("other__pay_insufficient_spending_description"), underlying: error)
        }
        return error
    }

    /// The SDK refuses an expired Lightning invoice before anything leaves the wallet, with the scanner's expiry copy.
    nonisolated static func expiredInvoiceRefusal(_ error: Error) -> ChannelFreeRailSendRefused? {
        guard case let SdkError.InvalidInput(message) = error, message.localizedCaseInsensitiveContains("invoice has expired") else { return nil }
        return ChannelFreeRailSendRefused(reason: t("other__scan__error__expired"))
    }

    nonisolated func hasSynced(after seconds: UInt64?) async -> Bool {
        guard let info = try? await requireSdk().getInfo(request: GetInfoRequest(ensureSynced: false)) else { return false }
        return await Self.hasSynced(
            after: seconds,
            syncedThisRun: syncedThisRun,
            lastSyncFailed: info.lastSyncError != nil,
            lastSyncedAt: info.lastSyncedAt
        )
    }

    /// The SDK keeps `lastSyncedAt` across launches but not `lastSyncError`, which is unset after each connect until that
    /// run's first sync ends, so only a sync this run, after a wallet sync that ever succeeded, shows Spark's list is complete.
    nonisolated static func hasSynced(after seconds: UInt64?, syncedThisRun: Bool, lastSyncFailed: Bool, lastSyncedAt: UInt64?) -> Bool {
        // The SDK sets `lastSyncedAt` only on a wallet sync that succeeded, while it reports Synced for partial ones too.
        guard syncedThisRun, !lastSyncFailed, let lastSyncedAt else { return false }
        guard let seconds else { return true }
        return lastSyncedAt > seconds
    }

    nonisolated func lightningPayments() async throws -> [ChannelFreeRailPayment] {
        let payments = try await requireSdk().listPayments(request: ListPaymentsRequest(sortAscending: false)).payments
        return payments.compactMap { payment in
            guard case let .lightning(_, _, _, htlcDetails, _, _, _, _) = payment.details else { return nil }
            return ChannelFreeRailPayment(
                paymentHash: htlcDetails.paymentHash,
                direction: payment.paymentType == .send ? .outbound : .inbound,
                status: Self.ldkStatus(payment.status),
                preimage: htlcDetails.preimage,
                timestamp: payment.timestamp,
                feeSats: Self.sats(payment.fees)
            )
        }
    }

    nonisolated func estimateRoutingFees(bolt11: String, amountSats: UInt64?) async throws -> UInt64 {
        let prepared = try await prepareSend(paymentRequest: bolt11, amountSats: amountSats)
        guard case let .bolt11Invoice(_, sparkTransferFeeSats, lightningFeeSats) = prepared.paymentMethod else { return 0 }
        if Self.prefersSpark, let sparkTransferFeeSats {
            return sparkTransferFeeSats
        }
        return lightningFeeSats
    }

    // MARK: Transfers

    /// The static on-chain address that funds the Spark wallet, claimed automatically once confirmed.
    func depositAddress() async throws -> String {
        let request = ReceivePaymentRequest(paymentMethod: .bitcoinAddress(newAddress: nil))
        return try await requireSdk().receivePayment(request: request).paymentRequest
    }

    /// Size of Spark's deposit claim transaction; the SDK prices a standard claim as the fastest recommended fee rate
    /// times this size before the provider quotes it (breez/spark-sdk `CLAIM_TX_SIZE_VBYTES`).
    private nonisolated static let claimTxSizeVbytes: UInt64 = 99

    /// What claiming a deposit of `amountSats` costs for each speed. The provider quotes the real fee only once the
    /// deposit exists, so Instant is the ceiling the user accepts and Later the mature claim at the half-hour rate.
    func depositClaimFees(amountSats: UInt64) async throws -> SparkClaimFees {
        let fees = try await requireSdk().recommendedFees()
        return SparkClaimFees(
            instantMaxSats: Self.maxDepositClaimFeeSats(fastestFeeRate: fees.fastestFee, amountSats: amountSats),
            laterSats: Self.matureDepositClaimFeeSats(halfHourFeeRate: fees.halfHourFee)
        )
    }

    nonisolated static func matureDepositClaimFeeSats(halfHourFeeRate: UInt64) -> UInt64 {
        halfHourFeeRate * claimTxSizeVbytes
    }

    nonisolated static func maxDepositClaimFeeSats(fastestFeeRate: UInt64, amountSats: UInt64) -> UInt64 {
        let onchain = (fastestFeeRate + depositClaimFeeLeewaySatPerVbyte) * claimTxSizeVbytes
        let proportional = amountSats.multipliedReportingOverflow(by: UInt64(depositClaimFeePpm)).partialValue / 1_000_000
        return onchain + proportional
    }

    /// How the deposit in `txid` can be claimed, or nil while Spark has not seen it yet. The early quote asks the
    /// provider on every call, so this is called once a deposit is listed, not on a timer.
    func depositClaimOffer(txid: String) async throws -> SparkClaimOffer? {
        let sdk = try await requireSdk()
        let unclaimed = try await sdk.listUnclaimedDeposits(request: ListUnclaimedDepositsRequest()).deposits
        guard let deposit = unclaimed.first(where: { $0.txid.caseInsensitiveCompare(txid) == .orderedSame }) else { return nil }
        let quote = try await sdk.fetchClaimDepositQuote(request: FetchClaimDepositQuoteRequest(txid: deposit.txid, vout: deposit.vout))
        return SparkClaimOffer(txid: deposit.txid, vout: deposit.vout, quote: quote)
    }

    /// Clears the fee cap an early claim of `offer` left on its deposit, back to the configured one, which never claims
    /// early (`sdkConfig`): a claim that names no cap clears the stored one before it is attempted. False when the cap
    /// may still be there: the call failed, or another claim of the deposit held it, which leaves the cap unchanged.
    func releaseEarlyClaim(_ offer: SparkClaimOffer) async -> Bool {
        do {
            _ = try await requireSdk().claimDeposit(request: ClaimDepositRequest(txid: offer.txid, vout: offer.vout, maxFee: nil))
            return true
        } catch {
            Logger.warn("Failed to clear the early claim cap of Spark deposit \(offer.txid): \(error)", context: "SparkManager")
            return false
        }
    }

    /// Accepts the early claim of `offer` at its quoted fee. The fee ceiling stays on the deposit, so an early claim
    /// not offered at this depth is still made once the provider offers it.
    func claimEarly(_ offer: SparkClaimOffer) async throws -> SparkEarlyClaim {
        guard case let .choice(earlyFeeSats, _, _, _) = offer.kind else { return .claimed }
        let request = ClaimDepositRequest(
            txid: offer.txid,
            vout: offer.vout,
            maxFee: MaxFee(onchain: .fixed(amount: earlyFeeSats), proportionalPpm: nil)
        )
        let claim: SparkEarlyClaim
        do {
            let outcome = try await requireSdk().claimDeposit(request: request).outcome
            claim = SparkEarlyClaim(outcome)
        } catch SdkError.DepositClaimInProgress {
            claim = .submitted
        }
        Logger.info("Early claim of Spark deposit \(offer.txid): \(claim)", context: "SparkManager")
        await refreshState()
        return claim
    }

    /// Moves the whole Spark balance to the on-chain `address`, fees included, for Spending to Savings. Refuses before
    /// sending when the fee is above `maxFeeSats`, the fee the confirm screen showed.
    func withdrawAll(to address: String, maxFeeSats: UInt64) async throws {
        do {
            let prepared = try await prepareWithdrawAll(to: address)
            try Self.checkWithdrawalFee(Self.withdrawalFeeSats(prepared), shownFeeSats: maxFeeSats)
            let sdk = try await requireSdk()
            // Preparing suspends, so an exit can start meanwhile.
            let response = try await spends.run {
                try await sdk.sendPayment(request: SendPaymentRequest(
                    prepareResponse: prepared,
                    options: .bitcoinAddress(confirmationSpeed: .medium)
                ))
            }
            preparedWithdrawal = nil
            if case let .withdraw(txId, _, _) = response.payment.details {
                sentWithdrawalTxIds.insert(txId)
            }
            withdrawalFailedAt = response.payment.status == .failed ? Self.nowSecs() : nil
            withdrewAllAt = response.payment.status == .failed ? nil : Self.nowSecs()
            try await Self.settleWithdrawal(status: response.payment.status) { try await self.refresh() }
        } catch {
            withdrawalFailedAt = Self.nowSecs()
            throw error
        }
    }

    /// A sent withdrawal has left the balance, so only Spark's own failed status fails it; reading the balance
    /// again afterwards is best effort.
    static func settleWithdrawal(status: BreezSdkSpark.PaymentStatus, refresh: () async throws -> Void) async throws {
        guard status != .failed else {
            throw AppError(message: "common__error_body", debugMessage: "Spark reported the withdrawal as failed")
        }
        do {
            try await refresh()
        } catch {
            Logger.warn("Failed to refresh Spark after its withdrawal: \(error)", context: "SparkManager")
        }
    }

    /// Whether Spark refused to quote a withdrawal because even its cheapest fee leaves dust.
    nonisolated static func isBelowMinimum(_ error: Error) -> Bool {
        guard case let SdkError.InvalidInput(message) = error else { return false }
        return message.lowercased().hasPrefix("amount is below the minimum")
    }

    /// The fee `withdrawAll(to:maxFeeSats:)` pays at its speed, which comes out of the balance it moves.
    func withdrawAllFeeSats(to address: String) async throws -> UInt64 {
        try await Self.withdrawalFeeSats(prepareWithdrawAll(to: address))
    }

    private static func withdrawalFeeSats(_ prepared: PrepareSendPaymentResponse) -> UInt64 {
        guard case let .bitcoinAddress(_, feeQuote) = prepared.paymentMethod else { return 0 }
        return feeQuote.speedMedium.userFeeSat + feeQuote.speedMedium.l1BroadcastFeeSat
    }

    nonisolated static func checkWithdrawalFee(_ feeSats: UInt64, shownFeeSats: UInt64) throws {
        guard feeSats > shownFeeSats else { return }
        throw SparkWithdrawalFeeIncreased(feeSats: feeSats, shownFeeSats: shownFeeSats)
    }

    /// Whether `txid` is a withdrawal of this wallet's Spark balance to Savings, so its receipt is a transfer.
    func isWithdrawal(txid: String) -> Bool {
        Self.isWithdrawal(txid: txid, sent: sentWithdrawalTxIds, withdrawals: withdrawals)
    }

    nonisolated static func isWithdrawal(txid: String, sent: Set<String>, withdrawals: [SparkWithdrawal]) -> Bool {
        sent.contains(txid) || withdrawals.contains { $0.txid == txid }
    }

    /// Whether `txid` is a Spark withdrawal, which LDK never held and so can't boost: one this app sent, to Savings or a
    /// contact, or one Spark lists.
    func isSparkWithdrawal(txid: String, isSent: Bool) async -> Bool {
        let known = sentWithdrawalTxIds.union(Self.contactWithdrawalTxIds).union(withdrawals.map(\.txid))
        if Self.isSparkWithdrawal(txid: txid, isSent: isSent, known: known, payments: []) {
            return true
        }
        guard isReady else { return false }
        do {
            let payments = try await requireSdk().listPayments(request: ListPaymentsRequest(sortAscending: false)).payments
            return Self.isSparkWithdrawal(txid: txid, isSent: isSent, known: known, payments: payments)
        } catch {
            Logger.warn("Failed to list Spark payments for \(txid): \(error)", context: "SparkManager")
            return false
        }
    }

    nonisolated static func isSparkWithdrawal(txid: String, isSent: Bool, known: Set<String>, payments: [Payment]) -> Bool {
        // Only the sent side was Spark's; Savings owns the output a withdrawal to it pays, so its receipt can be boosted.
        guard isSent else { return false }
        return known.contains(txid) || payments.contains { payment in
            guard case let .withdraw(txId, _, _) = payment.details else { return false }
            return txId == txid
        }
    }

    /// Reuses the provider's withdrawal quote while it holds for the same address and balance, so the withdrawal
    /// pays the fee the confirm screen showed; a second full-balance quote can take minutes.
    private func prepareWithdrawAll(to address: String) async throws -> PrepareSendPaymentResponse {
        let balanceSats = balanceSats
        let now = UInt64(Date().timeIntervalSince1970)
        if let preparedWithdrawal, preparedWithdrawal.quote.holds(address: address, balanceSats: balanceSats, now: now) {
            return preparedWithdrawal.response
        }
        let response = try await prepareSend(paymentRequest: address, amountSats: balanceSats, feePolicy: .feesIncluded)
        if case let .bitcoinAddress(_, feeQuote) = response.paymentMethod {
            let quote = SparkWithdrawalQuote(address: address, balanceSats: balanceSats, expiresAt: feeQuote.expiresAt)
            preparedWithdrawal = (quote, response)
        }
        return response
    }

    /// A Paykit route that withdraws exactly `amountSats` to the contact's on-chain `endpoint` at medium speed, with
    /// Spark's fee on top, or nil while Spark cannot send it. bitkit-core's Paykit router weighs it against the contact's
    /// other endpoints. Throws `SparkLegUnaffordable` when the balance can't cover the amount and its fee.
    func withdrawalRouteLeg(endpoint: PaykitEndpoint, amountSats: UInt64) async throws -> ServiceRouteLeg? {
        guard isReady else { return nil }
        guard balanceSats >= amountSats else { throw SparkLegUnaffordable(debitSats: amountSats, balanceSats: balanceSats) }
        let prepared = try await prepareSend(paymentRequest: endpoint.value, amountSats: amountSats)
        guard case let .bitcoinAddress(_, feeQuote) = prepared.paymentMethod else {
            throw AppError(message: "Unexpected Spark payment method", debugMessage: "\(prepared.paymentMethod)")
        }
        guard !feeQuote.isEstimate else { return nil }
        return try Self.withdrawalRouteLeg(
            endpoint: endpoint,
            amountSats: amountSats,
            fee: feeQuote.speedMedium,
            validUntilUnix: feeQuote.expiresAt,
            balanceSats: balanceSats
        )
    }

    /// The leg that withdraws `amountSats` to `endpoint` with `fee` on top. Throws `SparkLegUnaffordable` when
    /// `balanceSats` can't cover both.
    nonisolated static func withdrawalRouteLeg(
        endpoint: PaykitEndpoint,
        amountSats: UInt64,
        fee: SendOnchainSpeedFeeQuote,
        validUntilUnix: UInt64,
        balanceSats: UInt64
    ) throws -> ServiceRouteLeg {
        let debitSats = withdrawalDebitSats(amountSats: amountSats, fee: fee)
        guard balanceSats >= debitSats else { throw SparkLegUnaffordable(debitSats: debitSats, balanceSats: balanceSats) }
        return ServiceRouteLeg(
            service: routeService,
            endpoint: endpoint,
            deliveredSat: amountSats,
            debitSat: debitSats,
            atomicity: routeAtomicity,
            validUntilUnix: validUntilUnix
        )
    }

    /// What a withdrawal of `amountSats` takes from the balance: the amount, Spark's fee and the L1 broadcast fee.
    nonisolated static func withdrawalDebitSats(amountSats: UInt64, fee: SendOnchainSpeedFeeQuote) -> UInt64 {
        amountSats.saturatingAdd(fee.userFeeSat).saturatingAdd(fee.l1BroadcastFeeSat)
    }

    /// Withdraws exactly `amountSats` to a contact's on-chain `address` at medium speed and returns its txid. The
    /// withdrawal is written to a journal before it is sent, so one interrupted mid-send settles from Spark's payment
    /// list; a second one is refused while it is open. It is recorded as a sent on-chain activity for the contact.
    /// A withdrawal that pays a Paykit request (`request`) completes the request's on-chain proof with its txid, also when
    /// it settles from the journal. `beforeSend` runs right before Spark sends, after the quote.
    func withdraw(
        to address: String,
        amountSats: UInt64,
        contact: String?,
        request: SparkContactWithdrawal.PaykitRequest? = nil,
        tags: [String] = [],
        maxFeeSats: UInt64? = nil,
        paymentDeadline: PaykitPreciseInstant? = nil,
        beforeSend: () async throws -> Void = {}
    ) async throws -> String {
        // Everything before the journal is written sends nothing, so a refusal here says so to the caller.
        let sdk: BreezSdk
        let prepared: PrepareSendPaymentResponse
        let earlierPayments: [Payment]
        do {
            // An exit spends every leaf, so no contact withdrawal starts while one runs.
            guard !isExiting else {
                throw ChannelFreeRailSendRefused(reason: t("wallet__payment_failed_description"))
            }
            try claimContactWithdrawal()
        } catch {
            throw SparkWithdrawalNotSent(underlying: error)
        }
        defer { releaseContactWithdrawalClaim() }
        do {
            sdk = try await requireSdk()
            prepared = try await prepareSend(paymentRequest: address, amountSats: amountSats)
            if let maxFeeSats, case let .bitcoinAddress(_, feeQuote) = prepared.paymentMethod {
                // The fee Confirm showed caps the one sent, broadcast fee included.
                try Self.checkWithdrawalFee(
                    Self.withdrawalDebitSats(amountSats: amountSats, fee: feeQuote.speedMedium) - amountSats,
                    shownFeeSats: maxFeeSats
                )
            }
            // Withdrawals Spark already lists for this address and amount belong to earlier attempts, so recovery never
            // takes one of them for this attempt.
            earlierPayments = try await sdk.listPayments(request: ListPaymentsRequest(sortAscending: false)).payments
        } catch {
            throw SparkWithdrawalNotSent(underlying: error)
        }
        var pending = SparkContactWithdrawal(
            address: address,
            amountSats: amountSats,
            contact: contact,
            startedAt: UInt64(Date().timeIntervalSince1970),
            request: request,
            tags: tags,
            earlierPaymentIds: Self.withdrawalIds(to: address, amountSats: amountSats, in: earlierPayments),
            idempotencyKey: UUID().uuidString.lowercased()
        )
        let journaled = pending
        try await Self.startJournaledWithdrawal(
            writeJournal: {
                Self.pendingContactWithdrawal = journaled
                Self.lastContactWithdrawalResolution = nil
            },
            beforeSend: beforeSend,
            closeUnsent: {
                await Self.closeUnsentWithdrawal(journaled, releaseProof: Self.releaseUnsentProof, failAllowance: Self.failAllowance)
            },
            paymentDeadline: paymentDeadline
        )
        let idempotencyKey = pending.idempotencyKey
        let response = try await Self.sendJournaledWithdrawal(
            spends: spends,
            send: {
                try await sdk.sendPayment(request: SendPaymentRequest(
                    prepareResponse: prepared,
                    options: .bitcoinAddress(confirmationSpeed: .medium),
                    idempotencyKey: idempotencyKey
                ))
            },
            closeUnsent: {
                await Self.closeUnsentWithdrawal(journaled, releaseProof: Self.releaseUnsentProof, failAllowance: Self.failAllowance)
            },
            settleLater: {
                let failedAt = UInt64(Date().timeIntervalSince1970)
                Task {
                    await Self.settleAfterFailedWithdrawal(
                        failedAt: failedAt,
                        syncWallet: {
                            _ = try await self.requireSdk().syncWallet(request: SyncWalletRequest())
                            self.syncedThisRun = true
                        },
                        hasSynced: { await self.hasSynced(after: $0) },
                        settle: { await self.settleContactWithdrawal(allowClear: $0) }
                    )
                }
            }
        )
        Logger.info("Sent Spark withdrawal '\(response.payment.id)' with status '\(response.payment.status)'", context: "SparkManager")
        pending.paymentId = response.payment.id
        Self.pendingContactWithdrawal = pending
        if case let .withdraw(txId, _, _) = response.payment.details {
            await recordContactWithdrawal(response.payment, txId: txId, pending: pending)
        }
        await refreshState()
        return try Self.sentWithdrawalId(response.payment)
    }

    /// Claims the one contact withdrawal slot before anything awaits, so a second send started meanwhile is refused
    /// instead of overwriting the first one's journal.
    func claimContactWithdrawal() throws {
        guard Self.pendingContactWithdrawal == nil, !isWithdrawingToContact else {
            throw AppError(message: "wallet__payment_failed_description", debugMessage: "A Spark withdrawal to a contact is still settling")
        }
        isWithdrawingToContact = true
    }

    func releaseContactWithdrawalClaim() {
        isWithdrawingToContact = false
    }

    /// What `withdraw` returns for the payment Spark sent: its txid, or its id while Spark gives none yet. A withdrawal
    /// Spark returned as failed paid nothing, so the call ends as a refusal: the caller releases the request's proof,
    /// private list and allowance attempt and shows a failure, never a success. One still pending can fail until the
    /// provider accepts its payout, so the caller holds it as unknown, on the pending screen, until its journal settles.
    nonisolated static func sentWithdrawalId(_ payment: Payment) throws -> String {
        guard payment.status != .failed else {
            throw SparkWithdrawalNotSent(underlying: AppError(
                message: "wallet__payment_failed_description",
                debugMessage: "Spark returned withdrawal '\(payment.id)' as failed"
            ))
        }
        guard payment.status == .completed else {
            throw AppError(message: "wallet__payment_failed_description", debugMessage: "Spark withdrawal '\(payment.id)' is still pending")
        }
        guard case let .withdraw(txId, _, _) = payment.details else { return payment.id }
        return txId
    }

    /// Sends a contact withdrawal whose journal is open, counted in `spends` so an exit starting meanwhile refuses it or
    /// waits for it. A send refused before it left closes the journal and ends as `SparkWithdrawalNotSent`; any other
    /// failure settles later from Spark's payment list.
    static func sendJournaledWithdrawal<T>(
        spends: SparkSpends,
        send: () async throws -> T,
        closeUnsent: () async -> Void,
        settleLater: () -> Void
    ) async throws -> T {
        do {
            return try await spends.run(send)
        } catch {
            throw await withdrawalSendFailure(error, closeUnsent: closeUnsent, settleLater: settleLater)
        }
    }

    /// What a failed `sendPayment` of a journaled withdrawal means. A refusal Spark makes before anything reaches the
    /// operators, as on the Lightning rail, closes the journal at once; an outcome that may have sent it stays journaled
    /// and settles from the sync after it.
    static func withdrawalSendFailure(
        _ error: Error,
        closeUnsent: () async -> Void,
        settleLater: () -> Void
    ) async -> Error {
        let failure = sendPaymentFailure(error)
        if failure is ChannelFreeRailSendRefused || isWithdrawalFeeRise(error) {
            Logger.warn("Spark refused a withdrawal to a contact before sending it: \(error)", context: "SparkManager")
            await closeUnsent()
            return SparkWithdrawalNotSent(underlying: failure)
        }
        Logger.warn("Spark withdrawal to a contact failed or its outcome is unknown: \(error)", context: "SparkManager")
        settleLater()
        return error
    }

    /// Spark refetches a withdrawal's quote near its expiry and refuses one whose fee rose past the prepared one at every
    /// speed with this input error, before it withdraws (`affordable_speed` in the 0.28.0 SDK's `send/bitcoin_address.rs`).
    nonisolated static func isWithdrawalFeeRise(_ error: Error) -> Bool {
        guard case let SdkError.InvalidInput(message) = error else { return false }
        return message.localizedCaseInsensitiveContains("onchain fee rose to")
    }

    /// Settles the open contact withdrawal from Spark's payments: its own payment, once Spark returned it, or else a
    /// withdrawal to its address and amount that wasn't listed before it started. With `allowClear` (after a sync that
    /// succeeded), a list without one closes it as never sent and releases the request's proof, but only once the
    /// attempt is past `contactWithdrawalExpirySecs`, so a withdrawal Spark hasn't listed yet is never dropped. One still
    /// in flight in this process is never settled.
    func settleContactWithdrawal(allowClear: Bool, now: UInt64 = UInt64(Date().timeIntervalSince1970)) async {
        guard let pending = Self.pendingContactWithdrawal, !isWithdrawingToContact,
              let payments = try? await requireSdk().listPayments(request: ListPaymentsRequest(sortAscending: false)).payments
        else { return }
        let payment = Self.matchingWithdrawal(pending, in: payments)
        if let payment, case let .withdraw(txId, _, _) = payment.details {
            await recordContactWithdrawal(payment, txId: txId, pending: pending)
        } else if allowClear, Self.canCloseUnlisted(pending, listed: payment, now: now) {
            Logger.info("Closed a Spark contact withdrawal Spark never listed", context: "SparkManager")
            await Self.closeUnsentWithdrawal(pending, releaseProof: Self.releaseUnsentProof, failAllowance: Self.failAllowance)
        }
    }

    /// Settles a withdrawal whose send failed or has an unknown outcome from the sync after it. That sync returns even
    /// when it never reached Spark, so only one that completed after `failedAt` may close an unlisted one as unsent.
    static func settleAfterFailedWithdrawal(
        failedAt: UInt64,
        syncWallet: () async throws -> Void,
        hasSynced: (UInt64) async -> Bool,
        settle: (_ allowClear: Bool) async -> Void
    ) async {
        guard await (try? syncWallet()) != nil else { return }
        await settleAfterSync(since: failedAt, hasSynced: hasSynced, settle: settle)
    }

    /// Spark reports a sync that never reached it as done too, its `.synced` event included, so only one that completed
    /// after `since` may close an unlisted withdrawal as unsent.
    static func settleAfterSync(
        since: UInt64,
        hasSynced: (UInt64) async -> Bool,
        settle: (_ allowClear: Bool) async -> Void
    ) async {
        let synced = await hasSynced(since)
        await settle(synced)
    }

    /// Writes the attempt's journal before `beforeSend` starts the request's proof, so a kill between the two leaves a
    /// journal that recovery closes as unsent once it expires, releasing the proof; a refusal in `beforeSend`, or a
    /// `paymentDeadline` passed by then, closes it at once, releasing what it started.
    static func startJournaledWithdrawal(
        writeJournal: () -> Void,
        beforeSend: () async throws -> Void,
        closeUnsent: () async -> Void,
        paymentDeadline: PaykitPreciseInstant? = nil,
        now: () -> Date = Date.init
    ) async throws {
        writeJournal()
        do {
            try await beforeSend()
            // A quote can expire while the request and its allowance are checked, so it is checked last.
            try PaykitPaymentRequest.checkPaymentDeadline(paymentDeadline, at: now())
        } catch {
            await closeUnsent()
            throw SparkWithdrawalNotSent(underlying: error)
        }
    }

    nonisolated static let contactWithdrawalExpirySecs: UInt64 = 600

    /// An attempt Spark never returned nor listed is taken as unsent only after the expiry. Spark can list its payment
    /// without withdrawal details while the payout may still go out, so only one it failed is unsent too.
    nonisolated static func canCloseUnlisted(_ pending: SparkContactWithdrawal, listed: Payment? = nil, now: UInt64) -> Bool {
        pending.paymentId == nil && (listed?.status ?? .failed) == .failed && now >= pending.startedAt + contactWithdrawalExpirySecs
    }

    /// The attempt's own payment, by the id Spark returned or the idempotency key it keeps as the id, also while Spark
    /// lists it without withdrawal details; else, for one Spark never returned, a new withdrawal to its address and amount.
    nonisolated static func matchingWithdrawal(_ pending: SparkContactWithdrawal, in payments: [Payment]) -> Payment? {
        if let ownId = pending.paymentId ?? pending.idempotencyKey, let own = payments.first(where: { $0.id == ownId }) {
            return own
        }
        guard pending.paymentId == nil else { return nil }
        let earlier = Set(pending.earlierPaymentIds ?? [])
        return payments.first { payment in
            !earlier.contains(payment.id) && withdrawalIds(to: pending.address, amountSats: pending.amountSats, in: [payment]) == [payment.id]
        }
    }

    nonisolated static func withdrawalIds(to address: String, amountSats: UInt64, in payments: [Payment]) -> [String] {
        payments.compactMap { payment in
            guard payment.paymentType == .send, case let .withdraw(_, _, destination) = payment.details,
                  destination == address, sats(payment.amount) == amountSats
            else { return nil }
            return payment.id
        }
    }

    /// What an open withdrawal's journal does with the payment Spark returned or lists for it. Spark keeps a withdrawal
    /// pending until the provider accepts its payout, and one it never accepts still fails, so only a completed one paid.
    nonisolated static func settlement(of status: BreezSdkSpark.PaymentStatus) -> SparkWithdrawalSettlement {
        switch status {
        case .completed: .record
        case .failed: .closeUnsent
        case .pending: .wait
        }
    }

    /// Writes the withdrawal's sent activity, tags and request proof, and closes the journal only once all of them are
    /// saved, so a failed or interrupted write is retried from the journal.
    private func recordContactWithdrawal(_ payment: Payment, txId: String, pending: SparkContactWithdrawal) async {
        // A settle that raced this one already saved everything; its request's proof and allowance may be a retry's now.
        guard Self.isOpenJournal(pending) else { return }
        switch Self.settlement(of: payment.status) {
        case .wait:
            return
        case .closeUnsent:
            await Self.closeUnsentWithdrawal(pending, releaseProof: Self.releaseUnsentProof, failAllowance: Self.failAllowance)
            return
        case .record:
            break
        }
        Self.contactWithdrawalTxIds.insert(txId)
        let isDurable = await Self.recordWithdrawalLocally(
            saveProof: {
                guard let request = pending.request else { return true }
                return await PaykitPaymentProofService.shared.completeSparkOnchainPayment(
                    requestId: request.id,
                    identity: request.identity,
                    txid: txId
                )
            },
            saveActivity: {
                await CoreService.shared.activity.createSentOnchainActivityFromSendResult(
                    txid: txId,
                    address: pending.address,
                    amount: pending.amountSats,
                    fee: Self.sats(payment.fees),
                    feeRate: 0,
                    contact: pending.contact,
                    feeIsExact: true
                )
            },
            saveTags: {
                guard let tags = pending.tags, !tags.isEmpty else { return true }
                return await (try? CoreService.shared.activity.appendTags(toActivity: txId, tags)) != nil
            }
        )
        Self.confirmMinedContactPayouts(Self.completedContactPayouts([payment], contactWithdrawals: [txId]))
        if isDurable {
            if let request = pending.request {
                await PaykitAllowanceExecutor.shared.settleManualPayment(requestId: request.id, outcome: .succeeded, transactionId: txId)
            }
            if Self.clearJournal(pending) {
                Self.resolveContactWithdrawal(pending, txId: txId)
            }
        } else {
            Logger.warn("Kept the Spark contact withdrawal journal: its local records are not all saved yet", context: "SparkManager")
        }
    }

    /// Closes the journal of a withdrawal that never went out, but only once its request's started proof is released:
    /// a proof left behind would block the request, so the journal stays for the next sync to retry. The request's
    /// allowance attempt, left unknown when the send's outcome was, then fails, so the ledger lets it be paid again.
    static func closeUnsentWithdrawal(
        _ pending: SparkContactWithdrawal,
        releaseProof: (SparkContactWithdrawal.PaykitRequest, _ failAllowance: () async -> Bool) async -> SparkProofRelease,
        failAllowance: @escaping (SparkContactWithdrawal.PaykitRequest) async -> Bool
    ) async {
        // The proof and allowance attempt match by request, so a stale close would release a retry's.
        guard isOpenJournal(pending) else { return }
        // The allowance attempt begins only once the proof started, so only a started proof fails one, and it fails
        // before that proof goes, so a restart in between still finds the proof to settle it from.
        if let request = pending.request, await releaseProof(request, { await failAllowance(request) }) == .failed {
            Logger.warn("Kept the Spark contact withdrawal journal: its unsent proof is not released yet", context: "SparkManager")
            return
        }
        if clearJournal(pending) {
            resolveContactWithdrawal(pending, txId: nil)
        }
    }

    nonisolated static func isOpenJournal(_ pending: SparkContactWithdrawal) -> Bool {
        pendingContactWithdrawal == pending
    }

    /// Clears `pending`'s journal only while it is still the open one, so a stale recovery never drops a newer
    /// withdrawal's journal, which could then be paid twice. Returns whether it cleared it: only then is the resolution
    /// this attempt's to publish, since a retry of the same request shares its attempt.
    nonisolated static func clearJournal(_ pending: SparkContactWithdrawal) -> Bool {
        guard isOpenJournal(pending) else { return false }
        pendingContactWithdrawal = nil
        return true
    }

    static func resolveContactWithdrawal(_ pending: SparkContactWithdrawal, txId: String?) {
        let resolution = SparkContactWithdrawalResolution(attempt: pending.attempt, txId: txId)
        lastContactWithdrawalResolution = resolution
        contactWithdrawalResolutionSubject.send(resolution)
    }

    private static func releaseUnsentProof(
        _ request: SparkContactWithdrawal.PaykitRequest,
        failAllowance: () async -> Bool
    ) async -> SparkProofRelease {
        await PaykitPaymentProofService.shared.failSparkOnchainPayment(
            requestId: request.id,
            identity: request.identity,
            unstartedPaymentList: request.paymentList,
            settleAllowance: failAllowance
        )
    }

    private static func failAllowance(_ request: SparkContactWithdrawal.PaykitRequest) async -> Bool {
        await PaykitAllowanceExecutor.shared.settleManualPayment(requestId: request.id, outcome: .failed)
    }

    /// Saves the proof, then the activity, then its tags; true only when every write succeeded.
    static func recordWithdrawalLocally(
        saveProof: () async -> Bool,
        saveActivity: () async -> Bool,
        saveTags: () async -> Bool
    ) async -> Bool {
        let proofSaved = await saveProof()
        let activitySaved = await saveActivity()
        let tagsSaved = activitySaved ? await saveTags() : false
        return proofSaved && activitySaved && tagsSaved
    }

    private nonisolated static let pendingContactWithdrawalKey = "sparkPendingContactWithdrawal"
    private nonisolated static let contactWithdrawalTxIdsKey = "sparkContactWithdrawalTxIds"

    nonisolated static var pendingContactWithdrawal: SparkContactWithdrawal? {
        get {
            UserDefaults.standard.data(forKey: pendingContactWithdrawalKey)
                .flatMap { try? JSONDecoder().decode(SparkContactWithdrawal.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: pendingContactWithdrawalKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pendingContactWithdrawalKey)
            }
        }
    }

    /// Withdrawals paid to contacts, which stay sent payments rather than transfers to Savings.
    nonisolated static var contactWithdrawalTxIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: contactWithdrawalTxIdsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: contactWithdrawalTxIdsKey) }
    }

    /// What a unilateral exit needs if the Spark operators stop cooperating; it can reach several MB.
    func exportExitState() async throws -> String {
        try await requireSdk().exportUnilateralExitState().exitState
    }

    /// The exit data backup, or nil while Spark is not connected and there is nothing to back up.
    func exitBackup() async throws -> SparkExitBackupV1? {
        guard isConnected, let network = Self.sparkNetwork else { return nil }
        return try await SparkExitBackupV1(
            version: 1,
            createdAt: UInt64(Date().timeIntervalSince1970 * 1000),
            network: "\(network)",
            exitState: exportExitState()
        )
    }

    /// Puts a restored exit data backup back: at once while Spark is connected, otherwise right after it connects,
    /// before it is used, so a restored wallet can exit on-chain even while the Spark operators are unreachable.
    func restoreExitBackup(_ backup: SparkExitBackupV1, walletIndex: Int) async throws {
        guard let network = Self.sparkNetwork, backup.network == "\(network)" else {
            Logger.warn("Skipped Spark exit data from network '\(backup.network)'", context: "SparkManager")
            return
        }
        let file = Env.sparkExitRestore(walletIndex: walletIndex)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(backup.exitState.utf8).write(to: file, options: .atomic)
        if isConnected {
            await importRestoredExitState(walletIndex: walletIndex)
        }
    }

    /// Whether restored exit data is still waiting for its import, after trying that again while connected.
    func hasStagedExitState(walletIndex: Int) async -> Bool {
        await importRestoredExitState(walletIndex: walletIndex)
        return FileManager.default.fileExists(atPath: Env.sparkExitRestore(walletIndex: walletIndex).path)
    }

    private func importRestoredExitState(walletIndex: Int) async {
        let file = Env.sparkExitRestore(walletIndex: walletIndex)
        guard let sdk, let data = FileManager.default.contents(atPath: file.path) else { return }
        do {
            let imported = try await sdk.importUnilateralExitState(
                request: ImportUnilateralExitStateRequest(exitState: String(decoding: data, as: UTF8.self))
            )
            try FileManager.default.removeItem(at: file)
            Logger.info(
                "Imported Spark exit data: '\(imported.importedLeaves)' leaves, '\(imported.skippedForeignLeaves)' foreign, "
                    + "'\(imported.skippedConflictingLeaves)' conflicting, '\(imported.skippedChains)' already held",
                context: "SparkManager"
            )
        } catch {
            Logger.error("Failed to import Spark exit data: \(error)", context: "SparkManager")
        }
    }

    // MARK: Private

    private nonisolated func prepareSend(
        paymentRequest: String,
        amountSats: UInt64?,
        feePolicy: FeePolicy? = nil
    ) async throws -> PrepareSendPaymentResponse {
        try await requireSdk().prepareSendPayment(request: PrepareSendPaymentRequest(
            paymentRequest: .input(input: paymentRequest),
            amount: amountSats.map { BInt(Int($0)) },
            tokenIdentifier: nil,
            conversionOptions: nil,
            feePolicy: feePolicy
        ))
    }

    private nonisolated func requireSdk() async throws -> BreezSdk {
        guard let sdk = await sdk else {
            throw AppError(message: "wallet__payment_failed_description", debugMessage: "Spark wallet is not connected")
        }
        return sdk
    }

    /// Reads the Spark balance and deposits again, for pull to refresh.
    /// Lists a deposit the app just broadcast as pending right away, then syncs so Spark sees it sooner than its
    /// minute-long background sync; Spark's own deposit state replaces it once listed.
    func onDepositBroadcast(txid: String, amountSats: UInt64) {
        broadcastDeposits[txid] = amountSats
        applyBroadcastDeposits()
        onStateChanged?()
        Task {
            do {
                _ = try await requireSdk().syncWallet(request: SyncWalletRequest())
                syncedThisRun = true
            } catch {
                Logger.warn("Failed to sync Spark after deposit \(txid): \(error)", context: "SparkManager")
            }
            await refreshState()
        }
    }

    private func applyBroadcastDeposits() {
        let known = Set(deposits.map(\.txid))
        let local = broadcastDeposits
            .filter { !known.contains($0.key) }
            .map { SparkDeposit(txid: $0.key, amountSats: $0.value, isClaimed: false, confirmations: 0, isListed: false) }
        guard !local.isEmpty else { return }
        deposits = local + deposits
        pendingDepositSats = deposits.filter { !$0.isClaimed }.reduce(0) { $0 + $1.amountSats }
    }

    func refreshState() async {
        guard sdk != nil else { return }
        do {
            try await refresh()
        } catch {
            Logger.warn("Failed to refresh Spark state: \(error)", context: "SparkManager")
        }
    }

    /// One refresh at a time: a call during one waits for it, and it reads once more so the caller sees fresh state.
    private func refresh() async throws {
        if let refreshTask {
            refreshAgain = true
            return try await refreshTask.value
        }
        let task = Task {
            defer { refreshTask = nil }
            repeat {
                refreshAgain = false
                try await refreshOnce()
            } while refreshAgain
        }
        refreshTask = task
        try await task.value
    }

    private func refreshOnce() async throws {
        let sdk = try await requireSdk()
        let info = try await sdk.getInfo(request: GetInfoRequest(ensureSynced: false))
        if let syncError = info.lastSyncError {
            Logger.warn("Spark's last sync failed: \(syncError)", context: "SparkManager")
        }
        let listedUnclaimed = try await sdk.listUnclaimedDeposits(request: ListUnclaimedDepositsRequest()).deposits
        let payments = try await sdk.listPayments(request: ListPaymentsRequest()).payments
        let claimed = payments.filter { $0.method == .deposit && $0.status == .completed }
        let unclaimed = Self.unclaimedDeposits(listedUnclaimed, claimed: claimed)
        let listedDeposits = await Self.deposits(unclaimed: unclaimed, claimed: claimed)
        // A wipe while this read was in flight leaves the state it cleared.
        guard self.sdk === sdk else { return }
        let pending = unclaimed.reduce(0) { $0 + $1.amountSats }
        withdrawalFailedAt = Self.withdrawalFailedAt(
            withdrawalFailedAt, read: info.balanceSats, lastSyncedAt: info.lastSyncedAt, syncFailed: info.lastSyncError != nil
        )
        withdrewAllAt = Self.withdrewAllAt(withdrewAllAt, read: info.balanceSats, lastSyncedAt: info.lastSyncedAt)
        let kept = Self.keptBalanceSats(
            read: info.balanceSats,
            lastShown: shownBalanceSats,
            isStale: withdrawalFailedAt != nil || info.lastSyncError != nil,
            withdrewAll: withdrewAllAt != nil,
            isExiting: isExiting
        )
        let changed = !isReady || Self.balancesChanged(
            from: SparkBalances(readSats: balanceSats, keptSats: keptBalanceSats, pendingSats: pendingDepositSats),
            to: SparkBalances(readSats: info.balanceSats, keptSats: kept, pendingSats: pending)
        )
        isReady = true
        balanceSats = info.balanceSats
        keptBalanceSats = kept
        pendingDepositSats = pending
        recoverableFundsSats = info.recoverableFundsSats
        deposits = listedDeposits
        withdrawals = Self.withdrawals(payments)
        for deposit in deposits {
            broadcastDeposits[deposit.txid] = nil
        }
        applyBroadcastDeposits()
        if changed {
            onStateChanged?()
        }
        for payment in Self.paymentsToRecordAgain(payments, unsaved: unsavedPayments, recordedWithoutFee: sendsRecordedWithoutFee) {
            await recordActivity(payment)
        }
        let contactWithdrawals = Self.contactWithdrawalTxIds
        for txId in Self.savingsTransferTxIds(unclaimed: unclaimed, payments: payments, contactWithdrawals: contactWithdrawals) {
            await CoreService.shared.activity.markOnchainActivityAsTransfer(txId: txId)
        }
        Self.confirmMinedContactPayouts(Self.completedContactPayouts(payments, contactWithdrawals: contactWithdrawals))
    }

    /// The output of a contact withdrawal's transaction that pays the contact.
    struct ContactPayout: Equatable {
        let txId: String
        let vout: UInt32
        let address: String
    }

    /// The payouts of the contact withdrawals Spark lists as completed.
    nonisolated static func completedContactPayouts(_ payments: [Payment], contactWithdrawals: Set<String>) -> [ContactPayout] {
        payments.compactMap { payment in
            guard payment.status == .completed, case let .withdraw(txId, vout, address) = payment.details,
                  contactWithdrawals.contains(txId)
            else { return nil }
            return ContactPayout(txId: txId, vout: vout, address: address)
        }
    }

    /// Looks the payouts up on chain off the refresh, so a slow Electrum server never holds a send that waits for it.
    private static func confirmMinedContactPayouts(_ payouts: [ContactPayout]) {
        guard !payouts.isEmpty else { return }
        Task {
            await confirmMinedPayouts(
                payouts,
                needsConfirmation: { txId in
                    await (try? CoreService.shared.activity.getOnchainActivityByTxId(txid: txId))?.confirmed == false
                },
                unspentOutputs: { address in
                    try await OnChainHwService.shared.getAddressInfo(
                        address: address,
                        electrumUrl: OnChainHwService.getElectrumUrl(),
                        network: OnChainHwService.appDefaultCoinType
                    ).utxos
                },
                isMined: { txId in
                    guard let network = Self.exitNetwork else { return false }
                    do {
                        return try await EsploraSparkExitChain.network(network).txStatus(txid: txId).confirmed
                    } catch let error as URLError where error.code == .fileDoesNotExist {
                        // Spark can list a payout before it is broadcast, and the chain then knows no such transaction.
                        return false
                    }
                },
                markConfirmed: { await CoreService.shared.activity.markOnchainActivityAsConfirmed(txId: $0) }
            )
        }
    }

    /// Spark lists a withdrawal completed once its provider took the payout on, which can be before the payout transaction
    /// is broadcast or mined, so a payout's activity is confirmed only once the payout is in a block. The payout address's
    /// unspent outputs show that first; an output missing there, such as one the contact spent before Bitkit saw it mined,
    /// or a failed read of them, is looked up by its transaction (`isMined`) instead.
    nonisolated static func confirmMinedPayouts(
        _ payouts: [ContactPayout],
        needsConfirmation: (String) async -> Bool,
        unspentOutputs: (String) async throws -> [AccountUtxo],
        isMined: (String) async throws -> Bool,
        markConfirmed: (String) async -> Void
    ) async {
        for payout in payouts {
            guard await needsConfirmation(payout.txId) else { continue }
            do {
                let outputs: [AccountUtxo]
                do {
                    outputs = try await unspentOutputs(payout.address)
                } catch {
                    // A failed Electrum lookup falls through to the transaction's status, as a missing output does.
                    Logger.warn("Failed to read the payout address of Spark withdrawal '\(payout.txId)': \(error)", context: "SparkManager")
                    outputs = []
                }
                let isPayoutMined: Bool = if let output = outputs.first(where: { $0.txid == payout.txId && $0.vout == payout.vout }) {
                    output.confirmations > 0
                } else {
                    try await isMined(payout.txId)
                }
                if isPayoutMined {
                    await markConfirmed(payout.txId)
                }
            } catch {
                Logger.warn("Failed to look up the payout of Spark withdrawal '\(payout.txId)': \(error)", context: "SparkManager")
            }
        }
    }

    /// Whether balances and the receive invoice must follow a refresh: the read balance counts too, as sends use it, and
    /// it can come back to the shown one while that stays the same.
    nonisolated static func balancesChanged(from old: SparkBalances, to new: SparkBalances) -> Bool {
        old != new
    }

    /// After a failed withdrawal, or while Spark's last sync failed (`isStale`), Spark can read 0 with the funds still
    /// there, so the last shown balance stays shown until it reads one again. After a withdrawal of the whole balance
    /// (`withdrewAll`) the 0 is real. An emergency exit moves the balance to savings, so a 0 read during one keeps nothing.
    nonisolated static func keptBalanceSats(read: UInt64, lastShown: UInt64, isStale: Bool, withdrewAll: Bool, isExiting: Bool) -> UInt64? {
        read == 0 && isStale && !withdrewAll && lastShown > 0 && !isExiting ? lastShown : nil
    }

    /// The balance kept again once an exit ends: a cancelled exit moved nothing, so what was kept before it still is.
    nonisolated static func keptBalanceSats(afterExitKept kept: UInt64?, read: UInt64, isCancel: Bool) -> UInt64? {
        isCancel && read == 0 ? kept : nil
    }

    /// A failed withdrawal stops keeping the balance once Spark reads one, or reads 0 after a sync that ended after it.
    nonisolated static func withdrawalFailedAt(_ failedAt: UInt64?, read: UInt64, lastSyncedAt: UInt64?, syncFailed: Bool) -> UInt64? {
        guard let failedAt, read == 0, syncFailed || (lastSyncedAt ?? 0) <= failedAt else { return nil }
        return failedAt
    }

    /// A full withdrawal stops making a read of 0 real once a sync that ended after it reads a balance, so a refresh
    /// that read the balance before the withdrawal can't bring it back.
    nonisolated static func withdrewAllAt(_ withdrewAt: UInt64?, read: UInt64, lastSyncedAt: UInt64?) -> UInt64? {
        guard let withdrewAt, read == 0 || (lastSyncedAt ?? 0) <= withdrewAt else { return nil }
        return withdrewAt
    }

    private nonisolated static func nowSecs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970)
    }

    /// Spark can still list a deposit it already claimed early as unclaimed, so a claimed one is listed only as claimed.
    /// Matched by output, as one transaction can hold several deposits.
    nonisolated static func unclaimedDeposits(_ unclaimed: [DepositInfo], claimed: [Payment]) -> [DepositInfo] {
        let claimedOutputs = Set(claimed.compactMap { payment -> String? in
            guard case let .deposit(txId, vout) = payment.details else { return nil }
            return "\(txId.lowercased()):\(vout)"
        })
        return unclaimed.filter { !claimedOutputs.contains("\($0.txid.lowercased()):\($0.vout)") }
    }

    /// Spark's withdrawals to Savings, without the ones that paid contacts: those recorded as sent, and the open
    /// journal's, which Spark keeps pending until its payout is accepted.
    nonisolated static func withdrawals(_ payments: [Payment]) -> [SparkWithdrawal] {
        let contactWithdrawals = contactWithdrawalTxIds
        let journaledId = pendingContactWithdrawal.flatMap { matchingWithdrawal($0, in: payments)?.id }
        return payments.compactMap { payment in
            guard payment.status != .failed, payment.id != journaledId, case let .withdraw(txId, _, _) = payment.details,
                  !contactWithdrawals.contains(txId) else { return nil }
            return SparkWithdrawal(txid: txId, amountSats: sats(payment.amount), feeSats: sats(payment.fees))
        }
    }

    /// The transfers between Savings and Spark, without the withdrawals that paid contacts, which stay sends to them.
    nonisolated static func savingsTransferTxIds(unclaimed: [DepositInfo], payments: [Payment], contactWithdrawals: Set<String>) -> [String] {
        transferTxIds(unclaimed: unclaimed, payments: payments).filter { !contactWithdrawals.contains($0) }
    }

    /// On-chain transactions that moved funds between Savings and Spark, so their activities show as transfers.
    nonisolated static func transferTxIds(unclaimed: [DepositInfo], payments: [Payment]) -> [String] {
        unclaimed.map(\.txid) + payments.compactMap { payment in
            guard payment.status != .failed else { return nil }
            switch payment.details {
            case let .deposit(txId, _), let .withdraw(txId, _, _): return txId
            default: return nil
            }
        }
    }

    private static func deposits(unclaimed: [DepositInfo], claimed: [Payment]) async -> [SparkDeposit] {
        let confirmations = await onchainConfirmations()
        let pending = unclaimed.map {
            SparkDeposit(txid: $0.txid, amountSats: $0.amountSats, isClaimed: false, confirmations: confirmations[$0.txid] ?? nil)
        }
        let done: [SparkDeposit] = claimed.compactMap { payment in
            guard case let .deposit(txId, _) = payment.details else { return nil }
            return SparkDeposit(
                txid: txId,
                amountSats: sats(payment.amount),
                isClaimed: true,
                feeSats: sats(payment.fees),
                claimedAt: payment.timestamp
            )
        }
        return pending + done
    }

    /// Confirmations of the on-chain transactions this wallet sent or received, 0 while unconfirmed.
    private static func onchainConfirmations() async -> [String: UInt32?] {
        let tip = LightningService.shared.status?.currentBestBlock.height
        let payments = await LightningService.shared.listPayments() ?? []
        var result: [String: UInt32?] = [:]
        for payment in payments {
            guard case let .onchain(txid, status) = payment.kind else { continue }
            switch status {
            case .unconfirmed:
                result[txid] = 0
            case let .confirmed(_, height, _):
                result[txid] = tip.map { $0 >= height ? $0 - height + 1 : 0 }
            }
        }
        return result
    }

    /// Payment hashes whose every Lightning send failed, so a hold on a channel retry can be released.
    nonisolated static func failedSendHashes(_ payments: [Payment]) -> [String] {
        var failed: [String] = []
        var live: Set<String> = []
        for payment in payments where payment.paymentType == .send {
            guard case let .lightning(_, _, _, htlcDetails, _, _, _, _) = payment.details else { continue }
            if payment.status == .failed {
                failed.append(htlcDetails.paymentHash)
            } else {
                live.insert(htlcDetails.paymentHash)
            }
        }
        return failed.filter { !live.contains($0) }
    }

    private func syncActivities() async throws {
        let payments = try await requireSdk().listPayments(request: ListPaymentsRequest()).payments
        var recordError: Error?
        do {
            try await Self.recordAll(payments) { await self.recordActivity($0) }
        } catch {
            recordError = error
        }
        // A send that failed while the app was closed released no hold on a channel retry.
        await Self.releaseFailedSendHolds { try await self.requireSdk().listPayments(request: ListPaymentsRequest()).payments }
        if let recordError {
            throw recordError
        }
    }

    /// Releases the holds of the sends Spark's list shows failed. The list is read after the activities were recorded,
    /// so a retry the user started meanwhile keeps its hold, as does one recorded or ending while the list is read.
    static func releaseFailedSendHolds(listPayments: () async throws -> [Payment]) async {
        let mark = LightningService.shared.attemptMark
        guard let latest = try? await listPayments() else { return }
        for paymentHash in failedSendHashes(latest) {
            LightningService.shared.releaseRailAttempt(paymentHash: paymentHash, since: mark)
        }
    }

    /// Records every payment, then throws when any failed to save, so the activity sync isn't marked complete.
    static func recordAll(_ payments: [Payment], record: (Payment) async -> Bool) async throws {
        var unsaved = 0
        for payment in payments where await !record(payment) {
            unsaved += 1
        }
        guard unsaved == 0 else {
            throw AppError(message: "Failed to save \(unsaved) Spark activities", debugMessage: nil)
        }
    }

    /// The payments a refresh writes again: those whose last write failed, and sends recorded before Spark knew the fee
    /// it now reports.
    nonisolated static func paymentsToRecordAgain(
        _ payments: [Payment],
        unsaved: Set<String>,
        recordedWithoutFee: Set<String>
    ) -> [Payment] {
        payments.filter { unsaved.contains($0.id) || (recordedWithoutFee.contains($0.id) && sats($0.fees) > 0) }
    }

    private func onSdkEvent(_ event: SdkEvent) async {
        switch event {
        case .synced:
            syncedThisRun = true
            await LightningService.shared.listRailSendsIfUnseeded()
            await refreshState()
            await Self.settleAfterSync(
                since: Self.pendingContactWithdrawal?.startedAt ?? 0,
                hasSynced: { await self.hasSynced(after: $0) },
                settle: { await self.settleContactWithdrawal(allowClear: $0) }
            )
        case .newDeposits, .claimedDeposits:
            await refreshState()
        case let .unclaimedDeposits(deposits):
            Logger.warn("Found '\(deposits.count)' unclaimed Spark deposits", context: "SparkManager")
        case let .paymentSucceeded(payment), let .paymentFailed(payment):
            await Self.handleSettledPayment(
                payment,
                record: { await self.recordActivity($0) },
                emit: { LightningService.shared.emitChannelFreeRailEvent($0) },
                refresh: { try await self.refresh() }
            )
        case let .paymentPending(payment):
            await recordActivity(payment)
        case .unilateralExitStateChanged:
            Self.notifyExitStateChanged()
        case let .autoOptimization(optimizationEvent):
            noteOptimization(optimizationEvent)
        default:
            break
        }
    }

    /// Records a settled payment and delivers its node event before reading the balance again, so a failed read
    /// never drops the payment the send and receive flows wait for.
    static func handleSettledPayment(
        _ payment: Payment,
        record: (Payment) async -> Void,
        emit: (Event) -> Void,
        refresh: () async throws -> Void
    ) async {
        await record(payment)
        if let event = nodeEvent(for: payment) {
            emit(event)
        }
        do {
            try await refresh()
        } catch {
            Logger.warn("Failed to refresh Spark after payment '\(payment.id)': \(error)", context: "SparkManager")
        }
    }

    /// Returns whether the payment's activity is saved; a failed write is kept in `unsavedPayments` for the next refresh.
    @discardableResult
    private func recordActivity(_ payment: Payment) async -> Bool {
        guard case let .lightning(description, invoice, _, htlcDetails, _, _, _, _) = payment.details else { return true }
        let details = PaymentDetails(
            id: htlcDetails.paymentHash,
            kind: .bolt11(
                hash: htlcDetails.paymentHash,
                preimage: htlcDetails.preimage,
                secret: nil,
                description: description,
                bolt11: invoice
            ),
            amountMsat: Self.sats(payment.amount) * 1000,
            feePaidMsat: Self.sats(payment.fees) * 1000,
            direction: payment.paymentType == .send ? .outbound : .inbound,
            status: Self.ldkStatus(payment.status),
            latestUpdateTimestamp: payment.timestamp
        )
        if payment.paymentType == .send, Self.sats(payment.fees) == 0 {
            sendsRecordedWithoutFee.insert(payment.id)
        } else {
            sendsRecordedWithoutFee.remove(payment.id)
        }
        do {
            try await CoreService.shared.activity.recordChannelFreeRailPayment(details)
            unsavedPayments.remove(payment.id)
            return true
        } catch {
            Logger.error("Failed to record Spark payment '\(payment.id)': \(error)", context: "SparkManager")
            unsavedPayments.insert(payment.id)
            return false
        }
    }

    static func nodeEvent(for payment: Payment) -> Event? {
        guard case let .lightning(_, _, _, htlcDetails, _, _, _, _) = payment.details else { return nil }
        let hash = htlcDetails.paymentHash
        switch (payment.paymentType, payment.status) {
        case (.receive, .completed):
            return .paymentReceived(paymentId: hash, paymentHash: hash, amountMsat: sats(payment.amount) * 1000, customRecords: [])
        case (.send, .completed):
            return .paymentSuccessful(
                paymentId: hash,
                paymentHash: hash,
                paymentPreimage: htlcDetails.preimage,
                feePaidMsat: sats(payment.fees) * 1000
            )
        case (.send, .failed):
            return .paymentFailed(paymentId: hash, paymentHash: hash, reason: .unexpectedError)
        default:
            return nil
        }
    }

    private nonisolated static func ldkStatus(_ status: BreezSdkSpark.PaymentStatus) -> LDKNode.PaymentStatus {
        switch status {
        case .completed: .succeeded
        case .pending: .pending
        case .failed: .failed
        }
    }

    private nonisolated static func sats(_ value: U128) -> UInt64 {
        guard let sats = UInt64(value.description) else {
            Logger.error("Spark amount '\(value)' does not fit in sats", context: "SparkManager")
            return 0
        }
        return sats
    }
}

/// An on-chain deposit into Spark: pending until Spark claims it after 3 confirmations.
struct SparkDeposit: Identifiable, Equatable {
    let txid: String
    let amountSats: UInt64
    let isClaimed: Bool
    var feeSats: UInt64 = 0
    var claimedAt: UInt64?
    /// On-chain confirmations, known for deposits this wallet sent.
    var confirmations: UInt32?
    /// Whether Spark lists it, rather than only the app that just broadcast it.
    var isListed = true

    var id: String {
        "\(txid)-\(isClaimed)"
    }
}

extension [SparkDeposit] {
    /// The deposit whose progress the transfer banner opens: the first one Spark has not claimed yet.
    var inProgressTxid: String? {
        first { !$0.isClaimed }?.txid
    }
}

/// How a deposit into Spark can be claimed. The provider decides per deposit whether to credit it early, at 0
/// confirmations or 1-2, for a fee above the standard claim's at 3 confirmations.
struct SparkClaimOffer: Equatable {
    enum Kind: Equatable {
        /// No early claim is offered, so Spark claims it at `confirmations` for `feeSats`.
        case standard(feeSats: UInt64, confirmations: UInt32)
        /// The early claim fits this wallet's fee cap, so Spark claims it at `confirmations` by itself.
        case automatic(feeSats: UInt64, confirmations: UInt32)
        /// The early claim costs more than the cap, so it waits for the user to accept `earlyFeeSats`.
        case choice(earlyFeeSats: UInt64, earlyConfirmations: UInt32, standardFeeSats: UInt64, standardConfirmations: UInt32)
    }

    let txid: String
    let vout: UInt32
    var kind: Kind

    init(txid: String, vout: UInt32, kind: Kind) {
        self.txid = txid
        self.vout = vout
        self.kind = kind
    }

    init(txid: String, vout: UInt32, quote: FetchClaimDepositQuoteResponse) {
        let mature = quote.mature
        let kind: Kind = if let early = quote.instant {
            if let cap = early.maxFeeSats, early.feeSats <= cap {
                .automatic(feeSats: early.feeSats, confirmations: early.confirmationsRequired)
            } else {
                .choice(
                    earlyFeeSats: early.feeSats,
                    earlyConfirmations: early.confirmationsRequired,
                    standardFeeSats: mature.feeSats,
                    standardConfirmations: mature.confirmationsRequired
                )
            }
        } else {
            .standard(feeSats: mature.feeSats, confirmations: mature.confirmationsRequired)
        }
        self.init(txid: txid, vout: vout, kind: kind)
    }
}

/// What claiming a deposit costs: at most `instantMaxSats` to add it before confirmations, about `laterSats` to add it
/// after 3 confirmations.
struct SparkClaimFees: Equatable {
    let instantMaxSats: UInt64
    let laterSats: UInt64
}

/// What accepting an early claim did.
enum SparkEarlyClaim: Equatable {
    /// The claim settled, so the deposit is in the balance.
    case claimed
    /// The claim is submitted and Spark adds the deposit to the balance once it settles.
    case submitted
    /// Not offered at this depth yet; Spark claims it early once a confirmation brings the offer.
    case waiting
    /// The provider now asks `requiredFeeSats`, more than was accepted.
    case repriced(requiredFeeSats: UInt64)
    /// The provider declined it, so Spark claims the deposit at 3 confirmations.
    case declined

    init(_ outcome: ClaimDepositOutcome) {
        switch outcome {
        case .settled:
            self = .claimed
        case .submitted:
            self = .submitted
        case let .deferred(reason):
            switch reason {
            case .noEarlyClaimAvailable: self = .waiting
            case let .maxFeeExceeded(requiredFeeSats, _): self = .repriced(requiredFeeSats: requiredFeeSats)
            case .providerDeclined: self = .declined
            }
        }
    }
}

/// A Transfer to Savings out of Spark, with what Spark kept for it.
/// A withdrawal quote the provider issued; it holds for the same address and balance until shortly before it expires,
/// so it can't expire mid-send. An estimate, which no provider issued, expires at 0 and never holds.
struct SparkWithdrawalQuote: Equatable {
    static let expiryMarginSecs: UInt64 = 30

    let address: String
    let balanceSats: UInt64
    let expiresAt: UInt64

    func holds(address: String, balanceSats: UInt64, now: UInt64) -> Bool {
        self.address == address && self.balanceSats == balanceSats && expiresAt > now + Self.expiryMarginSecs
    }
}

/// The withdrawal now costs more than the confirm screen showed, so nothing was sent.
struct SparkWithdrawalFeeIncreased: LocalizedError, Equatable {
    let feeSats: UInt64
    let shownFeeSats: UInt64

    var errorDescription: String? {
        t("lightning__spending_confirm__fees_changed_title")
    }
}

/// User copy for a Spark failure; the SDK's own text goes to the log only.
enum SparkErrorCopy {
    static func message(for error: Error, fallback: String) -> String {
        switch error {
        case let refused as ChannelFreeRailSendRefused:
            return refused.reason
        case let appError as AppError where !appError.isGeneric:
            return t(appError.message)
        case SdkError.InsufficientFunds:
            return t("other__pay_insufficient_spending_description")
        case SdkError.NetworkError, SdkError.ChainServiceError:
            return t("hardware__send_broadcast_failed_text")
        default:
            return fallback
        }
    }
}

/// A Spark withdrawal to a contact's on-chain address, journaled before it is sent.
/// A contact withdrawal refused before its journal was written: nothing was sent.
enum SparkWithdrawalSettlement: Equatable {
    /// Paid: its records are saved and its journal closes.
    case record
    /// Never paid: its journal closes as unsent, releasing what it started.
    case closeUnsent
    /// Still in flight: its journal stays open until Spark settles it.
    case wait
}

struct SparkWithdrawalNotSent: Error {
    let underlying: Error
}

/// Spark's balance can't cover a contact withdrawal's amount and fee, so the route offers no Spark leg.
struct SparkLegUnaffordable: Error {
    let debitSats: UInt64
    let balanceSats: UInt64
}

struct SparkContactWithdrawal: Codable, Equatable {
    /// The Paykit request a withdrawal pays, and the identity its proof belongs to.
    struct PaykitRequest: Codable, Equatable {
        let id: PaykitPaymentRequest.ID
        let identity: String
        /// The contact's private list the request consumed, given back when the withdrawal never started its proof.
        var paymentList: PaymentList?
    }

    /// A private payment list version a send consumed, and the one before it.
    struct PaymentList: Codable, Equatable {
        let version: UInt64
        let previousVersion: UInt64?
    }

    let address: String
    let amountSats: UInt64
    let contact: String?
    let startedAt: UInt64
    var request: PaykitRequest?
    /// Tags picked on Confirm, saved on the sent activity.
    var tags: [String]?
    /// Withdrawals to the same address and amount Spark listed before this attempt; recovery skips them.
    var earlierPaymentIds: [String]?
    /// This attempt's Spark payment, once Spark returned it.
    var paymentId: String?
    /// The UUID the send passed as its idempotency key, which Spark keeps as the payment's id.
    var idempotencyKey: String?
}

/// One contact withdrawal, which a pending send screen follows until its journal closes.
struct SparkWithdrawalAttempt: Hashable {
    let address: String
    let amountSats: UInt64
    let requestId: PaykitPaymentRequest.ID?
}

/// How a contact withdrawal's journal closed: sent with its txid, or never sent when `txId` is nil.
struct SparkContactWithdrawalResolution: Equatable {
    let attempt: SparkWithdrawalAttempt
    let txId: String?
}

extension SparkContactWithdrawal {
    var attempt: SparkWithdrawalAttempt {
        SparkWithdrawalAttempt(address: address, amountSats: amountSats, requestId: request?.id)
    }
}

struct SparkWithdrawal: Identifiable, Equatable {
    let txid: String
    let amountSats: UInt64
    let feeSats: UInt64

    var id: String {
        txid
    }
}

struct BreezSparkExitRecovering: SparkExitRecovering {
    let sdk: BreezSdk

    func prepare(_ request: PrepareRecoverFundsRequest) async throws -> PrepareRecoverFundsResponse {
        try await sdk.prepareRecoverFunds(request: request)
    }

    func recover(_ request: RecoverFundsRequest, signer: CpfpSigner?) async throws -> RecoverFundsResponse {
        try await sdk.recoverFunds(request: request, signer: signer)
    }

    func check(_ recovery: RecoverFundsResponse) async throws -> CheckRecoverFundsResponse {
        try await sdk.checkRecoverFunds(request: CheckRecoverFundsRequest(recovery: recovery))
    }

    func exportExitState() async throws -> String {
        try await sdk.exportUnilateralExitState().exitState
    }

    func importExitState(_ exitState: String) async throws {
        let imported = try await sdk.importUnilateralExitState(request: ImportUnilateralExitStateRequest(exitState: exitState))
        Logger.info(
            "Imported the Spark exit's own exit data: '\(imported.importedLeaves)' leaves, '\(imported.skippedForeignLeaves)' foreign, "
                + "'\(imported.skippedConflictingLeaves)' conflicting, '\(imported.skippedChains)' already held",
            context: "SparkManager"
        )
    }
}

private final class SparkEventListener: BreezSdkSpark.EventListener, @unchecked Sendable {
    private let handler: @Sendable (SdkEvent) async -> Void

    init(handler: @escaping @Sendable (SdkEvent) async -> Void) {
        self.handler = handler
    }

    func onEvent(event: SdkEvent) async {
        await handler(event)
    }
}

/// The Spark sends and withdrawals past their exit check. An exit holds Spark before it waits for them, so every later
/// one refuses, and it quotes the leaves they leave once they end.
@MainActor
final class SparkSpends {
    private let isExiting: () -> Bool
    private(set) var inFlight = 0
    /// An exit start holds Spark while it waits for the sends, before its record exists.
    private(set) var isHeld = false

    init(isExiting: @escaping () -> Bool) {
        self.isExiting = isExiting
    }

    /// Runs `send` counted, unless an exit holds Spark. Called after the send's last await but the one inside `send`,
    /// so an exit starting meanwhile either refuses it here or waits for it.
    func run<T>(_ send: () async throws -> T) async throws -> T {
        guard !isExiting(), !isHeld else {
            Logger.info("Refused a Spark send: an emergency exit holds Spark", context: "SparkManager")
            throw ChannelFreeRailSendRefused(reason: t("wallet__payment_failed_description"))
        }
        inFlight += 1
        defer { inFlight -= 1 }
        return try await send()
    }

    /// Holds Spark for an exit start and waits for the counted sends to end, for up to `timeout`. Throws, and lets go,
    /// when one is still sending then: the exit must not start while a send can spend its leaves, and the user starts
    /// it again once the send ended. The start lets go (`release`) once its record holds Spark.
    func holdForExit(timeout: TimeInterval) async throws {
        isHeld = true
        let deadline = Date().addingTimeInterval(timeout)
        while inFlight > 0, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if inFlight > 0 {
            Logger.warn("Gave up waiting for Spark sends in flight to end", context: "SparkManager")
            isHeld = false
            throw AppError(message: t("other__try_again"), debugMessage: "A Spark payment is still sending")
        }
    }

    func release() {
        isHeld = false
    }
}

/// Lets the first of two racing tasks resume a continuation, once.
private final class SparkFirstResume: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { isClaimed = true }
            return !isClaimed
        }
    }
}

/// The balances a refresh reads: what Spark read (`readSats`), the balance kept on screen, and pending deposits.
struct SparkBalances: Equatable {
    let readSats: UInt64
    let keptSats: UInt64?
    let pendingSats: UInt64
}
