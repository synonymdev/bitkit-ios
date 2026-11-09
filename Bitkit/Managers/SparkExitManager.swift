import BackgroundTasks
import BitkitCore
import BreezSdkSpark
import Foundation
import LDKNode
import Observation
import UserNotifications

/// Runs a Spark emergency exit: the quote, the fee funding, then the driver until every step is on-chain. The exit
/// survives restarts through `SparkExitStore`, and is driven while Bitkit is open and by background runs while it
/// is closed (`BGAppRefreshTask` and `BGProcessingTask`, Spark SDK only). Reminders, scheduled ahead of each step,
/// bring the user back when those runs do not get to a step in time.
@Observable @MainActor
final class SparkExitManager {
    static let shared = SparkExitManager()
    nonisolated static let backgroundTaskId = "to.bitkit.spark-exit"
    nonisolated static let processingTaskId = "to.bitkit.spark-exit.processing"
    private nonisolated static let notificationPrefix = "spark-exit"
    /// Reminder ids with their fire dates, so one that fired is not posted again on the next run.
    private nonisolated static let remindersKey = "sparkExitReminders"
    private nonisolated static let walletIndexKey = "sparkExitWalletIndex"
    /// The `bitkit_action` of the exit's notifications, so tapping one opens the exit.
    nonisolated static let notificationAction = "spark_exit"
    private static let foregroundTickSeconds: UInt64 = 60

    private(set) var record: SparkExitRecord?
    private(set) var quote: SparkExitQuote?
    private(set) var quoteError: String?
    private(set) var isQuoting = false
    private(set) var tipHeight: UInt32?
    /// Confirmed or not, what reached the funding address and is not a funding input yet.
    private(set) var fundingSeenSats: UInt64 = 0
    /// How many payments make up `fundingSeenSats` on the pre-start funding screen.
    private(set) var fundingSeenCount = 0
    /// The network's rates now, read on every tick: the SDK's recommendation, or the chain host's without the SDK.
    private(set) var networkFees: SparkExitNetworkFees?
    /// The higher rates a fee bump offers, priced against the running exit.
    private(set) var feeBumpOptions: [SparkExitFeeBumpOption] = []
    private(set) var isPricingFeeBump = false
    private(set) var feeBumpError: String?
    /// What the running exit shows about its fee funding while it lacks some.
    var fundingState: SparkExitFundingState? {
        Self.isFundingOfExit(fundingExitCreatedAt, record: record) ? storedFundingState : nil
    }

    /// The full funding the Progress top-up asks for, every extra payment's input fee included.
    var fundingAskTotal: UInt64? {
        Self.isFundingOfExit(fundingExitCreatedAt, record: record) ? storedFundingAskTotal : nil
    }

    private var storedFundingState: SparkExitFundingState?
    private var storedFundingAskTotal: UInt64?
    /// The exit `fundingState` and `fundingAskTotal` were read for.
    private var fundingExitCreatedAt: Date?
    private(set) var fundingAddress: String?
    private(set) var lastError: String?
    /// Set when the user tapped an exit notification, until the app shows the exit.
    var opensProgress = false

    /// The funding choice made on the funding screen, used when the exit starts.
    @ObservationIgnored var fundFromSavings = false
    @ObservationIgnored var savingsFeeRate: UInt32 = 0
    @ObservationIgnored var savingsFeeSats: UInt64 = 0
    @ObservationIgnored private var walletIndex = 0
    @ObservationIgnored private var isTicking = false
    /// The exit a start is still settling: no tick or background run drives it until its optimization wait, requote
    /// and reconnect end, since optimization may still swap the leaves it exits.
    @ObservationIgnored private var startingCreatedAt: Date?
    @ObservationIgnored private(set) var pendingDestination: String?
    @ObservationIgnored private var pendingFeeRate: UInt64?
    @ObservationIgnored private(set) var pendingFundingIndex: UInt32?

    /// The app uses `shared`; tests make their own, on a wallet index no wallet uses.
    init(walletIndex: Int = 0) {
        self.walletIndex = walletIndex
    }

    /// The fee rate of the quote on screen.
    var quoteFeeRate: UInt64? {
        pendingFeeRate
    }

    /// What paying the fee funding from savings costs: that payment's own fee, and the total that leaves savings. Nil
    /// when another wallet pays, or there is nothing to fund.
    var savingsPayment: (feeSats: UInt64, totalSats: UInt64)? {
        guard fundFromSavings, let quote, quote.fundingSats > 0 else { return nil }
        return (savingsFeeSats, quote.fundingSats + savingsFeeSats)
    }

    var isExiting: Bool {
        record?.isActive == true
    }

    /// The exit runs, or its leftover fee funding is still on its way to savings.
    var needsDriving: Bool {
        record?.needsDriving == true
    }

    /// Emergency exit opens this exit's progress or result instead of a new exit.
    var showsResult: Bool {
        record?.showsResult == true
    }

    private var store: SparkExitStore {
        SparkExitStore(walletIndex: walletIndex)
    }

    private var lostLeafStore: SparkExitLostLeafStore {
        SparkExitLostLeafStore(walletIndex: walletIndex)
    }

    /// Saves the record, and keeps the leaves it lost to an older state for every later exit of the wallet. The lost-leaf
    /// list is best effort: it never fails the save the driver relies on.
    private var saveRecord: (SparkExitRecord) throws -> Void {
        Self.gatedSave(store: store, lostLeafStore: lostLeafStore, gate: writeGate)
    }

    /// Writes from ticks and background runs, closed for good once the wallet is wiped: a tick still running then can
    /// never write the deleted exit back.
    @ObservationIgnored private var writeGate = SparkExitWriteGate()

    nonisolated static func gatedSave(
        store: SparkExitStore,
        lostLeafStore: SparkExitLostLeafStore,
        gate: SparkExitWriteGate
    ) -> (SparkExitRecord) throws -> Void {
        {
            guard gate.isOpen else { throw SparkExitWriteGate.Closed() }
            try store.save($0)
            do {
                try lostLeafStore.add(lostIn: $0)
            } catch {
                Logger.warn("Failed to keep the Spark exit's lost leaves: \(error)", context: "SparkExitManager")
            }
        }
    }

    private var chain: SparkExitChain? {
        guard let network = SparkManager.exitNetwork else { return nil }
        return EsploraSparkExitChain.network(network)
    }

    // MARK: Lifecycle

