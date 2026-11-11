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

    /// Fires once Spark connects and whenever its unilateral exit data changes, so the exit data backup is redone.
    nonisolated static var exitStateChangedPublisher: AnyPublisher<Void, Never> {
        exitStateChanged.eraseToAnyPublisher()
    }

    private nonisolated static let depositClaimFeeLeewaySatPerVbyte: UInt64 = 2
    private nonisolated static let depositClaimFeePpm: UInt32 = 2000

    private(set) var isReady = false
    /// What Spark read, which sends and withdrawals use.
    private(set) var balanceSats: UInt64 = 0
    /// The last balance shown, kept while Spark reads 0 after a failed withdrawal or a failed sync; display only.
    private(set) var keptBalanceSats: UInt64?
    /// The balance Home and the Spark connection show.
    var shownBalanceSats: UInt64 {
        keptBalanceSats ?? balanceSats
    }

    /// Deposits seen on-chain that Spark claims into `balanceSats` after 3 confirmations.
    private(set) var pendingDepositSats: UInt64 = 0
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
    @ObservationIgnored private var listenerId: String?
    @ObservationIgnored private var connectTask: Task<Void, Error>?
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
        guard let network = Self.sparkNetwork else { return }
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
            // still go to LDK, even when that refresh or the activity sync fails.
            LightningService.shared.channelFreeRail = self
            activitiesSynced = try await Self.startConnected(
                activitiesSynced: activitiesSynced,
                refresh: { try await refresh() },
                syncWallet: {
                    _ = try await requireSdk().syncWallet(request: SyncWalletRequest())
                    syncedThisRun = true
                },
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
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        let config = Self.sdkConfig(network: network, apiKey: Env.breezApiKey)
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
        guard generation == connectGeneration else {
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
    nonisolated static func sdkConfig(network: BreezSdkSpark.Network, apiKey: String?) -> BreezSdkSpark.Config {
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
        return config
    }

    /// Disconnects and deletes this wallet's Spark data. A connect still running is waited for first, so it can't
    /// keep the wiped wallet; throws when the data could not be deleted, so the wipe is retried.
    func wipe(walletIndex: Int) async throws {
        connectGeneration += 1
        syncedThisRun = false
        if let connectTask {
            _ = try? await connectTask.value
        }
        connectTask = nil
        if LightningService.shared.channelFreeRail === self {
            LightningService.shared.channelFreeRail = nil
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
        balanceSats = 0
        keptBalanceSats = nil
        withdrawalFailedAt = nil
        pendingDepositSats = 0
        deposits = []
        withdrawals = []
        broadcastDeposits = [:]
        sendsRecordedWithoutFee = []
        unsavedPayments = []
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
        // A deadline that passed while the quote was prepared stops the payment here, before anything leaves.
        try beforeSubmission()
        let response: SendPaymentResponse
        do {
            response = try await sdk.sendPayment(request: SendPaymentRequest(
                prepareResponse: prepared,
                options: Self.bolt11SendOptions
            ))
        } catch {
            throw Self.sendPaymentFailure(error)
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
            let response = try await requireSdk().sendPayment(request: SendPaymentRequest(
                prepareResponse: prepared,
                options: .bitcoinAddress(confirmationSpeed: .medium)
            ))
            preparedWithdrawal = nil
            if case let .withdraw(txId, _, _) = response.payment.details {
                sentWithdrawalTxIds.insert(txId)
            }
            withdrawalFailedAt = response.payment.status == .failed ? Self.nowSecs() : nil
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
        let kept = Self.keptBalanceSats(
            read: info.balanceSats, lastShown: shownBalanceSats, isStale: withdrawalFailedAt != nil || info.lastSyncError != nil
        )
        let changed = !isReady || Self.balancesChanged(
            from: SparkBalances(readSats: balanceSats, keptSats: keptBalanceSats, pendingSats: pendingDepositSats),
            to: SparkBalances(readSats: info.balanceSats, keptSats: kept, pendingSats: pending)
        )
        isReady = true
        balanceSats = info.balanceSats
        keptBalanceSats = kept
        pendingDepositSats = pending
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
        for txId in Self.transferTxIds(unclaimed: unclaimed, payments: payments) {
            await CoreService.shared.activity.markOnchainActivityAsTransfer(txId: txId)
        }
    }

    /// Whether balances and the receive invoice must follow a refresh: the read balance counts too, as sends use it, and
    /// it can come back to the shown one while that stays the same.
    nonisolated static func balancesChanged(from old: SparkBalances, to new: SparkBalances) -> Bool {
        old != new
    }

    /// After a failed withdrawal, or while Spark's last sync failed (`isStale`), Spark can read 0 with the funds still
    /// there, so the last shown balance stays shown until it reads one again.
    nonisolated static func keptBalanceSats(read: UInt64, lastShown: UInt64, isStale: Bool) -> UInt64? {
        read == 0 && isStale && lastShown > 0 ? lastShown : nil
    }

    /// A failed withdrawal stops keeping the balance once Spark reads one, or reads 0 after a sync that ended after it.
    nonisolated static func withdrawalFailedAt(_ failedAt: UInt64?, read: UInt64, lastSyncedAt: UInt64?, syncFailed: Bool) -> UInt64? {
        guard let failedAt, read == 0, syncFailed || (lastSyncedAt ?? 0) <= failedAt else { return nil }
        return failedAt
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
            await refreshState()
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

struct SparkWithdrawal: Identifiable, Equatable {
    let txid: String
    let amountSats: UInt64
    let feeSats: UInt64

    var id: String {
        txid
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

/// The balances a refresh reads: what Spark read (`readSats`), the balance kept on screen, and pending deposits.
struct SparkBalances: Equatable {
    let readSats: UInt64
    let keptSats: UInt64?
    let pendingSats: UInt64
}
