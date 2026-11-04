import BackgroundTasks
import BitkitCore
import BreezSdkSpark
import Foundation
import Observation
import UserNotifications

/// Runs a Spark emergency exit: the quote, the fee funding, then the driver until every step is on-chain. The exit
/// survives restarts through `SparkExitStore`, and is driven while Bitkit is open, by a background refresh, and
/// after a notification brings the user back when a timelock matures.
@Observable @MainActor
final class SparkExitManager {
    static let shared = SparkExitManager()
    nonisolated static let backgroundTaskId = "to.bitkit.spark-exit"
    private nonisolated static let notificationId = "spark-exit"
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
        if let record {
            Task { await settleIfFinished(record) }
        }
    }

    /// Forgets the exit of a wallet being wiped.
    func wipe() {
        try? store.delete()
        record = nil
        quote = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationId])
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
        // Every tick asks for the next background refresh, so one failed or skipped tick never ends the chain.
        defer {
            if isExiting {
                Self.scheduleBackgroundRefresh()
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
            await afterTick(updated, previous: current)
        } catch {
            lastError = error.localizedDescription
            Logger.error("Spark exit tick failed: \(error)", context: "SparkExitManager")
        }
    }

    private func afterTick(_ record: SparkExitRecord, previous: SparkExitRecord) async {
        if let transferId = record.transferId {
            try? TransferStorage.shared.updateClaimableAtHeight(id: transferId, claimableAtHeight: record.claimableAtHeight)
        }
        await settleIfFinished(record)
        scheduleNotification(record, previous: previous)
        if !record.isActive {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationId])
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

    private func reattachSpark() async {
        let spark = SparkManager.shared
        await spark.refreshState()
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
        Logger.info("Started Spark exit of \(quote.exitSats) sats over \(quote.leafIds.count) leaves", context: "SparkExitManager")

        if fundFromSavings, quote.fundingSats > 0 {
            try await payFunding(address: key.address, sats: quote.fundingSats, satsPerVbyte: savingsFeeRate, feeSats: savingsFeeSats)
        }
        Task { await tick() }
    }

    /// Pays the fee funding from savings, as a transfer activity.
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
        await CoreService.shared.activity.markOnchainActivityAsTransfer(txId: txid)
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

    /// Registers the refresh that drives an exit while Bitkit is closed. Must run before launch finishes.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskId, using: nil) { task in
            let work = Task { @MainActor in
                let manager = SparkExitManager.shared
                if manager.record == nil {
                    manager.load(walletIndex: UserDefaults.standard.integer(forKey: walletIndexKey))
                }
                await manager.tick()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = {
                work.cancel()
                task.setTaskCompleted(success: false)
            }
        }
    }

    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Logger.warn("Failed to schedule the Spark exit refresh: \(error)", context: "SparkExitManager")
        }
    }

    /// Brings the user back when the next timelock matures, a while later when steps are waiting to be published
    /// (the operators' version of a matured step can land about 50 blocks after it), and once when the exit needs
    /// more fee funding.
    private func scheduleNotification(_ record: SparkExitRecord, previous: SparkExitRecord) {
        let center = UNUserNotificationCenter.current()
        let seconds: TimeInterval
        switch record.phase {
        case .needsFunding:
            if case .needsFunding = previous.phase {
                return
            }
            seconds = 1
        case .running:
            if let target = record.claimableAtHeight, let tipHeight, target > tipHeight {
                seconds = SparkExitMath.secondsUntil(height: target, tip: tipHeight, network: Env.network)
            } else {
                seconds = SparkExitMath.reminderSeconds(network: Env.network)
            }
        default:
            return
        }
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationId])
        let content = UNMutableNotificationContent()
        content.title = t("lightning__spark_exit__notification_title")
        content.body = t("lightning__spark_exit__notification_body")
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        center.add(UNNotificationRequest(identifier: Self.notificationId, content: content, trigger: trigger))
    }
}
