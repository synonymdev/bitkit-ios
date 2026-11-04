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
    private static let foregroundTickSeconds: UInt64 = 60

    private(set) var record: SparkExitRecord?
    private(set) var quote: SparkExitQuote?
    private(set) var quoteError: String?
    private(set) var isQuoting = false
    private(set) var tipHeight: UInt32?
    /// Confirmed or not, what reached the funding address and is not a funding input yet.
    private(set) var fundingSeenSats: UInt64 = 0
    private(set) var fundingAddress: String?
    private(set) var lastError: String?

    /// The funding choice made on the funding screen, used when the exit starts.
    @ObservationIgnored var fundFromSavings = false
    @ObservationIgnored var savingsFeeRate: UInt32 = 0
    @ObservationIgnored var savingsFeeSats: UInt64 = 0
    @ObservationIgnored private var walletIndex = 0
    @ObservationIgnored private var isTicking = false
    @ObservationIgnored private var pendingDestination: String?
    @ObservationIgnored private var pendingFeeRate: UInt64?

    private init() {}

    var isExiting: Bool {
        record?.isActive == true
    }

    private var store: SparkExitStore {
        SparkExitStore(walletIndex: walletIndex)
    }

    private var chain: SparkExitChain? {
        guard let network = SparkManager.exitNetwork else { return nil }
        return EsploraSparkExitChain(hosts: EsploraSparkExitChain.defaultHosts(for: network))
    }

    // MARK: Lifecycle

    func load(walletIndex: Int) {
        self.walletIndex = walletIndex
        do {
            record = try store.load()
        } catch {
            // Kept aside for support, so a new exit never overwrites it; a new exit prepares from chain state.
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

    /// Forgets the exit of a wallet being wiped.
    func wipe() {
        try? store.delete()
        record = nil
        quote = nil
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
        while !Task.isCancelled, isExiting {
            await tick()
            try? await Task.sleep(nanoseconds: Self.foregroundTickSeconds * 1_000_000_000)
        }
    }

    func tick() async {
        // Every tick asks for the next background run, so one failed or skipped tick never ends the chain.
        defer {
            if isExiting {
                Self.scheduleBackgroundRuns()
            }
        }
        guard !isTicking, let current = record, current.isActive, let chain else { return }
        isTicking = true
        defer { isTicking = false }
        let store = store
        let walletIndex = walletIndex
        let driver = SparkExitDriver(
            chain: chain,
            recovering: SparkManager.shared.exitRecovering,
            makeSigner: { try Self.signer(walletIndex: walletIndex) },
            save: { try store.save($0) }
        )
        do {
            tipHeight = try? await chain.tipHeight()
            await refreshFundingSeen(chain: chain, record: current)
            let updated = try await driver.tick(current)
            record = updated
            lastError = nil
            await afterTick(updated)
        } catch {
            lastError = error.localizedDescription
            Logger.error("Spark exit tick failed: \(error)", context: "SparkExitManager")
            await scheduleReminders(current)
        }
    }

    private func afterTick(_ record: SparkExitRecord) async {
        if let transferId = record.transferId {
            try? TransferStorage.shared.updateClaimableAtHeight(id: transferId, claimableAtHeight: record.claimableAtHeight)
        }
        await settleIfFinished(record)
        await scheduleReminders(record)
        if !record.isActive {
            await reattachSpark()
        }
    }

    /// Ends the exit's transfer once the sweep reaches savings, or once the exit ended, so its amount is never
    /// counted both as in transfer and in the on-chain balance. Runs on every tick and launch until it holds.
    private func settleIfFinished(_ record: SparkExitRecord) async {
        guard let transferId = record.transferId,
              let transfer = try? TransferStorage.shared.getById(transferId), !transfer.isSettled
        else { return }
        let activity = CoreService.shared.activity
        var isFinished = !record.isActive
        if let sweep = record.recovery?.response.transactions.first(where: { $0.kind == .sweep }),
           await activity.hasOnchainActivityForTxid(txid: sweep.txid)
        {
            await activity.markOnchainActivityAsTransfer(txId: sweep.txid)
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

    private func refreshFundingSeen(chain: SparkExitChain, record: SparkExitRecord) async {
        guard let address = record.funding.first?.address else { return }
        fundingAddress = address
        guard record.fundingShortfallSats != nil, let utxos = try? await chain.utxos(address: address) else { return }
        fundingSeenSats = utxos.reduce(0) { $0 + $1.value }
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
            let feeRate = try await SparkManager.shared.exitFeeRate()
            let destination: String = if let pendingDestination {
                pendingDestination
            } else {
                try await LightningService.shared.newAddress()
            }
            let prepared = try await recovering.prepare(PrepareRecoverFundsRequest(
                feeRateSatPerVbyte: feeRate,
                fundingKind: .p2wpkh,
                destination: destination,
                selection: .all
            ))
            pendingDestination = destination
            pendingFeeRate = feeRate
            quote = SparkExitQuote(prepared: prepared)
            fundingAddress = try Self.fundingKey(walletIndex: walletIndex).address
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
            }
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
        }
    }

    // MARK: Start

    /// Starts the exit for the current quote: writes its record, moves the Spark balance into transfer to savings
    /// and, with `fundFromSavings`, pays the fee funding from savings at `savingsFeeRate`.
    func start() async throws {
        guard !isExiting, let quote, let destination = pendingDestination, let feeRate = pendingFeeRate, let network = SparkManager.exitNetwork else {
            throw AppError(message: t("lightning__spark_exit__quote_error"), debugMessage: "No quote to start from")
        }
        let key = try Self.fundingKey(walletIndex: walletIndex)
        var record = SparkExitRecord(
            network: "\(network)",
            createdAt: Date(),
            phase: .awaitingFunding(requiredSats: quote.fundingSats),
            feeRateSatPerVbyte: feeRate,
            destination: destination,
            leafIds: quote.leafIds,
            funding: [.init(index: 0, address: key.address, pubkey: key.pubkey)],
            expectedSats: quote.incomingSats,
            skippedLeafCount: quote.prepared.skipped.count
        )
        // Saved before the transfer exists, so a failed save never leaves a transfer counted with no exit behind it.
        try store.save(record)
        record.transferId = try await TransferService(lightningService: .shared).createTransfer(type: .sparkExit, amountSats: quote.incomingSats)
        try store.save(record)
        UserDefaults.standard.set(walletIndex, forKey: Self.walletIndexKey)
        self.record = record
        SparkManager.shared.detachForExit()
        await SparkManager.shared.reconnectForExit()
        Logger.info("Started Spark exit of \(quote.exitSats) sats over \(quote.leafIds.count) leaves", context: "SparkExitManager")

        if fundFromSavings, quote.fundingSats > 0 {
            try await payFunding(address: key.address, sats: quote.fundingSats, satsPerVbyte: savingsFeeRate, feeSats: savingsFeeSats)
        }
        Task { await tick() }
    }

    /// Pays the fee funding from savings. It shows as an ordinary payment, not as a transfer to spending.
    func payFunding(address: String, sats: UInt64, satsPerVbyte: UInt32, feeSats: UInt64) async throws {
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
    }

    // MARK: Keys

    private nonisolated static func fundingKey(walletIndex: Int) throws -> SparkExitFundingKey.Derived {
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        return try SparkExitFundingKey.derive(index: 0, mnemonic: mnemonic, passphrase: passphrase, network: Env.bitkitCoreNetwork)
    }

    private nonisolated static func signer(walletIndex: Int) throws -> CpfpSigner {
        try singleKeyCpfpSigner(secretKeyBytes: fundingKey(walletIndex: walletIndex).secretKey)
    }

    // MARK: Background

    /// One background run from a cold launch or a suspended app, with no UI: the keyless pass, then the Spark SDK
    /// only (never the node) for the check, the signing and the broadcast, then the reminders and the next runs.
    /// Waits for a foreground tick in flight instead of skipping, so the run never reports work it did not do.
    @discardableResult
    func runInBackground(deadline: Date) async -> SparkExitBackgroundRun.Outcome {
        defer {
            if isExiting {
                Self.scheduleBackgroundRuns()
            }
        }
        if record == nil {
            load(walletIndex: UserDefaults.standard.integer(forKey: Self.walletIndexKey))
        }
        while isTicking, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !isTicking, let chain else { return .init(record: record) }
        isTicking = true
        defer { isTicking = false }
        let store = store
        let walletIndex = walletIndex
        let run = SparkExitBackgroundRun(
            load: { try store.load() },
            makeDriver: { chain, recovering in
                SparkExitDriver(
                    chain: chain,
                    recovering: recovering,
                    makeSigner: { try Self.signer(walletIndex: walletIndex) },
                    save: { try store.save($0) }
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
            await afterTick(updated)
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
                let outcome = await SparkExitManager.shared.runInBackground(deadline: Date(timeIntervalSinceNow: seconds))
                completion.complete(success: !Task.isCancelled && outcome.record != nil)
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
        let refresh = BGAppRefreshTaskRequest(identifier: backgroundTaskId)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        let processing = BGProcessingTaskRequest(identifier: processingTaskId)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        for request in [refresh, processing] as [BGTaskRequest] {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                Logger.warn("Failed to schedule Spark exit run \(request.identifier): \(error)", context: "SparkExitManager")
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
        let planned = record.isActive ? SparkExitMath.reminders(record, tip: tipHeight, now: now, network: Env.network) : []
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
            content.title = t("lightning__spark_exit__notification_title")
            content.body = t(reminder.isFunding ? "lightning__spark_exit__notification_funding" : "lightning__spark_exit__notification_body")
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