    func load(walletIndex: Int) {
        self.walletIndex = walletIndex
        do {
            record = try Self.loadRecord(store: store, lostLeafStore: lostLeafStore)
        } catch is SparkExitStore.Unavailable {
            // Before the first unlock the file is there but cannot be read yet: it is read again on the next load.
            Logger.warn("The Spark exit record cannot be read yet", context: "SparkExitManager")
            record = nil
        } catch {
            // Names no active exit it could rebuild: kept aside for support, so a new exit never overwrites it.
            Logger.error("Failed to read the Spark exit record: \(error)", context: "SparkExitManager")
            try? store.setAside()
            record = nil
        }
        if isExiting {
            SparkManager.shared.detachForExit()
        }
        let record = record
        Task {
            if let record {
                await settleIfFinished(record)
            }
            await settleOrphanedTransfers(record)
        }
    }

    /// Loads the stored exit and adds its lost leaves to the lost-leaf list, ended exits included, so leaves an exit
    /// lost before that list existed stay out of the next quote too.
    /// A record of an unknown version, or one that does not decode, is not forgotten while it names an active exit:
    /// what it still tells is kept, the exit rebuilds from the chain with its funding, and the original stays aside.
    nonisolated static func loadRecord(store: SparkExitStore, lostLeafStore: SparkExitLostLeafStore) throws -> SparkExitRecord? {
        guard let data = try store.loadData() else { return nil }
        let record: SparkExitRecord
        do {
            record = try SparkExitRecordCoder.decode(data)
        } catch {
            guard let salvaged = SparkExitRecordCoder.salvage(data) else { throw error }
            Logger.warn("Rebuilding the Spark exit from the chain, its record could not be read: \(error)", context: "SparkExitManager")
            // The original is copied aside first and the salvaged record then replaces it in one write.
            try store.keepCopyAside()
            try store.save(salvaged)
            record = salvaged
        }
        try? lostLeafStore.add(lostIn: record)
        return record
    }

