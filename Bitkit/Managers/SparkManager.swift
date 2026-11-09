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
    private nonisolated(unsafe) static let exitStateChanged = PassthroughSubject<Void, Never>()
    /// Fires once Spark connects and whenever its unilateral exit data changes, so the exit data backup is redone.
    nonisolated static var exitStateChangedPublisher: AnyPublisher<Void, Never> {
        exitStateChanged.eraseToAnyPublisher()
    }

    private nonisolated static let depositClaimFeeLeewaySatPerVbyte: UInt64 = 2
    private nonisolated static let depositClaimFeePpm: UInt32 = 2000

    private(set) var isReady = false
    private(set) var walletIndex = 0
    private(set) var balanceSats: UInt64 = 0
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
    @ObservationIgnored private var sdk: BreezSdk?
    /// The last withdrawal quote, which the withdrawal reuses while it holds.
    @ObservationIgnored private var preparedWithdrawal: (quote: SparkWithdrawalQuote, response: PrepareSendPaymentResponse)?
    /// Withdrawals this app sent, known before Spark lists them.
    @ObservationIgnored private var sentWithdrawalTxIds: Set<String> = []
    @ObservationIgnored private var listenerId: String?
    @ObservationIgnored private var connectTask: Task<Void, Error>?
    /// A leaf optimization is running, as its events tell.
    @ObservationIgnored private var isOptimizing = false
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
    /// The refresh in flight; callers during it wait for it, and it reads once more for them.
    @ObservationIgnored private var refreshTask: Task<Void, Error>?
    @ObservationIgnored private var refreshAgain = false
    /// Set once a full activity sync succeeded in this process; `wipe` clears it.
    @ObservationIgnored private var activitiesSynced = false

    private init() {}

    var isSupported: Bool {
        Self.sparkNetwork != nil
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

    /// Connects Spark again so its leaf optimization follows whether an exit runs: off when one starts, back on
    /// once it ends.
    func reconnectForExit() async {
        guard let network = Self.sparkNetwork else { return }
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
            try await connect(walletIndex: walletIndex, network: network, generation: connectGeneration)
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

    /// Counts connects in this process, nil while disconnected, so a backup can tell a new connection from observing
    /// that restarted while Spark stayed connected.
    var connectionId: Int? {
        sdk == nil ? nil : connectionCount
    }

    @ObservationIgnored private var connectionCount = 0

    /// Spark's regtest has no Lightning network, so there a Lightning invoice from another Spark wallet is paid as a
    /// Spark transfer, which lets two dev builds pay each other's invoices.
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
        guard let network = Self.sparkNetwork else { return }
        self.walletIndex = walletIndex
        SparkExitManager.shared.load(walletIndex: walletIndex)
        do {
            if sdk == nil {
                if connectTask == nil {
                    let generation = connectGeneration
                    connectTask = Task { try await connect(walletIndex: walletIndex, network: network, generation: generation) }
                }
                try await connectTask?.value
                connectTask = nil
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
                syncActivities: { try await syncActivities() }
            )
        } catch {
            connectTask = nil
            Logger.error("Failed to start Spark wallet: \(error)", context: "SparkManager")
        }
    }

    /// A start reads the balance every time, but rewrites every Spark activity only until that has succeeded once, so
    /// each foreground doesn't redo it; a start whose refresh failed leaves the sync to the next one. Returns whether
    /// the activities are synced.
    static func startConnected(
        activitiesSynced: Bool,
        refresh: () async throws -> Void,
        syncActivities: () async throws -> Void
    ) async throws -> Bool {
        try await refresh()
        guard !activitiesSynced else { return true }
        try await syncActivities()
        return true
    }

    private func connect(walletIndex: Int, network: BreezSdkSpark.Network, generation: Int) async throws {
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
        let connected = try await builder.build()
        guard generation == connectGeneration else {
            try? await connected.disconnect()
            throw CancellationError()
        }
        listenerId = await connected.addEventListener(listener: SparkEventListener { [weak self] event in
            await self?.onSdkEvent(event)
        })
        sdk = connected
        connectionCount += 1
        Logger.info("Connected Spark wallet on '\(network)'", context: "SparkManager")
        await importRestoredExitState(walletIndex: walletIndex)
        Self.exitStateChanged.send()
    }

    /// The SDK config Bitkit connects with.
    nonisolated static func sdkConfig(network: BreezSdkSpark.Network, apiKey: String?, isExiting: Bool) -> BreezSdkSpark.Config {
        var config = defaultConfig(network: network)
        config.apiKey = apiKey
        // No Breez data sync server and no Lightning address server: Bitkit uses neither.
        config.realTimeSyncServerUrl = nil
        config.lnurlDomain = nil
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
        connectGeneration += 1
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
        await SparkExitManager.shared.wipe()
        balanceSats = 0
        pendingDepositSats = 0
        recoverableFundsSats = 0
        deposits = []
        withdrawals = []
        broadcastDeposits = [:]
        sendsRecordedWithoutFee = []
        sentWithdrawalTxIds = []
        preparedWithdrawal = nil
        onStateChanged?()
        try Self.removeIfPresent(Env.sparkStorage(walletIndex: walletIndex))
        try Self.removeIfPresent(Env.sparkExitRestore(walletIndex: walletIndex))
        if let disconnectError {
            throw disconnectError
        }
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
    /// stays uncertain, as the payment may have been dispatched.
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
        // A deadline that passed while the quote was prepared stops the payment here, before anything leaves.
        try beforeSubmission()
        let response: SendPaymentResponse
        do {
            response = try await sdk.sendPayment(request: SendPaymentRequest(
                prepareResponse: prepared,
                options: Self.bolt11SendOptions
            ))
        } catch {
            // The SDK checks the expiry again before sending, so an invoice that expired on the confirm screen left nothing.
            throw Self.expiredInvoiceRefusal(error) ?? error
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

    /// The SDK refuses an expired Lightning invoice before anything leaves the wallet, with the scanner's expiry copy.
    nonisolated static func expiredInvoiceRefusal(_ error: Error) -> ChannelFreeRailSendRefused? {
        guard case let SdkError.InvalidInput(message) = error, message.localizedCaseInsensitiveContains("invoice has expired") else { return nil }
        return ChannelFreeRailSendRefused(reason: t("other__scan__error__expired"))
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
            claim = .claimed
        }
        Logger.info("Early claim of Spark deposit \(offer.txid): \(claim)", context: "SparkManager")
        await refreshState()
        return claim
    }

    /// Moves the whole Spark balance to the on-chain `address`, fees included, for Spending to Savings. Refuses before
    /// sending when the fee is above `maxFeeSats`, the fee the confirm screen showed.
    func withdrawAll(to address: String, maxFeeSats: UInt64) async throws {
        let prepared = try await prepareWithdrawAll(to: address)
        try Self.checkWithdrawalFee(Self.withdrawalFeeSats(prepared), shownFeeSats: maxFeeSats)
        let response = try await requireSdk().sendPayment(request: SendPaymentRequest(
            prepareResponse: prepared,
            options: .bitcoinAddress(confirmationSpeed: .medium)
        ))
        preparedWithdrawal = nil
        if case let .withdraw(txId, _, _) = response.payment.details {
            sentWithdrawalTxIds.insert(txId)
        }
        try await Self.settleWithdrawal(status: response.payment.status) { try await self.refresh() }
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
            .map { SparkDeposit(txid: $0.key, amountSats: $0.value, isClaimed: false, confirmations: 0) }
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
        let unclaimed = try await sdk.listUnclaimedDeposits(request: ListUnclaimedDepositsRequest()).deposits
        let payments = try await sdk.listPayments(request: ListPaymentsRequest()).payments
        let claimed = payments.filter { $0.method == .deposit && $0.status == .completed }
        let listedDeposits = await Self.deposits(unclaimed: unclaimed, claimed: claimed)
        // A wipe while this read was in flight leaves the state it cleared.
        guard self.sdk === sdk else { return }
        let pending = unclaimed.reduce(0) { $0 + $1.amountSats }
        let changed = !isReady || balanceSats != info.balanceSats || pendingDepositSats != pending
        isReady = true
        balanceSats = info.balanceSats
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
        for payment in payments where sendsRecordedWithoutFee.contains(payment.id) && Self.sats(payment.fees) > 0 {
            await recordActivity(payment)
        }
        for txId in Self.transferTxIds(unclaimed: unclaimed, payments: payments) {
            await CoreService.shared.activity.markOnchainActivityAsTransfer(txId: txId)
        }
    }

    nonisolated static func withdrawals(_ payments: [Payment]) -> [SparkWithdrawal] {
        payments.compactMap { payment in
            guard payment.status != .failed, case let .withdraw(txId, _, _) = payment.details else { return nil }
            return SparkWithdrawal(txid: txId, amountSats: sats(payment.amount), feeSats: sats(payment.fees))
        }
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
        for payment in payments {
            await recordActivity(payment)
        }
        // A send that failed while the app was closed released no hold on a channel retry.
        for paymentHash in Self.failedSendHashes(payments) {
            LightningService.shared.releaseRailAttempt(paymentHash: paymentHash)
        }
    }

    private func onSdkEvent(_ event: SdkEvent) async {
        switch event {
        case .synced, .newDeposits, .claimedDeposits:
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
            Self.exitStateChanged.send()
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

    private func recordActivity(_ payment: Payment) async {
        guard case let .lightning(description, invoice, _, htlcDetails, _, _, _, _) = payment.details else { return }
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
        } catch {
            Logger.error("Failed to record Spark payment '\(payment.id)': \(error)", context: "SparkManager")
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

    var id: String {
        "\(txid)-\(isClaimed)"
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
    /// The claim is submitted and the deposit reaches the balance shortly.
    case claimed
    /// Not offered at this depth yet; Spark claims it early once a confirmation brings the offer.
    case waiting
    /// The provider now asks `requiredFeeSats`, more than was accepted.
    case repriced(requiredFeeSats: UInt64)
    /// The provider declined it, so Spark claims the deposit at 3 confirmations.
    case declined

    init(_ outcome: ClaimDepositOutcome) {
        switch outcome {
        case .settled, .submitted:
            self = .claimed
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
