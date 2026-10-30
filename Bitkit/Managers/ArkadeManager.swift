import Combine
import Foundation
import LDKNode
import Observation

/// Lightning without channels, through Arkade (Ark Labs) and Arkade Intents. Savings to Spending boards on-chain funds
/// into the Arkade wallet, receives fall back to it when no channel has the inbound capacity, and sends fall back to it
/// when no channel has the outbound capacity. The wallet runs in bitkit-core's Arkade module through `ArkadeBridge`
/// and derives its keys from the Bitkit seed on its own BIP86 account (`m/86'/<coin>'/1'`).
/// Its payments reach the app as LDK events through `LightningService.emitChannelFreeRailEvent`, so the receive and
/// send flows built on node events work for both rails.
@Observable @MainActor
final class ArkadeManager: ChannelFreeLightningRail {
    static let shared = ArkadeManager()
    private nonisolated(unsafe) static let exitStateChanged = PassthroughSubject<Void, Never>()
    /// Fires once Arkade connects and whenever its outputs or swaps change, so the wallet data backup is redone.
    nonisolated static var exitStateChangedPublisher: AnyPublisher<Void, Never> {
        exitStateChanged.eraseToAnyPublisher()
    }

    /// Prefix of the activity id for a payment Arkade received outside a swap, such as an offline LNURL receive.
    nonisolated static let arkReceiveIdPrefix = "ark:"

    private(set) var isReady = false
    /// Spendable now: settled plus preconfirmed outputs.
    private(set) var balanceSats: UInt64 = 0
    /// On-chain deposits waiting to confirm or to be boarded into the next batch.
    private(set) var pendingDepositSats: UInt64 = 0
    /// Expired or swept outputs that the next renewal settles back into the balance.
    private(set) var recoverableFundsSats: UInt64 = 0
    /// On-chain deposits into Arkade, pending ones first, for the Lightning Connections screens.
    private(set) var deposits: [ArkadeDeposit] = []
    private(set) var withdrawals: [ArkadeWithdrawal] = []
    /// Unix seconds of the soonest batch expiry; the wallet renews 3 days before it.
    private(set) var nextExpiryAt: UInt64?
    private(set) var lightningAddress: String?
    /// Called after the Arkade balance or readiness was read again, so balances and the receive invoice can follow.
    var onStateChanged: (() -> Void)?

    /// Deposits this app broadcast that the Arkade wallet hasn't listed yet, by txid, so they show as pending at once.
    @ObservationIgnored private var broadcastDeposits: [String: UInt64] = [:]
    @ObservationIgnored private var info: ArkadeInfo?
    @ObservationIgnored private var walletIndex = 0
    @ObservationIgnored private var connectTask: Task<Void, Error>?
    @ObservationIgnored private lazy var bridge: ArkadeBridge = {
        let bridge = ArkadeBridge()
        bridge.onEvent = { [weak self] event in
            Task { await self?.onEvent(event) }
        }
        return bridge
    }()

    private init() {}

    var isSupported: Bool {
        Self.config != nil
    }

    var isConnected: Bool {
        info != nil
    }

    /// Arkade runs on mainnet against Ark Labs' operator; bitkit-core holds its endpoints. Its test network has no
    /// Lightning solver or LNURL server in bitkit-core, so dev builds keep Arkade off and use channels.
    nonisolated static var config: ArkadeConfig? {
        Env.network == .bitcoin ? ArkadeConfig(network: "bitcoin") : nil
    }

    /// Waits between attempts to connect the Arkade wallet when the operator or chain source is slow.
    private static let startRetryDelays: [Duration] = [.seconds(10), .seconds(30), .seconds(60)]

