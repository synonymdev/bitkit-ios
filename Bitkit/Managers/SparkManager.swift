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

    private static let depositClaimFeeLeewaySatPerVbyte: UInt64 = 2
    private static let depositClaimFeePpm: UInt32 = 2000

    private(set) var isReady = false
    private(set) var balanceSats: UInt64 = 0
    /// Deposits seen on-chain that Spark claims into `balanceSats` after 3 confirmations.
    private(set) var pendingDepositSats: UInt64 = 0
    private(set) var recoverableFundsSats: UInt64 = 0
    /// On-chain deposits into Spark, pending ones first, for the Lightning Connections screens.
    private(set) var deposits: [SparkDeposit] = []
    /// Called when Spark claims on-chain deposits, which completes a Savings to Spending transfer.
    var onDepositsClaimed: (() -> Void)?
    /// Called after the Spark balance or readiness was read again, so balances and the receive invoice can follow.
    var onStateChanged: (() -> Void)?

    /// Deposits this app broadcast that Spark hasn't listed yet, by txid, so they show as pending at once.
    @ObservationIgnored private var broadcastDeposits: [String: UInt64] = [:]
    @ObservationIgnored private var sdk: BreezSdk?
    @ObservationIgnored private var listenerId: String?
    @ObservationIgnored private var connectTask: Task<Void, Error>?

    private init() {}

    var isSupported: Bool {
        Self.sparkNetwork != nil
    }

    var isConnected: Bool {
        sdk != nil
    }

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
        do {
            if sdk == nil {
                if connectTask == nil {
                    connectTask = Task { try await connect(walletIndex: walletIndex, network: network) }
                }
                try await connectTask?.value
                connectTask = nil
            }
            try await refresh()
            try await syncActivities()
            LightningService.shared.channelFreeRail = self
        } catch {
            connectTask = nil
            Logger.error("Failed to start Spark wallet: \(error)", context: "SparkManager")
        }
    }

    private func connect(walletIndex: Int, network: BreezSdkSpark.Network) async throws {
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        var config = defaultConfig(network: network)
        config.apiKey = Env.breezApiKey
        config.maxDepositClaimFee = MaxFee(
            onchain: .networkRecommended(leewaySatPerVbyte: Self.depositClaimFeeLeewaySatPerVbyte),
            proportionalPpm: Self.depositClaimFeePpm
        )
        let storageDir = Env.sparkStorage(walletIndex: walletIndex)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        let connected = try await BreezSdkSpark.connect(request: ConnectRequest(
            config: config,
            seed: .mnemonic(mnemonic: mnemonic, passphrase: passphrase),
            storageDir: storageDir.path
        ))
        listenerId = await connected.addEventListener(listener: SparkEventListener { [weak self] event in
            await self?.onSdkEvent(event)
        })
        sdk = connected
        Logger.info("Connected Spark wallet on '\(network)'", context: "SparkManager")
        await importRestoredExitState(walletIndex: walletIndex)
        Self.exitStateChanged.send()
    }

    func wipe(walletIndex: Int) async {
        if LightningService.shared.channelFreeRail === self {
            LightningService.shared.channelFreeRail = nil
        }
        if let sdk {
            if let listenerId {
                _ = await sdk.removeEventListener(id: listenerId)
            }
            try? await sdk.disconnect()
        }
        sdk = nil
        listenerId = nil
        isReady = false
        balanceSats = 0
        pendingDepositSats = 0
        recoverableFundsSats = 0
        deposits = []
        try? FileManager.default.removeItem(at: Env.sparkStorage(walletIndex: walletIndex))
    }

    // MARK: ChannelFreeLightningRail

    nonisolated func receive(amountSats: UInt64?, description: String, expirySecs: UInt32) async throws -> String {
        let method = ReceivePaymentMethod.bolt11Invoice(
            description: description,
            amountSats: amountSats,
            expirySecs: expirySecs,
            paymentHash: nil,
            receiverIdentityPublicKey: nil
        )
        return try await requireSdk().receivePayment(request: ReceivePaymentRequest(paymentMethod: method)).paymentRequest
    }

    nonisolated func send(bolt11: String, sats: UInt64?) async throws -> PaymentHash {
        let prepared = try await prepareSend(paymentRequest: bolt11, amountSats: sats)
        guard case let .bolt11Invoice(invoiceDetails, _, _) = prepared.paymentMethod else {
            throw AppError(message: "Unexpected Spark payment method", debugMessage: "\(prepared.paymentMethod)")
        }
        let response = try await requireSdk().sendPayment(request: SendPaymentRequest(
            prepareResponse: prepared,
            options: Self.bolt11SendOptions
        ))
        Logger.info("Sent Spark payment '\(response.payment.id)' with status '\(response.payment.status)'", context: "SparkManager")
        return invoiceDetails.paymentHash
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
    private static let claimTxSizeVbytes: UInt64 = 99

    /// Estimates what Spark keeps from a deposit to claim it, the way the SDK does before the provider quotes it.
    func estimateDepositClaimFeeSats() async throws -> UInt64 {
        try await requireSdk().recommendedFees().fastestFee * Self.claimTxSizeVbytes
    }

    /// Moves the whole Spark balance to the on-chain `address`, fees included, for Spending to Savings.
    func withdrawAll(to address: String) async throws {
        let prepared = try await prepareSend(paymentRequest: address, amountSats: balanceSats, feePolicy: .feesIncluded)
        _ = try await requireSdk().sendPayment(request: SendPaymentRequest(
            prepareResponse: prepared,
            options: .bitcoinAddress(confirmationSpeed: .medium)
        ))
        try await refresh()
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
                    + "'\(imported.skippedConflictingLeaves)' conflicting",
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
            throw AppError(message: "Spark wallet is not connected", debugMessage: nil)
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

    private func refresh() async throws {
        let sdk = try await requireSdk()
        let info = try await sdk.getInfo(request: GetInfoRequest(ensureSynced: false))
        let unclaimed = try await sdk.listUnclaimedDeposits(request: ListUnclaimedDepositsRequest()).deposits
        let claimed = try await sdk.listPayments(request: ListPaymentsRequest()).payments
            .filter { $0.method == .deposit && $0.status == .completed }
        let pending = unclaimed.reduce(0) { $0 + $1.amountSats }
        let changed = !isReady || balanceSats != info.balanceSats || pendingDepositSats != pending
        isReady = true
        balanceSats = info.balanceSats
        pendingDepositSats = pending
        recoverableFundsSats = info.recoverableFundsSats
        deposits = await Self.deposits(unclaimed: unclaimed, claimed: claimed)
        for deposit in deposits {
            broadcastDeposits[deposit.txid] = nil
        }
        applyBroadcastDeposits()
        if changed {
            onStateChanged?()
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

    private func syncActivities() async throws {
        let payments = try await requireSdk().listPayments(request: ListPaymentsRequest()).payments
        for payment in payments {
            await recordActivity(payment)
        }
    }

    private func onSdkEvent(_ event: SdkEvent) async {
        do {
            switch event {
            case .synced, .newDeposits:
                try await refresh()
            case .claimedDeposits:
                try await refresh()
                onDepositsClaimed?()
            case let .unclaimedDeposits(deposits):
                Logger.warn("Found '\(deposits.count)' unclaimed Spark deposits", context: "SparkManager")
            case let .paymentSucceeded(payment), let .paymentFailed(payment):
                try await refresh()
                await recordActivity(payment)
                if let event = Self.nodeEvent(for: payment) {
                    LightningService.shared.emitChannelFreeRailEvent(event)
                }
            case let .paymentPending(payment):
                await recordActivity(payment)
            case .unilateralExitStateChanged:
                Self.exitStateChanged.send()
            default:
                break
            }
        } catch {
            Logger.error("Failed to handle Spark event '\(event)': \(error)", context: "SparkManager")
        }
    }

    private func recordActivity(_ payment: Payment) async {
        guard case let .lightning(description, invoice, _, htlcDetails, _, _, _, _) = payment.details else { return }
        if payment.status == .pending, payment.paymentType == .receive {
            return
        }
        let state: PaymentState = switch payment.status {
        case .completed: .succeeded
        case .pending: .pending
        case .failed: .failed
        }
        let activity = LightningActivity(
            walletId: WalletScope.default,
            id: htlcDetails.paymentHash,
            txType: payment.paymentType == .send ? .sent : .received,
            status: state,
            value: Self.sats(payment.amount),
            fee: Self.sats(payment.fees),
            invoice: invoice,
            message: description ?? "",
            timestamp: payment.timestamp,
            preimage: htlcDetails.preimage,
            contact: nil,
            createdAt: payment.timestamp,
            updatedAt: payment.timestamp,
            seenAt: nil
        )
        do {
            try await CoreService.shared.activity.upsert(.lightning(activity))
        } catch {
            Logger.error("Failed to record Spark payment '\(payment.id)': \(error)", context: "SparkManager")
        }
    }

    private static func nodeEvent(for payment: Payment) -> Event? {
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

    private static func sats(_ value: U128) -> UInt64 {
        UInt64(value.description) ?? 0
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

private final class SparkEventListener: BreezSdkSpark.EventListener, @unchecked Sendable {
    private let handler: @Sendable (SdkEvent) async -> Void

    init(handler: @escaping @Sendable (SdkEvent) async -> Void) {
        self.handler = handler
    }

    func onEvent(event: SdkEvent) async {
        await handler(event)
    }
}
