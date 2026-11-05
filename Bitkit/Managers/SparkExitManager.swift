import BackgroundTasks
import BitkitCore
import BreezSdkSpark
import Foundation
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
    private(set) var fundingState: SparkExitFundingState?
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
    @ObservationIgnored private var pendingDestination: String?
    @ObservationIgnored private var pendingFeeRate: UInt64?
    @ObservationIgnored private var pendingFundingIndex: UInt32?

    private init() {}

    /// The fee rate of the quote on screen.
    var quoteFeeRate: UInt64? {
        pendingFeeRate
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

    /// Saves the record, and keeps the leaves it lost to an older state for every later exit of the wallet.
    private var saveRecord: (SparkExitRecord) throws -> Void {
        let store = store
        let lostLeafStore = lostLeafStore
        return {
            try store.save($0)
            try lostLeafStore.add(lostIn: $0)
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
            try store.setAside()
            try store.save(salvaged)
            record = salvaged
        }
        try? lostLeafStore.add(lostIn: record)
        return record
    }

    /// Forgets the exit of a wallet being wiped.
    func wipe() {
        try? store.delete()
        try? lostLeafStore.delete()
        record = nil
        quote = nil
        pendingFundingIndex = nil
        Self.clearReminders()
    }

    /// Stops an exit that has not built anything and whose funding address received nothing, so leaving it
    /// costs nothing: Spark comes back as it was.
    var canCancel: Bool {
        guard let record, record.recovery == nil, record.fundedSats == 0, fundingSeenSats == 0 else { return false }
        if case .awaitingFunding = record.phase {
            return true
        }
        return false
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

    func cancel() async {
        guard canCancel, let record else { return }
        try? store.delete()
        self.record = nil
        Self.clearReminders()
        if let transferId = record.transferId {
            try? await TransferService(lightningService: .shared).markSettled(id: transferId)
        }
        await reattachSpark()
        Logger.info("Cancelled the Spark exit before it was funded", context: "SparkExitManager")
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
        guard !isTicking, let current = record, current.needsDriving, let chain else { return }
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
            await scheduleReminders(current)
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

    /// Ends the exit's transfer once the sweep reaches savings, once only leaves the operators moved on-chain are left,
    /// or once the exit ended, so its amount is never counted both as in transfer and in the on-chain balance. Runs on
    /// every tick and launch until it holds. A sweep of a generation the failed-leaf retry replaced is looked for too.
    private func settleIfFinished(_ record: SparkExitRecord) async {
        guard let transferId = record.transferId,
              let transfer = try? TransferStorage.shared.getById(transferId), !transfer.isSettled
        else { return }
        let activity = CoreService.shared.activity
        var isFinished = !record.isActive || record.isRetryingFailedLeaves
        let sweeps = (record.recovery?.response.transactions ?? []).filter { $0.kind == .sweep }.map(\.txid)
            + (record.earlierReceivedSats ?? [:]).keys.sorted()
        for txid in sweeps {
            guard await activity.hasOnchainActivityForTxid(txid: txid) else { continue }
            await activity.markOnchainActivityAsTransfer(txId: txid)
            isFinished = true
        }
        guard isFinished else { return }
        try? await TransferService(lightningService: .shared).markSettled(id: transferId)
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
            fundingState = nil
            return
        }
        let utxos = try? await chain.utxos(address: address)
        if let utxos {
            fundingSeenSats = SparkExitMath.newFunding(utxos, record: record).reduce(0) { $0 + $1.value }
        }
        fundingState = SparkExitMath.fundingState(record, utxos: utxos)
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
        guard let record, record.phase == .running, !record.isRebuilding, record.recovery != nil, !record.isRetryingFailedLeaves else {
            return false
        }
        return record.underpricedStep(tip: tipHeight) != nil || isNetworkAboveExitRate
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
        for i in options.indices {
            do {
                options[i].extraSats = try await driver.feeBumpShortfall(record, rate: options[i].rate)
            } catch {
                Logger.warn("Failed to price a Spark exit fee bump to \(options[i].rate) sat/vB: \(error)", context: "SparkExitManager")
            }
        }
        feeBumpOptions = options.filter { $0.extraSats != nil }
        if feeBumpOptions.isEmpty {
            feeBumpError = t("lightning__spark_exit__fee_bump_error")
        }
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
        record.applyFeeBump(rate: option.rate, extraSats: extraSats, paymentTxid: txid)
        try saveRecord(record)
        self.record = record
        fundingState = SparkExitMath.fundingState(record, utxos: nil)
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
            pendingDestination = destination
            pendingFeeRate = feeRate
            pendingFundingIndex = fundingIndex
            quote = newQuote
            fundingAddress = try Self.fundingKey(walletIndex: walletIndex, index: fundingIndex).address
        } catch {
            Logger.error("Failed to quote the Spark exit: \(error)", context: "SparkExitManager")
            quote = nil
            quoteError = t("lightning__spark_exit__quote_error")
        }
    }

    /// Watches the funding address while the user funds it from another wallet.
    func watchFundingAddress() async {
        guard let chain, let fundingAddress else { return }
        while !Task.isCancelled {
            if let utxos = try? await chain.utxos(address: fundingAddress) {
                fundingSeenSats = utxos.reduce(0) { $0 + $1.value }
                fundingSeenCount = utxos.count
            }
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
        }
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
        self.record = record
        SparkManager.shared.detachForExit()
        // Reconnecting cuts an optimization short, which would leave its counter-swap unclaimed for a while.
        await SparkManager.shared.waitForOptimization()
        await SparkManager.shared.reconnectForExit()
        Logger.info("Started Spark exit of \(quote.exitSats) sats over \(quote.leafIds.count) leaves", context: "SparkExitManager")

        if fundFromSavings, quote.fundingSats > 0 {
            let txid = try await payFunding(address: key.address, sats: quote.fundingSats, satsPerVbyte: savingsFeeRate, feeSats: savingsFeeSats)
            await notePaidFunding(txid: txid)
        }
        Task { await tick() }
    }

    /// Keeps the savings payment in the record, so the exit waits for it instead of asking for the funding again.
    /// Written between ticks, so a tick in flight never saves over it.
    private func notePaidFunding(txid: String) async {
        while isTicking {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard var record else { return }
        record.fundingPaymentTxid = txid
        do {
            try store.save(record)
        } catch {
            Logger.error("Failed to save the Spark exit funding payment: \(error)", context: "SparkExitManager")
        }
        self.record = record
        fundingState = SparkExitMath.fundingState(record, utxos: nil)
    }

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
        guard case let .accepted(txid) = result else {
            throw AppError(message: t("wallet__send_error_tx_failed"), debugMessage: "Spark exit funding outcome: \(result)")
        }
        _ = try? await attempts.resumeAcceptedOrdinarySend(
            walletId: OnchainSendAttemptService.walletId(index: lightning.currentWalletIndex),
            observedTxid: txid
        )
        Logger.info("Funded the Spark exit with \(sats) sats in \(txid)", context: "SparkExitManager")
        return txid
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
        guard !isTicking, let chain else { return .init(record: record) }
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
            let id = "\(Self.notificationPrefix)-\(reminder.id)"
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
        UserDefaults.standard.set(kept, forKey: Self.remindersKey)
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