    func start(walletIndex: Int) async {
        guard Self.config != nil else { return }
        if info == nil {
            var connected = await tryConnect(walletIndex: walletIndex)
            for delay in Self.startRetryDelays where !connected {
                try? await Task.sleep(for: delay)
                connected = await tryConnect(walletIndex: walletIndex)
            }
            guard connected else {
                Logger.error("Failed to start Arkade wallet", context: "ArkadeManager")
                return
            }
        }
        // A connected wallet is ready even when its first refresh times out; the next event or refresh catches up.
        isReady = true
        LightningService.shared.channelFreeRail = self
        do {
            try await refresh()
        } catch {
            Logger.warn("Failed to refresh Arkade state: \(error)", context: "ArkadeManager")
        }
        await syncActivities()
        do {
            lightningAddress = try await bridge.lightningAddress()?.lightningAddress
        } catch {
            Logger.warn("Failed to get the Arkade Lightning address: \(error)", context: "ArkadeManager")
        }
    }

    private func tryConnect(walletIndex: Int) async -> Bool {
        do {
            if connectTask == nil {
                connectTask = Task { try await connect(walletIndex: walletIndex) }
            }
            try await connectTask?.value
            connectTask = nil
            return true
        } catch {
            connectTask = nil
            Logger.warn("Failed to connect the Arkade wallet: \(error)", context: "ArkadeManager")
            return false
        }
    }