    /// Forgets the exit of a wallet being wiped: closes the writes of any tick still running, waits for it to stop, then
    /// deletes the record, so the exit can't come back.
    func wipe() async {
        writeGate.close()
        while isTicking {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        writeGate = SparkExitWriteGate()
        try? store.delete()
        try? lostLeafStore.delete()
        record = nil
        quote = nil
        // The quote's destination and funding belong to the wiped wallet: the next wallet's exit never pays to them.
        pendingDestination = nil
        pendingFeeRate = nil
        pendingFundingIndex = nil
        fundingAddress = nil
        fundFromSavings = false
        savingsFeeRate = 0
        savingsFeeSats = 0
        fundingSeenSats = 0
        fundingSeenCount = 0
        Self.clearReminders()
    }

    /// Stops an exit that has not built anything and whose funding address received nothing, so leaving it
    /// costs nothing: Spark comes back as it was.
    var canCancel: Bool {
        guard let record else { return false }
        return Self.canCancel(record, fundingSeenSats: fundingSeenSats, unresolvedSendAddress: unresolvedSendAddress)
    }

    /// The address of an unresolved savings send, read on every tick and before a cancel.
    private(set) var unresolvedSendAddress: String?
    /// The savings payment of the start that a node refused, read on every tick: progress says so and offers to pay
    /// again.
    private(set) var refusedSavingsPayment: OnchainSendAttempt?

    var isSavingsPaymentRefused: Bool {
        record.map { Self.isSavingsPaymentRefused($0, attempt: refusedSavingsPayment) } ?? false
    }

    /// A node refused the savings payment of `record`'s fee funding, and none was adopted since: only before the exit
    /// is funded, for the payment the start made.
    nonisolated static func isSavingsPaymentRefused(_ record: SparkExitRecord, attempt: OnchainSendAttempt?) -> Bool {
        guard record.isActive, case .awaitingFunding = record.phase, record.fundingPaymentTxid == nil,
              let address = record.funding.first?.address, let attempt
        else { return false }
        return attempt.address == address && attempt.status == .rejected
    }

    /// Pays a refused savings payment again: the same attempt, re-signed at the rate the user approved over the inputs
    /// it already spends. Every version spends those inputs, so at most one ever confirms, and nothing waits for the
    /// refused one to be known gone from the mempool first. The txid to wait for, or nil when it was refused again.
    nonisolated static func payRefusedAgain(
        _ refused: OnchainSendAttempt,
        record: SparkExitRecord,
        retrySamePayment: (OnchainSendPendingContext) async throws -> OnchainSendResult
    ) async throws -> String? {
        guard isSavingsPaymentRefused(record, attempt: refused), refused.canRetrySamePayment else {
            throw OnchainSendAttemptError.unresolved
        }
        let result = try await retrySamePayment(OnchainSendPendingContext(attemptId: refused.id, walletId: refused.walletId, txid: refused.txid))
        return fundingTxid(result)
    }

    func retrySavingsPayment() async throws {
        // Under the ticks' lock from the check to the saved txid, as the start's payment: a cancel either ends the exit
        // before savings pays again or finds the payment and refuses.
        while isTicking {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        isTicking = true
        defer { isTicking = false }
        if let stored = try? Self.loadRecord(store: store, lostLeafStore: lostLeafStore) {
            record = stored
        }
        guard let current = record, let refused = refusedSavingsPayment else { return }
        let attempts = OnchainSendAttemptService.shared
        let txid = try await Self.payRefusedAgain(refused, record: current) { context in
            try await attempts.retrySamePayment(using: LightningService.shared, context: context) { attempt, _ in
                guard attempt.id == refused.id, attempt.address == refused.address else { throw OnchainSendAttemptError.unresolved }
            }
        }
        await refreshRefusedSavingsPayment()
        guard let txid else {
            throw AppError(message: t("wallet__send_error_tx_failed"), debugMessage: "Spark exit savings payment refused again")
        }
        _ = try? await attempts.resumeAcceptedOrdinarySend(walletId: refused.walletId, observedTxid: txid)
        guard var paid = record, paid.createdAt == current.createdAt, paid.isActive else { return }
        paid.fundingPaymentTxid = txid
        try saveRecord(paid)
        record = paid
        setFunding(SparkExitMath.fundingState(paid, utxos: nil), for: paid)
        refusedSavingsPayment = nil
        Logger.info("Paid the Spark exit funding from savings again in \(txid)", context: "SparkExitManager")
        Task { await tick() }
    }

    private func refreshRefusedSavingsPayment() async {
        let attempt = try? await OnchainSendAttemptService.shared.blockingAttempt()
        refusedSavingsPayment = attempt?.status == .rejected ? attempt : nil
    }

    /// What the exit still brings to savings, for its own transfer's in-transfer amount; nil without one.
    var inTransfer: (transferId: String, sats: UInt64)? {
        guard let record, let transferId = record.transferId else { return nil }
        return (transferId, SparkExitMath.inTransferSats(record, fundingSeenSats: fundingSeenSats))
    }

    /// Nothing built, nothing paid from savings and nothing seen at the funding address, and no unresolved savings send
    /// to that address: such a send can still be retried from Send, always to the same address, which a forgotten exit
    /// would no longer watch.
    nonisolated static func canCancel(_ record: SparkExitRecord, fundingSeenSats: UInt64, unresolvedSendAddress: String? = nil) -> Bool {
        guard record.recovery == nil, record.fundedSats == 0, fundingSeenSats == 0, record.fundingPaymentTxid == nil else { return false }
        if let unresolvedSendAddress, record.funding.contains(where: { $0.address == unresolvedSendAddress }) {
            return false
        }
        if case .awaitingFunding = record.phase {
            return true
        }
        return false
    }

    enum CancelOutcome: Equatable {
        /// Nothing reached the funding address: the exit is forgotten and Spark comes back.
        case forget
        /// Funding reached it after all: the exit ends and sends that funding back to savings.
        case sweepFunding([SparkExitRecord.Leftover])
        /// The address could not be read: nothing changes.
        case keep
    }

    /// What cancelling does, given what the funding address holds now (nil when it could not be read).
    nonisolated static func cancelOutcome(utxos: [EsploraUtxo]?) -> CancelOutcome {
        guard let utxos else { return .keep }
        guard !utxos.isEmpty else { return .forget }
        return .sweepFunding(utxos.map { SparkExitRecord.Leftover(txid: $0.txid, vout: $0.vout, valueSats: $0.value) })
    }

    /// Notes that the user opened the result of an exit that failed or lost leaves, so Emergency exit starts a new
    /// one next time.
    func markResultSeen() {
        guard var record, record.hasUnseenResult else { return }
        record.isResultSeen = true
        do {
            try store.save(record)
            self.record = record
        } catch {
            Logger.error("Failed to save the seen Spark exit result: \(error)", context: "SparkExitManager")
        }
    }

    /// Reads the funding address first: a payment that arrived since the last tick is never orphaned. With funding there
    /// the record stays, ends as cancelled and its leftover sweep returns the funding to savings.
    /// Holds the same lock as the driver's ticks and the background run for the whole cancel, and decides on the record
    /// as stored now: one a tick funded, built or published meanwhile is never cancelled.
    @discardableResult
    func cancel() async -> CancelOutcome {
        while isTicking {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        isTicking = true
        defer { isTicking = false }
        if let stored = try? Self.loadRecord(store: store, lostLeafStore: lostLeafStore) {
            record = stored
        }
        unresolvedSendAddress = await OnchainSendAttemptService.shared.unresolvedSendAddress()
        guard canCancel, var record, let address = record.funding.first?.address else { return .keep }
        let utxos = try? await chain?.utxos(address: address)
        let outcome = Self.cancelOutcome(utxos: utxos)
        switch outcome {
        case .keep:
            Logger.warn("Spark exit not cancelled: its funding address could not be read", context: "SparkExitManager")
            return outcome
        case let .sweepFunding(leftover):
            record.phase = .failed(reason: SparkExitRecord.cancelledReason)
            record.isCancelled = true
            record.isResultSeen = true
            record.leftover = leftover
            do {
                try saveRecord(record)
            } catch {
                Logger.error("Failed to save the cancelled Spark exit: \(error)", context: "SparkExitManager")
                return .keep
            }
            self.record = record
            if let transferId = record.transferId {
                try? await TransferService(lightningService: .shared).markSettled(id: transferId)
            }
            await reattachSpark()
            Logger.info("Cancelled the Spark exit after funding arrived; sweeping it back to savings", context: "SparkExitManager")
            // After the lock is released by this function's return.
            Task { await tick() }
            return outcome
        case .forget:
            break
        }
        try? store.delete()
        self.record = nil
        Self.clearReminders()
        if let transferId = record.transferId {
            try? await TransferService(lightningService: .shared).markSettled(id: transferId)
        }
        await reattachSpark()
        Logger.info("Cancelled the Spark exit before it was funded", context: "SparkExitManager")
        return .forget
    }

    /// Ticks every minute while the app is active and an exit runs. Each step of an exit needs Bitkit to publish it.
    func runWhileActive() async {
        while !Task.isCancelled, needsDriving {
            await tick()
            try? await Task.sleep(nanoseconds: Self.foregroundTickSeconds * 1_000_000_000)
        }
    }

    func tick() async {
        // Every tick asks for the next background run, so one failed or skipped tick never ends the chain.
        defer {
            if needsDriving {
                Self.scheduleBackgroundRuns()
            }
        }
        guard !isTicking, let current = record, Self.canDrive(current, startingCreatedAt: startingCreatedAt), let chain else { return }
        isTicking = true
        defer { isTicking = false }
        let store = store
        let walletIndex = walletIndex
        let driver = SparkExitDriver(
            chain: chain,
            recovering: SparkManager.shared.exitRecovering,
            makeSigner: { try Self.signer(walletIndex: walletIndex, index: $0) },
            save: saveRecord
        )
        do {
            tipHeight = try? await chain.tipHeight()
            unresolvedSendAddress = await OnchainSendAttemptService.shared.unresolvedSendAddress()
            await refreshRefusedSavingsPayment()
            await refreshNetworkFees(chain: chain)
            await refreshFundingSeen(chain: chain, record: current)
            var updated = try await driver.tick(current)
            // A tick that adopted the funding and came up short would otherwise keep showing that payment as seen.
            if updated.phase != current.phase {
                await refreshFundingSeen(chain: chain, record: updated)
            }
            // The result may have been opened while this tick ran.
            if record?.isResultSeen == true, updated.isResultSeen != true {
                updated.isResultSeen = true
                try? store.save(updated)
            }
            record = updated
            lastError = nil
            await afterTick(updated, wasActive: current.isActive)
        } catch {
            lastError = error.localizedDescription
            Logger.error("Spark exit tick failed: \(error)", context: "SparkExitManager")
            // The driver saved along the way: the next tick starts from what is on disk, never from the copy it began with.
            let stored = (try? Self.loadRecord(store: store, lostLeafStore: lostLeafStore)) ?? current
            record = stored
            await scheduleReminders(stored)
        }
    }

    private func afterTick(_ record: SparkExitRecord, wasActive: Bool) async {
        if let transferId = record.transferId {
            try? TransferStorage.shared.updateClaimableAtHeight(id: transferId, claimableAtHeight: record.claimableAtHeight)
        }
        await settleIfFinished(record)
        await scheduleReminders(record)
        if wasActive, !record.isActive {
            await reattachSpark()
        }
    }

    /// Ends the exit's transfer once the sweep reaches savings or once the exit ended, so its amount is never counted
    /// both as in transfer and in the on-chain balance. Runs on every tick and launch until it holds. A sweep of a
    /// generation the failed-leaf retry replaced is looked for too.
    private func settleIfFinished(_ record: SparkExitRecord) async {
        guard let transferId = record.transferId, let transfer = try? TransferStorage.shared.getById(transferId) else { return }
        let activity = CoreService.shared.activity
        var isSweepSeen = false
        // The sweep's activity is marked as a transfer even after the transfer settled: it may reach the activity
        // list only later.
        for txid in SparkExitMath.sweepTxids(record) {
            guard await activity.hasOnchainActivityForTxid(txid: txid) else { continue }
            await activity.markOnchainActivityAsTransfer(txId: txid)
            isSweepSeen = true
        }
        guard Self.isTransferFinished(record, isSweepSeen: isSweepSeen), !transfer.isSettled else { return }
        try? await TransferService(lightningService: .shared).markSettled(id: transferId)
    }

    /// The exit's transfer ends once the exit ended, or once its sweep reached savings and no leaf is outstanding (a
    /// failed cooperative one before or during its retry, or one a build skipped): the value those leaves hold stays in
    /// transfer, less what already reached savings (`inTransferSats`).
    nonisolated static func isTransferFinished(_ record: SparkExitRecord, isSweepSeen: Bool) -> Bool {
        !record.isActive || (isSweepSeen && !record.hasLeavesOutstanding)
    }

    /// Settles exit transfers no running exit owns, so their amount never stays in transfer to savings for good.
    private func settleOrphanedTransfers(_ record: SparkExitRecord?) async {
        guard let active = try? TransferStorage.shared.getActiveTransfers() else { return }
        for id in SparkExitMath.orphanedTransferIds(active, record: record) {
            Logger.warn("Settling Spark exit transfer \(id) with no running exit", context: "SparkExitManager")
            try? await TransferService(lightningService: .shared).markSettled(id: id)
        }
    }

    private func reattachSpark() async {
        let spark = SparkManager.shared
        await spark.reconnectForExit()
        if LightningService.shared.channelFreeRail == nil, spark.isReady {
            LightningService.shared.channelFreeRail = spark
        }
        spark.onStateChanged?()
    }

    /// Only new funding counts: the adopted inputs and the CPFP change at the address are already part of the exit.
    private func refreshFundingSeen(chain: SparkExitChain, record: SparkExitRecord) async {
        guard let address = record.funding.first?.address else { return }
        fundingAddress = address
        guard record.fundingShortfallSats != nil else {
            setFunding(nil, for: record)
            return
        }
        let utxos = try? await chain.utxos(address: address)
        if let utxos {
            fundingSeenSats = SparkExitMath.newFunding(utxos, record: record).reduce(0) { $0 + $1.value }
        }
        setFunding(SparkExitMath.fundingState(record, utxos: utxos), askTotal: SparkExitMath.fundingAskTotal(record, utxos: utxos), for: record)
    }

    private func setFunding(_ state: SparkExitFundingState?, askTotal: UInt64? = nil, for record: SparkExitRecord) {
        storedFundingState = state
        storedFundingAskTotal = askTotal
        fundingExitCreatedAt = record.createdAt
    }

    /// Whether funding read for the exit created at `createdAt` belongs to `record`: a cancelled exit's savings
    /// payment or funding ask never shows for the next one.
    nonisolated static func isFundingOfExit(_ createdAt: Date?, record: SparkExitRecord?) -> Bool {
        createdAt != nil && createdAt == record?.createdAt
    }

    private func refreshNetworkFees(chain: SparkExitChain) async {
        if SparkManager.shared.exitRecovering != nil, let fees = try? await SparkManager.shared.exitNetworkFees() {
            networkFees = fees
        } else if let fees = try? await chain.networkFees() {
            networkFees = fees
        }
    }

    // MARK: Fee bump

    /// Whether the running exit can move to a higher fee: it is underpriced (refused under the mempool's minimum, or
    /// accepted and unconfirmed for more than `unconfirmedBlocksToSurface` blocks), or the network's next-block rate
    /// is above its own. Not while it rebuilds or waits for funding, and not once only leaves the operators hold are left.
    var canPayHigherFee: Bool {
        guard let record else { return false }
        return Self.canPayHigherFee(record, tip: tipHeight, isNetworkAboveExitRate: isNetworkAboveExitRate)
    }

    /// A recovery of the exit's own still has a step to confirm: a failed-leaf retry that built one counts too, its
    /// timing kept for the leaves still outstanding. One waiting only on the operators has nothing to speed up.
    nonisolated static func canPayHigherFee(_ record: SparkExitRecord, tip: UInt32?, isNetworkAboveExitRate: Bool) -> Bool {
        guard record.phase == .running, !record.isRebuilding, let recovery = record.recovery?.response else { return false }
        let hasStepToConfirm = recovery.transactions.contains {
            if case .confirmed = $0.status {
                return false
            }
            return true
        }
        guard !record.isRetryingFailedLeaves || hasStepToConfirm else { return false }
        return record.underpricedStep(tip: tip) != nil || isNetworkAboveExitRate
    }

    /// The network's next-block rate is above the exit's.
    var isNetworkAboveExitRate: Bool {
        guard let record, let networkFees else { return false }
        return networkFees.fastest > record.feeRateSatPerVbyte
    }

    /// Prices each higher rate against what the exit's funding holds now.
    func loadFeeBumpOptions() async {
        guard let record, let chain else { return }
        isPricingFeeBump = true
        feeBumpError = nil
        defer { isPricingFeeBump = false }
        await refreshNetworkFees(chain: chain)
        guard let networkFees else {
            feeBumpError = t("lightning__spark_exit__fee_bump_error")
            return
        }
        let walletIndex = walletIndex
        let driver = SparkExitDriver(
            chain: chain,
            recovering: SparkManager.shared.exitRecovering,
            makeSigner: { try Self.signer(walletIndex: walletIndex, index: $0) },
            save: { _ in }
        )
        var options = SparkExitFeeBumpOption.options(exitRate: record.feeRateSatPerVbyte, fees: networkFees)
        var leavesBehind = false
        for i in options.indices {
            do {
                options[i].extraSats = try await driver.feeBumpShortfall(record, rate: options[i].rate)
            } catch let SparkExitFeeBumpError.leavesBehind(sats) {
                leavesBehind = true
                Logger.info(
                    "Spark exit fee bump to \(options[i].rate) sat/vB would leave \(sats) sats on Spark; not offered",
                    context: "SparkExitManager"
                )
            } catch {
                Logger.warn("Failed to price a Spark exit fee bump to \(options[i].rate) sat/vB: \(error)", context: "SparkExitManager")
            }
        }
        feeBumpOptions = options.filter { $0.extraSats != nil }
        if feeBumpOptions.isEmpty {
            let key = leavesBehind ? "lightning__spark_exit__fee_bump_leaves_behind" : "lightning__spark_exit__fee_bump_error"
            feeBumpError = t(key)
        }
    }

    /// An ended exit keeps a savings payment that went out after it ended as pending, so the exit is driven until the
    /// payment reaches the funding address and joins the leftover sweep (`followEndedPayment`). Nil while the exit is
    /// active (its funding adopts the payment), without a txid, or while an earlier payment is still followed.
    nonisolated static func followingLatePayment(_ record: SparkExitRecord, txid: String?) -> SparkExitRecord? {
        guard !record.isActive, let txid, !record.isEndedPaymentPending else { return nil }
        var record = record
        record.fundingPaymentTxid = txid
        record.fundingPaymentSeenAtHeight = nil
        record.fundingPaymentMissingSince = nil
        return record
    }

    /// Notes what savings pays in fees to send the extra funding of `rate`.
    func setFeeBumpPaymentFee(rate: UInt64, sats: UInt64) {
        guard let i = feeBumpOptions.firstIndex(where: { $0.rate == rate }) else { return }
        feeBumpOptions[i].paymentFeeSats = sats
    }

    /// Moves the exit to `option`'s rate: pays its extra funding from savings at `savingsFeeRate` first, then rebuilds
    /// what has not confirmed at the new rate, which replaces it on the network.
    func payHigherFee(_ option: SparkExitFeeBumpOption, savingsFeeRate: UInt32) async throws {
        guard let extraSats = option.extraSats, let address = record?.funding.first?.address, canPayHigherFee else {
            throw AppError(message: t("lightning__spark_exit__fee_bump_error"), debugMessage: "No fee bump to pay")
        }
        var txid: String?
        if extraSats > 0 {
            txid = try await payFunding(address: address, sats: extraSats, satsPerVbyte: savingsFeeRate, feeSats: option.paymentFeeSats ?? 0)
        }
        // Written between ticks, so a tick in flight never saves over it.
        while isTicking {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard var record else { return }
        // The exit may have ended while savings paid: the extra stays at the funding address for the leftover sweep.
        guard record.phase == .running, !record.isRebuilding else {
            Logger.warn("Spark exit ended while its higher fee was paid; the payment goes back with the leftover", context: "SparkExitManager")
            if let followed = Self.followingLatePayment(record, txid: txid) {
                try saveRecord(followed)
                self.record = followed
                Task { await tick() }
            }
            return
        }
        record.applyFeeBump(rate: option.rate, extraSats: extraSats, paymentTxid: txid)
        try saveRecord(record)
        self.record = record
        setFunding(SparkExitMath.fundingState(record, utxos: nil), askTotal: storedFundingAskTotal, for: record)
        Logger.info("Spark exit moves to \(option.rate) sat/vB with \(extraSats) sats more funding", context: "SparkExitManager")
        Task { await tick() }
    }

    // MARK: Quote

    func loadQuote() async {
        isQuoting = true
        quoteError = nil
        defer { isQuoting = false }
        do {
            guard let recovering = SparkManager.shared.exitRecovering else {
                throw AppError(message: "Spark is not connected", debugMessage: nil)
            }
            // Value an interrupted leaf optimization still owes the wallet would otherwise stay out of the quote.
            await SparkManager.shared.settleForExit()
            let feeRate = try await SparkManager.shared.exitFeeRate()
            let destination: String = if let pendingDestination {
                pendingDestination
            } else {
                try await LightningService.shared.newAddress()
            }
            let newQuote = try await SparkExitQuote.prepare(
                recovering,
                feeRateSatPerVbyte: feeRate,
                destination: destination,
                lostLeafIds: (try? lostLeafStore.load()) ?? []
            )
            let fundingIndex = pendingFundingIndex ?? nextFundingIndex()
            let fundingAddress = try Self.fundingKey(walletIndex: walletIndex, index: fundingIndex).address
            useQuote(newQuote, destination: destination, feeRate: feeRate, fundingIndex: fundingIndex, fundingAddress: fundingAddress)
        } catch {
            Logger.error("Failed to quote the Spark exit: \(error)", context: "SparkExitManager")
            quote = nil
            quoteError = t("lightning__spark_exit__quote_error")
        }
    }

    /// The quote the funding and confirm screens show, and `start()` starts from.
    func useQuote(_ quote: SparkExitQuote, destination: String, feeRate: UInt64, fundingIndex: UInt32, fundingAddress: String) {
        pendingDestination = destination
        pendingFeeRate = feeRate
        pendingFundingIndex = fundingIndex
        self.quote = quote
        self.fundingAddress = fundingAddress
    }

    /// Watches the funding address while the user funds it from another wallet.
    func watchFundingAddress() async {
        guard let chain, let fundingAddress else { return }
        while !Task.isCancelled {
            if let utxos = try? await chain.utxos(address: fundingAddress) {
                noteFundingSeen(utxos)
            }
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
        }
    }

    /// What reached the funding address before the exit starts.
    func noteFundingSeen(_ utxos: [EsploraUtxo]) {
        fundingSeenSats = utxos.reduce(0) { $0 + $1.value }
        fundingSeenCount = utxos.count
    }

    // MARK: Start

    /// Starts the exit for the current quote: writes its record, moves the Spark balance into transfer to savings
    /// and, with `fundFromSavings`, pays the fee funding from savings at `savingsFeeRate`.
    func start() async throws {
        guard !isExiting, let quote, let destination = pendingDestination, let feeRate = pendingFeeRate,
              let fundingIndex = pendingFundingIndex, let network = SparkManager.exitNetwork
        else {
            throw AppError(message: t("lightning__spark_exit__quote_error"), debugMessage: "No quote to start from")
        }
        let key = try Self.fundingKey(walletIndex: walletIndex, index: fundingIndex)
        var record = SparkExitRecord(
            network: "\(network)",
            createdAt: Date(),
            phase: .awaitingFunding(requiredSats: quote.fundingSats),
            feeRateSatPerVbyte: feeRate,
            destination: destination,
            leafIds: quote.leafIds,
            leafTotalSats: quote.leafTotalSats,
            funding: [.init(index: fundingIndex, address: key.address, pubkey: key.pubkey)],
            expectedSats: quote.incomingSats,
            skippedLeafCount: quote.prepared.skipped.count
        )
        record.fundingStrategy = SparkExitRecord.perNodeStrategy
        // Saved before the transfer exists, so a failed save never leaves a transfer counted with no exit behind it.
        try store.save(record)
        record.transferId = try await TransferService(lightningService: .shared).createTransfer(type: .sparkExit, amountSats: quote.incomingSats)
        try store.save(record)
        UserDefaults.standard.set(walletIndex, forKey: Self.walletIndexKey)
        UserDefaults.standard.set(Int(fundingIndex) + 1, forKey: fundingIndexKey)
        pendingFundingIndex = nil
        startingCreatedAt = record.createdAt
        defer { startingCreatedAt = nil }
        self.record = record
        SparkManager.shared.detachForExit()
        // Reconnecting cuts an optimization short, which would leave its counter-swap unclaimed for a while.
        await SparkManager.shared.waitForOptimization()
        // The rest runs under the ticks' lock, on this exit as stored: one cancelled during the wait above is never
        // reconnected for or paid to.
        while isTicking {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        isTicking = true
        defer { isTicking = false }
        let stored = try? Self.loadRecord(store: store, lostLeafStore: lostLeafStore)
        guard var started = Self.startedExit(stored: stored, createdAt: record.createdAt) else {
            Logger.info("Spark exit was cancelled before it started; nothing paid", context: "SparkExitManager")
            throw SparkExitStartCancelled()
        }
        // An optimization since the quote swapped leaves: the exit is quoted again over the leaves Spark holds now.
        var exitQuote = quote
        if let recovering = SparkManager.shared.exitRecovering,
           let fresh = await Self.requote(
               recovering,
               confirmed: quote,
               feeRate: feeRate,
               destination: destination,
               lostLeafIds: (try? lostLeafStore.load()) ?? []
           ),
           let requoted = Self.requoted(started, fresh: fresh)
        {
            let transfers = TransferService(lightningService: .shared)
            let store = store
            let written = await Self.writeRequote(
                requoted,
                replacing: started,
                incomingSats: fresh.incomingSats,
                createTransfer: { try await transfers.createTransfer(type: .sparkExit, amountSats: $0) },
                save: { try store.save($0) },
                markSettled: { try? await transfers.markSettled(id: $0) }
            )
            if let written {
                started = written
                self.record = written
                exitQuote = fresh
            }
        }
        await SparkManager.shared.reconnectForExit()
        Logger.info("Started Spark exit of \(exitQuote.exitSats) sats over \(exitQuote.leafIds.count) leaves", context: "SparkExitManager")

        let savingsSats = Self.savingsFundingSats(confirmed: quote, fresh: exitQuote)
        if fundFromSavings, savingsSats > 0 {
            let txid: String
            do {
                txid = try await payFunding(address: key.address, sats: savingsSats, satsPerVbyte: savingsFeeRate, feeSats: savingsFeeSats)
            } catch {
                // A refused payment shows on progress at once, with the offer to pay again.
                await refreshRefusedSavingsPayment()
                throw error
            }
            // Saved before the lock is released, so a cancel after the payment finds it and refuses.
            started.fundingPaymentTxid = txid
            do {
                try store.save(started)
            } catch {
                Logger.error("Failed to save the Spark exit funding payment: \(error)", context: "SparkExitManager")
            }
            self.record = started
            setFunding(SparkExitMath.fundingState(started, utxos: nil), for: started)
        }
        Task { await tick() }
    }

    /// The exit quoted again at its start, when the leaves Spark holds changed since the confirmed quote; nil when they
    /// did not, when none is left, or when the quote fails (the exit then goes on with the confirmed one).
    nonisolated static func requote(
        _ recovering: SparkExitRecovering,
        confirmed: SparkExitQuote,
        feeRate: UInt64,
        destination: String,
        lostLeafIds: Set<String>
    ) async -> SparkExitQuote? {
        do {
            let fresh = try await SparkExitQuote.prepare(recovering, feeRateSatPerVbyte: feeRate, destination: destination, lostLeafIds: lostLeafIds)
            guard !fresh.leafIds.isEmpty, Set(fresh.leafIds) != Set(confirmed.leafIds) else { return nil }
            Logger.warn("Quoting the Spark exit again: its leaves changed since the quote", context: "SparkExitManager")
            return fresh
        } catch {
            Logger.warn("Failed to quote the Spark exit again at its start: \(error)", context: "SparkExitManager")
            return nil
        }
    }

    /// The started exit over the fresh quote's leaves, amount and funding.
    nonisolated static func requoted(_ record: SparkExitRecord, fresh: SparkExitQuote) -> SparkExitRecord? {
        guard case .awaitingFunding = record.phase else { return nil }
        var record = record
        record.phase = .awaitingFunding(requiredSats: fresh.fundingSats)
        record.leafIds = fresh.leafIds
        record.leafTotalSats = fresh.leafTotalSats
        record.expectedSats = fresh.incomingSats
        record.skippedLeafCount = fresh.prepared.skipped.count
        return record
    }

    /// The started exit moved onto the fresh quote: a transfer for its amount, saved, and the confirmed quote's transfer
    /// settled. Nil when that write fails, with a transfer made for it settled again: the start goes on with the
    /// confirmed quote, as after a failed requote, so it still reconnects, pays and ticks.
    nonisolated static func writeRequote(
        _ requoted: SparkExitRecord,
        replacing started: SparkExitRecord,
        incomingSats: UInt64,
        createTransfer: (UInt64) async throws -> String,
        save: (SparkExitRecord) throws -> Void,
        markSettled: (String) async -> Void
    ) async -> SparkExitRecord? {
        var requoted = requoted
        do {
            requoted.transferId = try await createTransfer(incomingSats)
        } catch {
            Logger.warn("Failed to create the requoted Spark exit transfer, going on with the confirmed quote: \(error)", context: "SparkExitManager")
            return nil
        }
        do {
            try save(requoted)
        } catch {
            Logger.warn("Failed to save the requoted Spark exit, going on with the confirmed quote: \(error)", context: "SparkExitManager")
            if let created = requoted.transferId {
                await markSettled(created)
            }
            return nil
        }
        if let replaced = started.transferId {
            await markSettled(replaced)
        }
        return requoted
    }

    /// Whether a tick may drive the exit now: not while its start still settles it (`startingCreatedAt`).
    nonisolated static func canDrive(_ record: SparkExitRecord, startingCreatedAt: Date?) -> Bool {
        record.needsDriving && record.createdAt != startingCreatedAt
    }

    /// Savings pays at most the funding the user confirmed: a higher fresh amount goes through the shortfall flow on
    /// Progress, which asks for the rest.
    nonisolated static func savingsFundingSats(confirmed: SparkExitQuote, fresh: SparkExitQuote) -> UInt64 {
        min(confirmed.fundingSats, fresh.fundingSats)
    }

    /// The exit a start began, still stored and active (not cancelled meanwhile); nil otherwise. The store keeps
    /// dates to the millisecond.
    nonisolated static func startedExit(stored: SparkExitRecord?, createdAt: Date) -> SparkExitRecord? {
        guard let stored, stored.isActive else { return nil }
        let millis = { (date: Date) in (date.timeIntervalSince1970 * 1000).rounded() }
        return millis(stored.createdAt) == millis(createdAt) ? stored : nil
    }

    /// Keeps the savings payment in the record, so the exit waits for it instead of asking for the funding again.
    /// Written between ticks, so a tick in flight never saves over it.
    /// The funding key index of the next exit: one no exit of this wallet used, from the counter the last start
    /// left and the stored record, so leftover of an earlier exit never mixes into a new one.
    private func nextFundingIndex() -> UInt32 {
        SparkExitMath.nextFundingIndex(counter: UserDefaults.standard.integer(forKey: fundingIndexKey), record: record)
    }

    private var fundingIndexKey: String {
        "sparkExitNextFundingIndex-\(Env.network)-\(walletIndex)"
    }

    /// Pays the fee funding from savings. It shows as an ordinary payment, not as a transfer to spending.
    @discardableResult
    func payFunding(address: String, sats: UInt64, satsPerVbyte: UInt32, feeSats: UInt64) async throws -> String {
        let lightning = LightningService.shared
        let attempts = OnchainSendAttemptService.shared
        let result = try await attempts.send(
            using: lightning,
            address: address,
            amountSats: sats,
            satsPerVbyte: satsPerVbyte,
            utxosToSpend: nil,
            isMaxAmount: false,
            followupContext: OnchainSendFollowupContext(
                feeSats: feeSats,
                feeRate: satsPerVbyte,
                tags: [],
                contact: nil,
                createdAt: UInt64(Date().timeIntervalSince1970)
            )
        )
        // An unknown outcome may still have gone out: it is kept as paid (pending), so the exit, and its address, stay
        // until the payment lands or the own-payment expiry forgets it.
        guard let txid = Self.fundingTxid(result) else {
            throw AppError(message: t("wallet__send_error_tx_failed"), debugMessage: "Spark exit funding outcome: \(result)")
        }
        if case .accepted = result {
            _ = try? await attempts.resumeAcceptedOrdinarySend(
                walletId: OnchainSendAttemptService.walletId(index: lightning.currentWalletIndex),
                observedTxid: txid
            )
            Logger.info("Funded the Spark exit with \(sats) sats in \(txid)", context: "SparkExitManager")
        } else {
            Logger.warn("Spark exit funding \(txid) has an unknown outcome; kept as pending", context: "SparkExitManager")
        }
        return txid
    }

    /// The funding payment's txid to keep as paid: accepted, or unknown (it may still have gone out). A refused one is none.
    nonisolated static func fundingTxid(_ result: OnchainSendResult) -> String? {
        switch result {
        case let .accepted(txid), let .unknown(txid): txid
        case .rejected: nil
        }
    }

    // MARK: Keys

    private nonisolated static func fundingKey(walletIndex: Int, index: UInt32) throws -> SparkExitFundingKey.Derived {
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        return try SparkExitFundingKey.derive(index: index, mnemonic: mnemonic, passphrase: passphrase, network: Env.bitkitCoreNetwork)
    }

    private nonisolated static func signer(walletIndex: Int, index: UInt32) throws -> CpfpSigner {
        try singleKeyCpfpSigner(secretKeyBytes: fundingKey(walletIndex: walletIndex, index: index).secretKey)
    }

    // MARK: Background

    /// One background run from a cold launch or a suspended app, with no UI: the keyless pass, then the Spark SDK
    /// only (never the node) for the check, the signing and the broadcast, then the reminders and the next runs.
    /// Waits for a foreground tick in flight instead of skipping, so the run never reports work it did not do.
    @discardableResult
    func runInBackground(deadline: Date) async -> SparkExitBackgroundRun.Outcome {
        defer {
            if needsDriving {
                Self.scheduleBackgroundRuns()
            }
        }
        if record == nil {
            load(walletIndex: UserDefaults.standard.integer(forKey: Self.walletIndexKey))
            // Before the first unlock after a restart the record cannot be read yet: this run ends, and the next one
            // comes once it can.
            if record == nil, FileManager.default.fileExists(atPath: store.url.path) {
                Logger.info("Spark exit background run waits for the first unlock", context: "SparkExitManager")
                Self.scheduleBackgroundRuns()
                return .init(record: nil)
            }
        }
        while isTicking, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !isTicking, startingCreatedAt == nil, let chain else { return .init(record: record) }
        let wasActive = record?.isActive == true
        isTicking = true
        defer { isTicking = false }
        let store = store
        let lostLeafStore = lostLeafStore
        let saveRecord = saveRecord
        let walletIndex = walletIndex
        let run = SparkExitBackgroundRun(
            load: { try Self.loadRecord(store: store, lostLeafStore: lostLeafStore) },
            makeDriver: { chain, recovering in
                SparkExitDriver(
                    chain: chain,
                    recovering: recovering,
                    makeSigner: { try Self.signer(walletIndex: walletIndex, index: $0) },
                    save: saveRecord
                )
            },
            chain: chain,
            connected: SparkManager.shared.exitRecovering,
            connect: { timeout in await SparkManager.shared.connectForExit(walletIndex: walletIndex, timeout: timeout) },
            deadline: deadline
        )
        tipHeight = try? await chain.tipHeight()
        let outcome = await run.run()
        let seconds = SparkExitBackgroundRun.Step.allCases.compactMap { step in
            outcome.seconds[step].map { "\(step.rawValue)=\(String(format: "%.2f", $0))s" }
        }
        Logger.info(
            "Spark exit background run: connected=\(outcome.isConnected) phase=\(String(describing: outcome.record?.phase)) "
                + "\(seconds.joined(separator: " ")) footprint=\(Self.footprintMegabytes())MB",
            context: "SparkExitManager"
        )
        if let updated = outcome.record {
            record = updated
            await afterTick(updated, wasActive: wasActive)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastBackgroundRunKey)
        return outcome
    }

    private nonisolated static let lastBackgroundRunKey = "sparkExitLastBackgroundRun"

    /// The process's physical footprint, as `footprint` and Xcode's memory gauge report it.
    nonisolated static func footprintMegabytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// Registers the background runs that drive an exit while Bitkit is closed. Must run before launch finishes.
    nonisolated static func registerBackgroundTask() {
        // The OS ends a refresh after about 30 seconds and a processing task after a few minutes.
        register(backgroundTaskId, seconds: 25)
        register(processingTaskId, seconds: 4 * 60)
    }

    private nonisolated static func register(_ identifier: String, seconds: TimeInterval) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let completion = SparkExitTaskCompletion(task)
            let work = Task { @MainActor in
                await SparkExitManager.shared.runInBackground(deadline: Date(timeIntervalSinceNow: seconds))
                completion.complete(success: !Task.isCancelled)
            }
            // The driver stops before its next SDK call or broadcast and has saved every broadcast, so the record on
            // disk is whole whenever the OS suspends the app.
            task.expirationHandler = {
                work.cancel()
                completion.complete(success: false)
            }
        }
    }

    nonisolated static func scheduleBackgroundRuns() {
        // The refresh moves out on every run; the processing task is left alone while pending, or runs ticking more
        // often than its floor would keep it from ever coming due.
        BGTaskScheduler.shared.getPendingTaskRequests { pending in
            let refresh = BGAppRefreshTaskRequest(identifier: backgroundTaskId)
            refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            var requests: [BGTaskRequest] = [refresh]
            if !pending.contains(where: { $0.identifier == processingTaskId }) {
                let processing = BGProcessingTaskRequest(identifier: processingTaskId)
                processing.requiresNetworkConnectivity = true
                processing.requiresExternalPower = false
                processing.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
                requests.append(processing)
            }
            for request in requests {
                do {
                    try BGTaskScheduler.shared.submit(request)
                } catch {
                    Logger.warn("Failed to schedule Spark exit run \(request.identifier): \(error)", context: "SparkExitManager")
                }
            }
        }
    }

    // MARK: Reminders

    /// Schedules a reminder ahead of each step, so it fires even when no background run gets to that step: at each
    /// timelock's maturity plus a grace well inside the ~50 blocks after which the operators may publish their own
    /// version, after a grace for steps ready to publish now, and at once when the exit needs more fee funding or a
    /// step keeps being rejected. Each run (foreground or background) recomputes them, which drops the reminders of
    /// steps it published or that confirmed, and of an exit that ended.
    private func scheduleReminders(_ record: SparkExitRecord) async {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let remembered = Self.rememberedReminders()
        let planned = SparkExitMath.reminders(record, tip: tipHeight, now: now, network: Env.network)
        var kept: [String: TimeInterval] = [:]
        var requests: [UNNotificationRequest] = []
        for reminder in planned {
            let id = Self.notificationId(reminder, record: record)
            // A reminder that fired is not posted again. One still ahead keeps its earliest date, so runs that do not
            // publish its step never push it out.
            let rememberedAt = remembered[id].map(Date.init(timeIntervalSince1970:))
            if let rememberedAt, rememberedAt <= now {
                kept[id] = rememberedAt.timeIntervalSince1970
                continue
            }
            let fireAt = max(now.addingTimeInterval(1), min(reminder.fireAt, rememberedAt ?? reminder.fireAt))
            kept[id] = fireAt.timeIntervalSince1970
            let content = UNMutableNotificationContent()
            content.userInfo = ["bitkit_action": Self.notificationAction]
            content.title = t("lightning__spark_exit__notification_title")
            content.body = if reminder.isLostLeaves {
                t("lightning__spark_exit__notification_lost", variables: ["amount": "₿ \(CurrencyFormatter.formatSats(record.lostSats))"])
            } else if reminder.isFailed {
                t("lightning__spark_exit__notification_failed")
            } else if reminder.isNotMoving {
                t("lightning__spark_exit__notification_not_moving")
            } else {
                t(reminder.isFunding ? "lightning__spark_exit__notification_funding" : "lightning__spark_exit__notification_body")
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireAt.timeIntervalSince(now), repeats: false)
            requests.append(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.notificationPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for request in requests {
            try? await center.add(request)
        }
        UserDefaults.standard.set(Self.keepingFired(kept, remembered: remembered, now: now), forKey: Self.remindersKey)
    }

    /// How long a fired reminder stays remembered after it left the plan, so a plan that drops an id for one run (a
    /// tip that could not be read, a phase that flickered) never posts it again.
    nonisolated static let firedReminderMemory: TimeInterval = 30 * 24 * 60 * 60

    /// `kept` plus every reminder that already fired within `firedReminderMemory`, whether or not it is planned now.
    nonisolated static func keepingFired(_ kept: [String: TimeInterval], remembered: [String: TimeInterval], now: Date) -> [String: TimeInterval] {
        var result = kept
        for (id, firedAt) in remembered where result[id] == nil {
            let age = now.timeIntervalSince1970 - firedAt
            if age >= 0, age < firedReminderMemory {
                result[id] = firedAt
            }
        }
        return result
    }

    /// A reminder's notification id, scoped to its exit (its creation time), so a later exit's `failed`, `lost-1` or
    /// `1-rebuild` is never taken for one an earlier exit already fired.
    nonisolated static func notificationId(_ reminder: SparkExitReminder, record: SparkExitRecord) -> String {
        "\(notificationPrefix)-\(Int64(record.createdAt.timeIntervalSince1970 * 1000))-\(reminder.id)"
    }

    private nonisolated static func rememberedReminders() -> [String: TimeInterval] {
        UserDefaults.standard.dictionary(forKey: remindersKey) as? [String: TimeInterval] ?? [:]
    }

    private nonisolated static func clearReminders() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(notificationPrefix) })
        }
        UserDefaults.standard.removeObject(forKey: remindersKey)
    }
}

/// Completes a background task once, whichever comes first: the run finishing or the OS expiring it.
private final class SparkExitTaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGTask?

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        let task = lock.withLock {
            defer { self.task = nil }
            return self.task
        }
        task?.setTaskCompleted(success: success)
    }
}

/// A start whose exit was cancelled while it waited: nothing was paid and Spark was not taken off Lightning.
struct SparkExitStartCancelled: Error {}

/// Lets the exit's writes through until a wipe closes it.
final class SparkExitWriteGate: @unchecked Sendable {
    struct Closed: Error {}

    private let lock = NSLock()
    private var closed = false

    var isOpen: Bool {
        lock.withLock { !closed }
    }

    func close() {
        lock.withLock { closed = true }
    }
}