    /// Starts the wallet in the bridge. The first start on an install scans the operator for the wallet's past outputs
    /// and swaps, which a wallet restored from its phrase needs, and a restored backup is imported before the wallet
    /// opens its databases.
    private func connect(walletIndex: Int) async throws {
        guard let config = Self.config else { throw ArkadeError.unsupported }
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        let restoreFile = Env.arkadeExitRestore(walletIndex: walletIndex)
        let backup = FileManager.default.contents(atPath: restoreFile.path).map { String(decoding: $0, as: UTF8.self) }
        let startedMarker = Env.arkadeStartedMarker(walletIndex: walletIndex)
        let params = ArkadeStartParams(
            dataDir: Env.arkadeStorage(walletIndex: walletIndex).path,
            mnemonic: mnemonic,
            passphrase: passphrase,
            network: config.network,
            restore: !FileManager.default.fileExists(atPath: startedMarker.path),
            backup: backup
        )
        info = try await bridge.start(params)
        self.walletIndex = walletIndex
        try FileManager.default.createDirectory(at: startedMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(Date().timeIntervalSince1970)".utf8).write(to: startedMarker, options: .atomic)
        if backup != nil {
            try? FileManager.default.removeItem(at: restoreFile)
            Logger.info("Imported Arkade wallet data from backup", context: "ArkadeManager")
        }
        Logger.info("Connected Arkade wallet on '\(config.network)'", context: "ArkadeManager")
        Self.exitStateChanged.send()
    }

    func wipe(walletIndex: Int) async {
        if LightningService.shared.channelFreeRail === self {
            LightningService.shared.channelFreeRail = nil
        }
        do {
            try await bridge.wipe(dataDir: Env.arkadeStorage(walletIndex: walletIndex).path)
        } catch {
            Logger.warn("Failed to wipe Arkade storage: \(error)", context: "ArkadeManager")
        }
        try? FileManager.default.removeItem(at: Env.arkadeExitRestore(walletIndex: walletIndex))
        try? FileManager.default.removeItem(at: Env.arkadeStartedMarker(walletIndex: walletIndex))
        info = nil
        connectTask = nil
        isReady = false
        balanceSats = 0
        pendingDepositSats = 0
        recoverableFundsSats = 0
        deposits = []
        withdrawals = []
        nextExpiryAt = nil
        lightningAddress = nil
        broadcastDeposits = [:]
    }

    // MARK: ChannelFreeLightningRail

    /// An invoice for exactly `amountSats` through Arkade's Lightning solver. Without an amount there is no invoice:
    /// the wallet's Lightning address takes amountless payments instead, so its LNURL is returned.
    nonisolated func receive(amountSats: UInt64?, description: String, expirySecs: UInt32) async throws -> String {
        try await createInvoice(amountSats: amountSats)
    }

    private func createInvoice(amountSats: UInt64?) async throws -> String {
        guard let amountSats, amountSats > 0 else {
            guard let address = try await bridge.lightningAddress() else {
                throw ArkadeError.bridge("Arkade has no Lightning address")
            }
            lightningAddress = address.lightningAddress
            return address.lnurl
        }
        let swap = try await bridge.receive(amountSats: amountSats)
        guard let bolt11 = swap.bolt11 else { throw ArkadeError.bridge("Arkade returned no invoice") }
        return bolt11
    }

    /// Pays `bolt11` and returns its payment hash, the id LDK payments use, so the send flow can match it. Returns once
    /// the lockup is funded; the outcome arrives as a swap event.
    nonisolated func send(bolt11: String, sats: UInt64?) async throws -> PaymentHash {
        guard Self.invoiceAmountSats(bolt11) != nil else {
            throw ArkadeError.bridge("Arkade can't pay an invoice without an amount, '\(sats.map(String.init) ?? "nil")' sats asked")
        }
        let paymentHash = try Bolt11Invoice.fromStr(invoiceStr: bolt11).paymentHash()
        try await pay(bolt11: bolt11)
        return paymentHash
    }

    private func pay(bolt11: String) async throws {
        let swap = try await bridge.pay(bolt11: bolt11)
        Logger.info("Funded Arkade payment '\(swap.id ?? "")' with outcome '\(swap.outcome ?? "")'", context: "ArkadeManager")
        await recordSwap(swap)
        try await refresh()
    }

    nonisolated func lightningPayments() async -> [ChannelFreeRailPayment] {
        await listSwaps().compactMap(Self.railPayment)
    }

    /// The solver's fee for paying `bolt11`: the difference between the lockup and the invoice amount.
    nonisolated func estimateRoutingFees(bolt11: String, amountSats: UInt64?) async throws -> UInt64 {
        if amountSats != nil, Self.invoiceAmountSats(bolt11) == nil {
            throw ArkadeError.bridge("AmountlessInvoice")
        }
        return try await UInt64(max(0, quotePay(bolt11: bolt11).feeSat))
    }

    private func quotePay(bolt11: String) async throws -> ArkadePayQuote {
        try await bridge.quotePay(bolt11: bolt11)
    }

    private nonisolated static func invoiceAmountSats(_ bolt11: String) -> UInt64? {
        (try? Bolt11Invoice.fromStr(invoiceStr: bolt11).amountMilliSatoshis()).flatMap { $0 }.map { $0 / 1000 }
    }

    // MARK: Transfers

    /// The on-chain boarding address that funds the Arkade wallet; a deposit is boarded once it confirms.
    func depositAddress() async throws -> String {
        try await bridge.info().boardingAddress
    }

    /// What the operator charges to board a deposit: its fee formula has no on-chain input term, so 0 today.
    func boardingFeeSats() -> UInt64 {
        0
    }

    /// Moves the whole Arkade balance to the on-chain `address` in the next batch, for Spending to Savings.
    func withdrawAll(to address: String) async throws {
        let txid = try await bridge.offboard(address: address)
        Logger.info("Offboarded Arkade balance in '\(txid)'", context: "ArkadeManager")
        try await refresh()
    }

    /// The wallet data backup, or nil while Arkade is not connected and there is nothing to back up.
    func exitBackup() async throws -> ArkadeExitBackupV1? {
        guard isConnected, let config = Self.config else { return nil }
        return try await ArkadeExitBackupV1(
            version: 1,
            createdAt: UInt64(Date().timeIntervalSince1970 * 1000),
            network: config.network,
            exitState: bridge.exportState()
        )
    }

    /// Puts restored wallet data back before the Arkade wallet next opens its databases, and has it scan the operator
    /// again on that start for outputs and swaps the backup missed.
    func restoreExitBackup(_ backup: ArkadeExitBackupV1, walletIndex: Int) async throws {
        guard let config = Self.config, backup.network == config.network else {
            Logger.warn("Skipped Arkade wallet data from network '\(backup.network)'", context: "ArkadeManager")
            return
        }
        let file = Env.arkadeExitRestore(walletIndex: walletIndex)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(backup.exitState.utf8).write(to: file, options: .atomic)
        try? FileManager.default.removeItem(at: Env.arkadeStartedMarker(walletIndex: walletIndex))
        if isConnected {
            info = nil
            isReady = false
            try await bridge.reload()
            await start(walletIndex: walletIndex)
        }
    }

    /// Lists a deposit the app just broadcast as pending right away, then boards it once it confirms.
    func onDepositBroadcast(txid: String, amountSats: UInt64) {
        broadcastDeposits[txid] = amountSats
        applyBroadcastDeposits()
        onStateChanged?()
        Task { await refreshState() }
    }

    private func applyBroadcastDeposits() {
        let known = Set(deposits.map(\.txid))
        let local = broadcastDeposits
            .filter { !known.contains($0.key) }
            .map { ArkadeDeposit(txid: $0.key, amountSats: $0.value, isClaimed: false, confirmations: 0) }
        guard !local.isEmpty else { return }
        deposits = local + deposits
        pendingDepositSats = deposits.filter { !$0.isClaimed }.reduce(0) { $0 + $1.amountSats }
    }

    /// Reads the Arkade balance and deposits again, for pull to refresh and the deposit screen.
    func refreshState() async {
        guard isConnected else { return }
        do {
            try await refresh()
        } catch {
            Logger.warn("Failed to refresh Arkade state: \(error)", context: "ArkadeManager")
        }
    }

    private func refresh() async throws {
        let balance = try await bridge.balance()
        let history = try await bridge.history()
        let vtxos = try await bridge.vtxos()
        let pending = UInt64(max(0, balance.boardingConfirmed + balance.boardingUnconfirmed))
        let available = UInt64(max(0, balance.available))
        let changed = !isReady || balanceSats != available || pendingDepositSats != pending
        isReady = true
        balanceSats = available
        pendingDepositSats = pending
        recoverableFundsSats = UInt64(max(0, balance.recoverable))
        deposits = Self.deposits(history)
        withdrawals = Self.withdrawals(history)
        nextExpiryAt = Self.nextExpiry(vtxos)
        for deposit in deposits where deposit.isClaimed {
            broadcastDeposits[deposit.txid] = nil
        }
        applyBroadcastDeposits()
        deposits = await Self.withConfirmations(deposits)
        if changed {
            onStateChanged?()
        }
        for txId in deposits.map(\.txid) + withdrawals.map(\.txid) {
            await CoreService.shared.activity.markOnchainActivityAsTransfer(txId: txId)
        }
        Self.exitStateChanged.send()
    }

    /// On-chain deposits: boarding entries of the wallet's history, boarded once settled.
    nonisolated static func deposits(_ history: [ArkadeHistoryEntry]) -> [ArkadeDeposit] {
        let deposits = history.compactMap { entry -> ArkadeDeposit? in
            guard let txid = entry.boardingTxid, entry.type == ArkadeHistoryEntry.received else { return nil }
            return ArkadeDeposit(txid: txid, amountSats: UInt64(max(0, entry.amount)), isClaimed: entry.settled)
        }
        return deposits.filter { !$0.isClaimed } + deposits.filter(\.isClaimed)
    }

    /// Transfers to Savings: sends settled in a batch's commitment transaction without an Arkade transaction.
    nonisolated static func withdrawals(_ history: [ArkadeHistoryEntry]) -> [ArkadeWithdrawal] {
        history.compactMap { entry in
            guard entry.type == ArkadeHistoryEntry.sent, let txid = entry.commitmentTxid, entry.arkTxid == nil else { return nil }
            return ArkadeWithdrawal(txid: txid, amountSats: UInt64(max(0, entry.amount)), feeSats: 0)
        }
    }

    /// Unix seconds of the soonest expiry of an unswept output; the bridge may report it in milliseconds.
    nonisolated static func nextExpiry(_ vtxos: [ArkadeVtxo]) -> UInt64? {
        guard let expiry = vtxos.filter({ $0.isSwept != true }).compactMap(\.batchExpiry).min(), expiry > 0 else { return nil }
        return UInt64(expiry > 1_000_000_000_000 ? expiry / 1000 : expiry)
    }

    private static func withConfirmations(_ deposits: [ArkadeDeposit]) async -> [ArkadeDeposit] {
        guard deposits.contains(where: { !$0.isClaimed }) else { return deposits }
        let confirmations = await onchainConfirmations()
        return deposits.map { deposit in
            guard !deposit.isClaimed else { return deposit }
            var pending = deposit
            pending.confirmations = confirmations[deposit.txid] ?? nil
            return pending
        }
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

    // MARK: Swaps and history

    private nonisolated func listSwaps() async -> [ArkadeSwap] {
        do {
            return try await bridgeSwaps()
        } catch {
            Logger.warn("Failed to list Arkade swaps: \(error)", context: "ArkadeManager")
            return []
        }
    }

    private func bridgeSwaps() async throws -> [ArkadeSwap] {
        guard isConnected else { return [] }
        return try await bridge.swaps()
    }

    private func syncActivities() async {
        for swap in await listSwaps() {
            await recordSwap(swap)
        }
    }

    private func onEvent(_ event: ArkadeBridgeEvent) async {
        do {
            switch event {
            case let .swap(swap):
                Logger.info("Arkade swap '\(swap.id ?? "")' is '\(swap.outcome ?? "")'", context: "ArkadeManager")
                await recordSwap(swap)
                try await refresh()
                if let event = Self.nodeEvent(for: swap) {
                    LightningService.shared.emitChannelFreeRailEvent(event)
                }
            case let .history(entries):
                try await onHistory(entries)
            }
        } catch {
            Logger.error("Failed to handle Arkade event: \(error)", context: "ArkadeManager")
        }
    }

    /// A payment that reached the wallet outside this client's swaps: an offline receive the LNURL server claimed, or a
    /// payment straight to the Arkade address. Boarding and swap claims show up through their own records.
    private func onHistory(_ entries: [ArkadeHistoryEntry]) async throws {
        try await refresh()
        let swapClaims = await Set(listSwaps().filter(\.isReceive).compactMap(\.takeSat))
        for entry in Self.offlineReceives(entries, swapClaims: swapClaims) {
            guard let arkTxid = entry.arkTxid else { continue }
            let id = Self.arkReceiveIdPrefix + arkTxid
            if try await CoreService.shared.activity.getActivity(id: id) != nil {
                continue
            }
            let amountMsat = UInt64(max(0, entry.amount)) * 1000
            let details = PaymentDetails(
                id: id,
                kind: .bolt11(hash: id, preimage: nil, secret: nil, description: nil, bolt11: nil),
                amountMsat: amountMsat,
                feePaidMsat: 0,
                direction: .inbound,
                status: .succeeded,
                latestUpdateTimestamp: UInt64(max(0, entry.createdAt / 1000))
            )
            try await CoreService.shared.activity.recordChannelFreeRailPayment(details)
            Logger.info("Recorded Arkade receive '\(id)' of '\(entry.amount)' sats", context: "ArkadeManager")
            LightningService.shared.emitChannelFreeRailEvent(
                .paymentReceived(paymentId: id, paymentHash: id, amountMsat: amountMsat, customRecords: [])
            )
        }
    }

    /// History entries received outside a swap and outside boarding, which no other record covers.
    nonisolated static func offlineReceives(_ entries: [ArkadeHistoryEntry], swapClaims: Set<Int64>) -> [ArkadeHistoryEntry] {
        entries.filter {
            $0.type == ArkadeHistoryEntry.received && $0.boardingTxid == nil && $0.arkTxid != nil && !swapClaims.contains($0.amount)
        }
    }

    private func recordSwap(_ swap: ArkadeSwap) async {
        guard let details = Self.paymentDetails(for: swap) else { return }
        do {
            try await CoreService.shared.activity.recordChannelFreeRailPayment(details)
        } catch {
            Logger.error("Failed to record Arkade swap '\(swap.id ?? "")': \(error)", context: "ArkadeManager")
        }
    }

    /// The swap as an LDK payment, for its activity; a receive is recorded only once claimed.
    nonisolated static func paymentDetails(for swap: ArkadeSwap) -> PaymentDetails? {
        guard let hash = swap.paymentHash, let status = ldkStatus(swap), swap.isSend || status == .succeeded else { return nil }
        let timestamp = swap.updatedAt ?? swap.createdAt ?? Int64(Date().timeIntervalSince1970)
        return PaymentDetails(
            id: hash,
            kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: swap.bolt11),
            amountMsat: UInt64(max(0, swap.takeSat ?? 0)) * 1000,
            feePaidMsat: UInt64(max(0, swap.feeSat ?? 0)) * 1000,
            direction: swap.isSend ? .outbound : .inbound,
            status: status,
            latestUpdateTimestamp: UInt64(max(0, timestamp))
        )
    }

    nonisolated static func railPayment(_ swap: ArkadeSwap) -> ChannelFreeRailPayment? {
        guard let hash = swap.paymentHash, swap.isSend || swap.isReceive, let status = ldkStatus(swap) else { return nil }
        return ChannelFreeRailPayment(paymentHash: hash.lowercased(), direction: swap.isSend ? .outbound : .inbound, status: status, preimage: nil)
    }

    nonisolated static func nodeEvent(for swap: ArkadeSwap) -> Event? {
        guard let hash = swap.paymentHash else { return nil }
        switch (swap.isReceive, swap.isSend, ldkStatus(swap)) {
        case (true, _, .succeeded):
            return .paymentReceived(
                paymentId: hash,
                paymentHash: hash,
                amountMsat: UInt64(max(0, swap.takeSat ?? 0)) * 1000,
                customRecords: []
            )
        case (_, true, .succeeded):
            return .paymentSuccessful(
                paymentId: hash,
                paymentHash: hash,
                paymentPreimage: nil,
                feePaidMsat: UInt64(max(0, swap.feeSat ?? 0)) * 1000
            )
        case (_, true, .failed):
            return .paymentFailed(paymentId: hash, paymentHash: hash, reason: .unexpectedError)
        default:
            return nil
        }
    }

    /// A receive succeeds once claimed and a send once paid; a send that was refunded, cancelled or failed failed.
    private nonisolated static func ldkStatus(_ swap: ArkadeSwap) -> PaymentStatus? {
        switch swap.outcome {
        case ArkadeSwap.claimed, ArkadeSwap.paid: .succeeded
        case let outcome? where ArkadeSwap.failedSendOutcomes.contains(outcome): .failed
        case .some: .pending
        case nil: nil
        }
    }
}

struct ArkadeConfig {
    let network: String
}

/// An on-chain deposit into Arkade: pending until it confirms and the wallet boards it into a batch.
struct ArkadeDeposit: Identifiable, Equatable {
    let txid: String
    let amountSats: UInt64
    let isClaimed: Bool
    /// On-chain confirmations, known for deposits this wallet sent.
    var confirmations: UInt32?

    var id: String {
        "\(txid)-\(isClaimed)"
    }
}

/// A Transfer to Savings out of Arkade, offboarded in a batch.
struct ArkadeWithdrawal: Identifiable, Equatable {
    let txid: String
    let amountSats: UInt64
    let feeSats: UInt64

    var id: String {
        txid
    }
}

enum ArkadeError: LocalizedError {
    case unsupported
    case notConnected
    case bridge(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "Arkade is not available on this network"
        case .notConnected: "Arkade wallet is not connected"
        case let .bridge(message): message
        }
    }
}
