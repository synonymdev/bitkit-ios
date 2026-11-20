import BitkitCore
import Combine
import Foundation
import LDKNode

/// The amounts behind moving the channels' balance to Spark, kept apart so they can be tested without a node.
enum MoveToSparkMath {
    /// The move invoice's description.
    static let invoiceDescription = "Move to Spark"
    /// Below this a move is not offered: what is left is about the routing fee.
    static let minMoveSats: UInt64 = 1000
    /// The fee guessed for the first quote of a full move, as a share of the amount in parts per million.
    private static let firstFeeGuessPpm: UInt64 = 5000
    /// The least fee guessed for the first quote of a full move.
    private static let minFeeGuessSats: UInt64 = 10
    /// Room left above the quoted fee, in sats, for the fee moving between the quote and the payment.
    private static let feeMarginSats: UInt64 = 2

    static func movableSats(channels: [ChannelDetails]?) -> UInt64 {
        (channels ?? []).filter(\.isUsable).map { $0.nextOutboundHtlcLimitMsat / 1000 }.reduce(0, +)
    }

    /// Whether Spark can take a move; every Move to Spark check goes through here.
    @MainActor
    static func isSparkUsable(_ spark: SparkManager) -> Bool {
        isSparkUsable(isReady: spark.isReady, isExiting: spark.isExiting)
    }

    /// Spark takes no move during an emergency exit, which is sweeping its funds to savings.
    static func isSparkUsable(isReady: Bool, isExiting: Bool) -> Bool {
        isReady && !isExiting
    }

    /// Whether the channels hold a balance worth moving to a usable Spark wallet.
    static func canMove(channels: [ChannelDetails]?, isSparkUsable: Bool) -> Bool {
        isSparkUsable && hasMovableBalance(limitSats: movableSats(channels: channels))
    }

    /// Whether `limitSats` still leaves at least `minMoveSats` to quote once the first fee guess is reserved.
    static func hasMovableBalance(limitSats: UInt64) -> Bool {
        firstCandidate(wantedSats: limitSats, limitSats: limitSats) >= minMoveSats
    }

    /// The first amount to quote: `wantedSats` when it leaves room for fees, else the limit less a guessed fee.
    static func firstCandidate(wantedSats: UInt64, limitSats: UInt64) -> UInt64 {
        let guessSats = max(limitSats.multipliedReportingOverflow(by: firstFeeGuessPpm).partialValue / 1_000_000, minFeeGuessSats)
        return min(wantedSats, amountAfterFee(limitSats: limitSats, feeSats: guessSats))
    }

    /// The amount that fits under `limitSats` together with `feeSats` and its margin.
    static func amountAfterFee(limitSats: UInt64, feeSats: UInt64) -> UInt64 {
        let reserved = feeSats.addingReportingOverflow(feeMarginSats)
        return reserved.overflow || reserved.partialValue >= limitSats ? 0 : limitSats - reserved.partialValue
    }

    /// The routing fee to show for an estimate: the estimate and its margin, which also covers the estimate's rounding.
    static func quotedFeeSats(estimateSats: UInt64) -> UInt64 {
        estimateSats + feeMarginSats
    }

    /// The routing fee cap for the payment: exactly the quoted fee, so it never pays more than shown.
    static func feeCapMsat(feeSats: UInt64) -> UInt64 {
        feeSats * 1000
    }

    /// The most parts one move pays.
    static let maxParts = 16

    /// How many parts of `part` the balance under `limitSats` takes, at most `maxParts`: each takes its amount and fee,
    /// and a rest that cannot be moved takes none.
    static func partCount(limitSats: UInt64, part: MoveToSparkPart) -> UInt64 {
        let stepSats = part.amountSats + part.feeSats
        guard stepSats > 0 else { return 1 }
        var count: UInt64 = 1
        var restSats = limitSats - min(limitSats, stepSats)
        while hasMovableBalance(limitSats: restSats), count < UInt64(maxParts) {
            count += 1
            restSats -= min(restSats, stepSats)
        }
        return count
    }

    /// The next amount to try after one did not route: half of it, or nothing below the minimum.
    static func smallerAmount(_ sats: UInt64) -> UInt64? {
        let half = sats / 2
        return half >= minMoveSats ? half : nil
    }

    /// The open channels in `after` that could send at least `minMoveSats` in `before` and no longer can. None while
    /// `payments` holds an outbound Lightning payment in flight, or can't be read: its HTLC lowers a channel's send limit
    /// until it settles, so a channel the move did not empty could look emptied. An on-chain send holds no HTLC.
    static func emptiedChannels(before: [ChannelDetails], after: [ChannelDetails]?, payments: [PaymentDetails]?) -> [ChannelDetails] {
        guard let payments, !payments.contains(where: isLightningInFlight) else { return [] }
        let beforeById = Dictionary(before.map { ($0.channelId, $0) }, uniquingKeysWith: { first, _ in first })
        return (after ?? []).filter(\.isChannelReady).filter {
            guard let was = beforeById[$0.channelId] else { return false }
            return was.nextOutboundHtlcLimitMsat / 1000 >= minMoveSats && $0.nextOutboundHtlcLimitMsat / 1000 < minMoveSats
        }
    }

    /// Whether a channel's send limit may still be held under the minimum by the move's settled HTLC counting against the
    /// peer's in-flight cap, which clears, rather than by what stays. ldk-node exposes neither the HTLCs nor the channel
    /// type, so it can be ruled out only when the capacity itself is under the minimum, or when the limit read is, within
    /// a sat, the one LDK leaves on a channel we funded once its HTLCs clear, for an anchor or a legacy commitment.
    static func mayHoldTheMoveHtlc(_ channel: ChannelDetails) -> Bool {
        guard channel.outboundCapacityMsat / 1000 >= minMoveSats else { return false }
        guard channel.isOutbound else { return true }
        let limitSats = Int64(channel.nextOutboundHtlcLimitMsat / 1000)
        return ![false, true].contains { isLegacy in
            let predictedSats = clearedLimitMsat(
                capacityMsat: Int64(channel.outboundCapacityMsat),
                feerate: Int64(channel.feerateSatPer1000Weight),
                isLegacy: isLegacy
            ) / 1000
            return abs(limitSats - predictedSats) <= 1
        }
    }

    /// The send limit LDK 0.2 leaves on a channel we funded with no HTLCs pending (`get_available_balances_for_scope`):
    /// capacity less the commitment fee for an above-dust HTLC and its fee spike buffer HTLC, doubled for a legacy
    /// commitment; under the dust limit it reserves one HTLC less and stays under the limit. The dust limit is LDK's
    /// default 354 sats, plus the HTLC timeout transaction's fee on a legacy commitment.
    static func clearedLimitMsat(capacityMsat: Int64, feerate: Int64, isLegacy: Bool) -> Int64 {
        let baseWeight: Int64 = isLegacy ? 724 : 1124
        func feeMsat(htlcs: Int64) -> Int64 {
            feerate * (baseWeight + htlcs * 172) / 1000 * 1000 * (isLegacy ? 2 : 1)
        }
        let dustMsat = ((isLegacy ? feerate * 663 / 1000 : 0) + 354) * 1000
        let aboveDust = capacityMsat - feeMsat(htlcs: 2)
        guard aboveDust < dustMsat else { return aboveDust }
        return max(0, min(capacityMsat - feeMsat(htlcs: 1), dustMsat - 1, capacityMsat))
    }

    /// Whether `channel` can close: its capacity is under the minimum, or its reserve explains its limit in this read and
    /// in the one before (`previous`), unchanged. One read can match a reserve by chance while the move's HTLC still
    /// counts against the peer's cap; the HTLC clears within the recheck, so a reading that holds across it is what stays.
    static func isEmptiedForGood(_ channel: ChannelDetails, previous: [ChannelDetails]?) -> Bool {
        guard channel.outboundCapacityMsat / 1000 >= minMoveSats else { return true }
        guard !mayHoldTheMoveHtlc(channel), let was = previous?.first(where: { $0.channelId == channel.channelId }) else { return false }
        return was.outboundCapacityMsat == channel.outboundCapacityMsat && was.nextOutboundHtlcLimitMsat == channel.nextOutboundHtlcLimitMsat
    }

    /// The payments read before and after a read of the channels, or nil when a read failed or an outbound Lightning
    /// payment appeared or changed between them: it may have held an HTLC while the channels were read. Also nil when a
    /// payment other than a move's changed since the move started (`moveStart`): it may have emptied another channel.
    static func paymentsAround(
        moveStart start: [PaymentDetails]?,
        channelsRead before: [PaymentDetails]?,
        _ after: [PaymentDetails]?,
        isMovePayment: (String) -> Bool
    ) -> [PaymentDetails]? {
        guard let start, let before, let after, outboundLightning(before) == outboundLightning(after) else { return nil }
        let othersAtStart = outboundLightning(start).filter { !isMovePayment($0.id) }
        guard othersAtStart == outboundLightning(before).filter({ !isMovePayment($0.id) }) else { return nil }
        return before + after
    }

    private struct PaymentMark: Hashable {
        let id: String
        let status: PaymentStatus
        let updatedAt: UInt64
    }

    private static func outboundLightning(_ payments: [PaymentDetails]) -> Set<PaymentMark> {
        Set(payments.filter { payment in
            if case .onchain = payment.kind {
                return false
            }
            return payment.direction == .outbound
        }.map { PaymentMark(id: $0.id, status: $0.status, updatedAt: $0.latestUpdateTimestamp) })
    }

    private static func isLightningInFlight(_ payment: PaymentDetails) -> Bool {
        if case .onchain = payment.kind {
            return false
        }
        return payment.direction == .outbound && payment.status == .pending
    }

    /// The most a Lightning payment can send: over the channels, from Spark, or from Spark after an update.
    static func maxSendSats(channels: [ChannelDetails]?, spark: SparkSendState) -> UInt64 {
        max(movableSats(channels: channels), spark.sendableSats, combinedSendableSats(channels: channels, spark: spark))
    }

    /// The most Spark can send once the channels' balance less a guessed routing fee has moved to it; 0 when nothing can
    /// move.
    static func combinedSendableSats(channels: [ChannelDetails]?, spark: SparkSendState) -> UInt64 {
        guard canMove(channels: channels, isSparkUsable: spark.isUsable) else { return 0 }
        let limitSats = movableSats(channels: channels)
        let (balanceSats, overflow) = spark.balanceSats.addingReportingOverflow(firstCandidate(wantedSats: limitSats, limitSats: limitSats))
        return ChannelFreeRailFees.sendableSats(balanceSats: overflow ? .max : balanceSats)
    }

    /// The most the channels or a usable Spark can send alone.
    static func singleRailSendableSats(channels: [ChannelDetails]?, spark: SparkSendState) -> UInt64 {
        max(movableSats(channels: channels), spark.sendableSats)
    }

    /// Whether `amountSats` fits neither the channels nor Spark alone, but fits Spark once the channels moved to it. The
    /// channels send only below what they can send together, as `LightningService.canSend` reads them, so an amount
    /// equal to it needs the update too.
    static func needsUpdateToSend(amountSats: UInt64, channels: [ChannelDetails]?, spark: SparkSendState) -> Bool {
        let channelsSats = (channels ?? []).filter(\.isUsable).map(\.nextOutboundHtlcLimitMsat).reduce(0, +) / 1000
        return amountSats >= channelsSats && !spark.canSend(amountSats)
            && amountSats <= combinedSendableSats(channels: channels, spark: spark)
    }

    /// Whether a Lightning payment of `amountSats` needs the update now, from the node's channels and Spark's state.
    @MainActor
    static func needsUpdateToSend(amountSats: UInt64) -> Bool {
        needsUpdateToSend(amountSats: amountSats, channels: LightningService.shared.channels, spark: .live)
    }

    /// Whether a Lightning send can pay `amountSats`: over one rail, or from Spark once the spending balance is updated.
    @MainActor
    static func canSendLightning(amountSats: UInt64, lightningService: LightningService = .shared) -> Bool {
        lightningService.canSend(amountSats: amountSats)
            || needsUpdateToSend(amountSats: amountSats, channels: lightningService.channels, spark: .live)
    }

    /// What a Pubky swap can spend of `maxSendSats`: its hold payment goes out over one rail, never after a spending
    /// balance update.
    static func swapSpendableSats(maxSendSats: UInt64, channels: [ChannelDetails]?, spark: SparkSendState) -> UInt64 {
        min(maxSendSats, singleRailSendableSats(channels: channels, spark: spark))
    }

    @MainActor
    static func swapSpendableSats(maxSendSats: UInt64) -> UInt64 {
        swapSpendableSats(maxSendSats: maxSendSats, channels: LightningService.shared.channels, spark: .live)
    }

    /// Whether Spark can pay `amountSats` and its `feeSats` for the payment once `quote` has moved to it, by the rule the
    /// wait after the move uses too, which keeps Spark's service fee.
    static func coversPayment(quote: MoveToSparkQuote, spark: SparkSendState, amountSats: UInt64, feeSats: UInt64) -> Bool {
        let (have, haveOverflow) = spark.balanceSats.addingReportingOverflow(quote.amountSats)
        let (need, needOverflow) = amountSats.addingReportingOverflow(feeSats)
        guard spark.isUsable, !needOverflow else { return false }
        guard !haveOverflow else { return true }
        var moved = spark
        moved.balanceSats = have
        return have >= need && moved.canSend(amountSats)
    }

    /// The update fee guard: nothing is charged that the user did not see, so a fresh quote with no fee shown before it,
    /// or a fee above the one shown, stops the payment until the new fee shows.
    static func isUpdateFeeUnseen(shownFeeSats: UInt64?, freshFeeSats: UInt64) -> Bool {
        guard let shownFeeSats else { return true }
        return freshFeeSats > shownFeeSats
    }
}

/// What the update to Spark reads of Spark: whether it takes a move, and what it can then send.
struct SparkSendState: Equatable {
    var isReady: Bool
    var isExiting: Bool
    var balanceSats: UInt64

    var isUsable: Bool {
        MoveToSparkMath.isSparkUsable(isReady: isReady, isExiting: isExiting)
    }

    /// What Spark can send once its service fee is kept; nothing while it is not usable.
    var sendableSats: UInt64 {
        isUsable ? ChannelFreeRailFees.sendableSats(balanceSats: balanceSats) : 0
    }

    func canSend(_ amountSats: UInt64) -> Bool {
        sendableSats >= amountSats
    }

    @MainActor
    static var live: SparkSendState {
        let spark = SparkManager.shared
        return SparkSendState(isReady: spark.isReady, isExiting: spark.isExiting, balanceSats: spark.balanceSats)
    }
}

/// One payment of a move, under its quoted routing fee.
struct MoveToSparkPart: Equatable {
    let amountSats: UInt64
    let feeSats: UInt64
}

/// A move of the channels' whole balance. `partSats` is the largest payment that routes; a balance larger than that
/// moves in parts. `feeSats` is the fee shown, a ceiling: the part's fee for each part it takes.
struct MoveToSparkQuote: Equatable {
    let invoice: String
    let amountSats: UInt64
    let feeSats: UInt64
    let partSats: UInt64

    init(invoice: String, amountSats: UInt64, feeSats: UInt64, partSats: UInt64? = nil) {
        self.invoice = invoice
        self.amountSats = amountSats
        self.feeSats = feeSats
        self.partSats = partSats ?? amountSats
    }
}

/// What paying a move's parts came to.
enum MoveToSparkPartsOutcome: Equatable {
    /// The parts settled, moving `movedSats` for `feeSats`; `isComplete` once the channels have less than the minimum left.
    case settled(movedSats: UInt64, feeSats: UInt64, isComplete: Bool)
    /// `partSats` was still unsettled after the wait; the parts before it moved `movedSats` for `feeSats`.
    case inFlight(movedSats: UInt64, feeSats: UInt64, partSats: UInt64)
}

@MainActor
extension LightningActivity {
    /// The channel send of a move to Spark, which Activity shows as a transfer rather than a payment. Known by its payment
    /// hash, so a paid outside invoice that happens to carry the move's description stays a payment.
    var isMoveToSpark: Bool {
        txType == .sent && MoveToSparkPayments.contains(id)
    }
}

enum MoveToSparkError: Error, Equatable {
    case nothingToMove
    case sparkUnavailable
    /// No part of the channels' balance, down to the minimum, routes to Spark.
    case noRoute
    /// The quoted move, with Spark's balance, would not cover a payment of `amountSats`, so nothing moved.
    case updateFallsShort(amountSats: UInt64)
    /// The update's fee is new or above the one the user saw, so nothing moved until they see it.
    case updateFeeUnseen
    /// The update moved the balance, but Spark cannot pay with it yet: the move or Spark's balance has not settled.
    case updateUnsettled
    /// The update for a payment could not be quoted or did not move; the payment was not sent.
    case updateFailed
}

/// The payments that move a channel balance to Spark, whose send and receive the app does not announce as payments.
/// Kept on disk until a wipe and in the metadata backup, so a move that settles after a relaunch, and its Activity row after
/// a restore, stay known as one.
@MainActor
enum MoveToSparkPayments {
    private static let storageKey = "moveToSparkPaymentHashes"
    static var defaults: UserDefaults = .standard {
        didSet { cached = nil }
    }

    /// Read once, as Activity asks for every row it draws.
    private static var cached: [String: Double]?
    /// Outside the main actor, so the backup observers can subscribe from anywhere.
    nonisolated static var savedPublisher: AnyPublisher<Void, Never> {
        MoveToSparkPaymentsSaved.subject.eraseToAnyPublisher()
    }

    static func insert(_ paymentHash: String, now: Date = Date()) {
        var hashes = stored
        hashes[paymentHash.lowercased()] = now.timeIntervalSince1970
        save(hashes)
        MoveToSparkPaymentsSaved.subject.send()
    }

    /// Sorted, so an unchanged store backs up byte for byte the same.
    static func backupSnapshot() -> [String] {
        stored.keys.sorted()
    }

    /// Adds the restored hashes to any already known.
    static func restore(_ paymentHashes: [String]?, now: Date = Date()) {
        guard let paymentHashes, !paymentHashes.isEmpty else { return }
        var hashes = stored
        for hash in paymentHashes where hashes[hash.lowercased()] == nil {
            hashes[hash.lowercased()] = now.timeIntervalSince1970
        }
        save(hashes)
    }

    static func contains(_ paymentHash: String?) -> Bool {
        paymentHash.map { stored[$0.lowercased()] != nil } ?? false
    }

    private static func save(_ hashes: [String: Double]) {
        defaults.set(hashes, forKey: storageKey)
        cached = hashes
    }

    static func removeAll() {
        defaults.removeObject(forKey: storageKey)
        cached = nil
    }

    private static var stored: [String: Double] {
        if let cached {
            return cached
        }
        let hashes = defaults.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
        cached = hashes
        return hashes
    }
}

private enum MoveToSparkPaymentsSaved {
    static let subject = PassthroughSubject<Void, Never>()
}

/// What a move quote needs from Spark and the channels, apart so the quote can be tested without either.
protocol MoveToSparkServices {
    @MainActor var isSparkUsable: Bool { get }
    func receiveInvoice(description: String, expirySecs: UInt32) async throws -> String
    /// The routing fee LDK estimates for paying `bolt11` with `amountSats` over the channels only.
    func estimateChannelFee(bolt11: String, amountSats: UInt64) async throws -> UInt64
    @MainActor var spark: SparkSendState { get }
    /// Spark's fee for paying `bolt11` with `amountSats`, from Spark's own quote, which prices the amount whatever its balance.
    func estimateSparkFee(bolt11: String, amountSats: UInt64) async throws -> UInt64
    func refreshSpark() async
}

struct LiveMoveToSparkServices: MoveToSparkServices {
    @MainActor var isSparkUsable: Bool {
        MoveToSparkMath.isSparkUsable(SparkManager.shared)
    }

    func receiveInvoice(description: String, expirySecs: UInt32) async throws -> String {
        try await SparkManager.shared.receive(amountSats: nil, description: description, expirySecs: expirySecs)
    }

    func estimateChannelFee(bolt11: String, amountSats: UInt64) async throws -> UInt64 {
        try await LightningService.shared.estimateRoutingFees(bolt11: bolt11, amountSats: amountSats, channelsOnly: true)
    }

    @MainActor var spark: SparkSendState {
        .live
    }

    func estimateSparkFee(bolt11: String, amountSats: UInt64) async throws -> UInt64 {
        try await SparkManager.shared.estimateRoutingFees(bolt11: bolt11, amountSats: amountSats)
    }

    func refreshSpark() async {
        await SparkManager.shared.refreshState()
    }
}

enum MoveToSparkFailure {
    case nothingToMove
    case sparkUnavailable
    case unknown
}

enum MoveToSparkState: Equatable {
    case quoting
    /// `isMoving`: Update was tapped and the parts are paying.
    case confirm(MoveToSparkQuote, isMoving: Bool)
    case done(amountSats: UInt64, feeSats: UInt64)
    /// A part had no outcome within the wait; it may still settle or return to the channel.
    case inFlight(amountSats: UInt64)
    case failed(MoveToSparkFailure)
}

/// Moves the channels' balance to the user's own Spark wallet, paying a Spark invoice over the channels only.
/// Blocktank is closing its channels, and this is the cheapest way to keep the balance in Spending.
@Observable @MainActor
final class MoveToSparkManager {
    /// Shared so a move and its outcome outlive the Update Spending Balance modal.
    static let shared = MoveToSparkManager()

    private static let invoiceExpirySecs: UInt32 = 3600
    private static let maxQuoteRounds = 4
    /// How long a payment after an update waits for Spark to show the moved balance.
    private static let sparkBalanceWait: Duration = .seconds(60)
    /// How often that wait reads Spark's balance again.
    private static let sparkBalanceRecheck: Duration = .seconds(2)
    /// How long a close waits for a move's HTLC to stop counting against the peer's in-flight cap, rechecking every 2 s.
    private static let htlcClearWait: Duration = .seconds(30)
    private static let htlcClearRecheck: Duration = .seconds(2)

    private(set) var state: MoveToSparkState = .quoting
    /// A move was started and its outcome is still the modal's, so showing the modal again keeps it.
    private var keepsOutcome = false
    /// Counts quotes, moves and resets; a quote writes its result only while it is still the latest.
    private(set) var generation = 0
    private var isQuoting = false
    /// A move that has not settled yet; closing the modal keeps it, so it is never quoted over.
    private var isMoveInFlight = false

    /// A move is kept for its result, so its modal stays reachable while the channels have nothing left to move.
    var keepsMoveForItsResult: Bool {
        keepsOutcome || isMoveInFlight
    }

    private let services: any MoveToSparkServices
    /// One move at a time: the modal's and a payment's update would otherwise pay from the same channel balance.
    private var moveTail: Task<Void, Never>?

    init(services: any MoveToSparkServices = LiveMoveToSparkServices()) {
        self.services = services
    }

    /// Opens the modal: quotes a new move, unless a quote is still running or a move started earlier is still running
    /// or showing its outcome.
    func start(wallet: WalletViewModel) async {
        guard !keepsOutcome, !isQuoting else { return }
        await quote(wallet: wallet)
    }

    /// Forgets the last move once its modal is closed, unless its payment is still in flight.
    func reset() {
        guard !isMoveInFlight else { return }
        generation += 1
        isQuoting = false
        keepsOutcome = false
        state = .quoting
    }

    /// Forgets everything of the wiped wallet, its unsettled move too: a new generation makes that move's pending result
    /// and late outcome leave the screen of the next wallet alone.
    func resetForWipe() {
        generation += 1
        isQuoting = false
        keepsOutcome = false
        isMoveInFlight = false
        state = .quoting
        MoveToSparkPayments.removeAll()
    }

    /// Quotes moving everything the channels can send.
    func quote(wallet: WalletViewModel) async {
        generation += 1
        let quoteGeneration = generation
        isQuoting = true
        keepsOutcome = false
        state = .quoting
        await wallet.syncStateAsync()
        let result: MoveToSparkState
        do {
            result = try await .confirm(makeQuote(channels: wallet.channels), isMoving: false)
        } catch {
            Logger.warn("Failed to quote move to Spark: \(error)", context: "MoveToSpark")
            result = Self.state(for: error)
        }
        guard quoteGeneration == generation else { return }
        isQuoting = false
        state = result
    }

    func move(wallet: WalletViewModel, transfer: TransferViewModel) async {
        guard case let .confirm(quote, isMoving) = state, !isMoving else { return }
        let channelsBefore = wallet.channels ?? []
        let moveGeneration = beginMove()
        state = .confirm(quote, isMoving: true)
        let paymentsBefore = await LightningService.shared.listPayments()
        // A part still unsettled after the wait keeps the move until its late outcome, so leaving and reopening the
        // screen shows it again instead of a new quote.
        var isSettled = true
        defer {
            if isSettled {
                isMoveInFlight = false
            }
        }
        do {
            let outcome = try await payParts(
                quote,
                wallet: wallet,
                // Shown in the step that stops waiting, so a late outcome right after it finds this move in flight.
                onTimeout: { [weak self] movedSats in self?.showInFlight(amountSats: movedSats, moveGeneration: moveGeneration) },
                onLateFailure: { [weak self] movedSats, feeSats in
                    self?.lateFailure(movedSats: movedSats, feeSats: feeSats, moveGeneration: moveGeneration)
                },
                onLateSuccess: { [weak self, weak wallet, weak transfer] movedSats, feeSats in
                    guard let self, let wallet else { return }
                    if let transfer {
                        closeEmptied(before: channelsBefore, paymentsBefore: paymentsBefore, wallet: wallet, transfer: transfer)
                    }
                    Task {
                        await self.lateSuccess(amountSats: movedSats, feeSats: feeSats, moveGeneration: moveGeneration, wallet: wallet)
                    }
                }
            )
            guard case let .settled(movedSats, feeSats, isComplete) = outcome else {
                isSettled = false
                return
            }
            closeEmptied(before: channelsBefore, paymentsBefore: paymentsBefore, wallet: wallet, transfer: transfer)
            guard moveGeneration == generation else { return }
            await wallet.syncStateAsync()
            guard moveGeneration == generation else { return }
            // A move that stopped with balance left shows Failed, whose Try again quotes what is left.
            state = isComplete ? .done(amountSats: movedSats, feeSats: feeSats) : .failed(.unknown)
        } catch {
            Logger.error("Failed to move '\(quote.amountSats)' sats to Spark: \(error)", context: "MoveToSpark")
            guard moveGeneration == generation else { return }
            state = .failed(.unknown)
        }
    }

    /// Pays the parts of `quote` over the channels, each quoted afresh from the balance a node sync shows, with
    /// `payOverChannels`. `onTimeout` gets the total including the part left in flight, and the late outcomes the totals
    /// as they then stand.
    private func payParts(
        _ quote: MoveToSparkQuote,
        wallet: WalletViewModel,
        onTimeout: @escaping @MainActor (UInt64) -> Void = { _ in },
        onLateFailure: @escaping @MainActor (UInt64, UInt64) -> Void = { _, _ in },
        onLateSuccess: @escaping @MainActor (UInt64, UInt64) -> Void = { _, _ in }
    ) async throws -> MoveToSparkPartsOutcome {
        let services = services
        return try await Self.payParts(
            quote,
            movableSats: {
                await wallet.syncStateAsync()
                return MoveToSparkMath.movableSats(channels: wallet.channels)
            },
            newInvoice: {
                try await services.receiveInvoice(description: MoveToSparkMath.invoiceDescription, expirySecs: Self.invoiceExpirySecs)
            },
            quotePart: { invoice, limitSats, wantedSats in
                try await self.quotePart(invoice: invoice, limitSats: limitSats, wantedSats: wantedSats)
            },
            pay: { bolt11, part, movedSats, feeSats in
                let settled = try await self.payOverChannels(
                    MoveToSparkQuote(invoice: bolt11, amountSats: part.amountSats, feeSats: part.feeSats),
                    wallet: wallet,
                    onTimeout: { onTimeout(movedSats + part.amountSats) },
                    onLateFailure: { onLateFailure(movedSats, feeSats) },
                    onLateSuccess: { onLateSuccess(movedSats + part.amountSats, feeSats + $0.feePaidSats) }
                )
                return settled?.feePaidSats
            }
        )
    }

    /// Pays the channels' balance in parts until less than the minimum is left: each part is quoted from `movableSats`,
    /// no larger than the last, the first to the quote's invoice and each later one to `newInvoice`. A part that does
    /// not route, quoted or sent, is halved. Each part's fee cap is its quoted fee, within what is left of the fee shown,
    /// so the move never pays more than the user saw. It stops when a part's fee no longer fits, a part leaves the
    /// balance where it was, after `maxParts` parts, or on any other failure, which it throws when nothing moved. `pay`
    /// returns the fee paid, or `nil` while the part is still in flight, which ends the parts.
    static func payParts(
        _ quote: MoveToSparkQuote,
        movableSats: () async -> UInt64,
        newInvoice: () async throws -> String,
        quotePart: (_ invoice: String, _ limitSats: UInt64, _ wantedSats: UInt64) async throws -> MoveToSparkPart?,
        pay: (_ bolt11: String, _ part: MoveToSparkPart, _ movedSats: UInt64, _ feeSats: UInt64) async throws -> UInt64?
    ) async throws -> MoveToSparkPartsOutcome {
        var wantedSats = quote.partSats
        var firstInvoice: String? = quote.invoice
        var movedSats: UInt64 = 0
        var feeSats: UInt64 = 0
        var lastLimitSats: UInt64?
        var stopError: Error = MoveToSparkError.noRoute
        for _ in 0 ..< MoveToSparkMath.maxParts {
            let limitSats = await movableSats()
            guard MoveToSparkMath.hasMovableBalance(limitSats: limitSats) else {
                return .settled(movedSats: movedSats, feeSats: feeSats, isComplete: true)
            }
            if let lastLimitSats, limitSats >= lastLimitSats {
                break
            }
            var bolt11 = ""
            var part: MoveToSparkPart?
            do {
                if let invoice = firstInvoice {
                    bolt11 = invoice
                    firstInvoice = nil
                } else {
                    bolt11 = try await newInvoice()
                }
                part = try await quotePart(bolt11, limitSats, min(wantedSats, limitSats))
                guard let part, part.feeSats <= quote.feeSats - feeSats else { break }
                guard let paidSats = try await pay(bolt11, part, movedSats, feeSats) else {
                    return .inFlight(movedSats: movedSats, feeSats: feeSats, partSats: part.amountSats)
                }
                movedSats += part.amountSats
                feeSats += paidSats
                wantedSats = part.amountSats
                lastLimitSats = limitSats
            } catch {
                stopError = error
                guard let part, isNoRoute(error) || isSendWithoutRoute(error, invoice: bolt11),
                      let halfSats = MoveToSparkMath.smallerAmount(part.amountSats)
                else { break }
                wantedSats = halfSats
            }
        }
        guard movedSats > 0 else { throw stopError }
        return .settled(movedSats: movedSats, feeSats: feeSats, isComplete: false)
    }

    /// Pays `quote` over the channels, after any move still paying, and waits for its outcome; `nil` means it is still in
    /// flight, and its late outcome goes to `onLateFailure` or `onLateSuccess`.
    private func payOverChannels(
        _ quote: MoveToSparkQuote,
        wallet: WalletViewModel,
        onTimeout: @escaping @MainActor () -> Void = {},
        onLateFailure: @escaping @MainActor () -> Void = {},
        onLateSuccess: @escaping @MainActor (WalletViewModel.SettledLightningPayment) -> Void = { _ in }
    ) async throws -> WalletViewModel.SettledLightningPayment? {
        let previous = moveTail
        let payment = Task { @MainActor in
            await previous?.value
            let paymentHash = try Bolt11Invoice.fromStr(invoiceStr: quote.invoice).paymentHash()
            MoveToSparkPayments.insert(String(describing: paymentHash))
            return try await wallet.sendOverChannels(
                bolt11: quote.invoice,
                sats: quote.amountSats,
                maxFeeMsat: MoveToSparkMath.feeCapMsat(feeSats: quote.feeSats),
                onTimeout: onTimeout,
                onLateFailure: onLateFailure,
                onLateSuccess: onLateSuccess
            )
        }
        moveTail = Task { _ = try? await payment.value }
        return try await payment.value
    }

    /// Quotes moving everything the channels can send, for a payment that needs the update.
    /// The update moves the balance in one payment; a balance that takes several parts goes through the modal.
    func updateQuote(wallet: WalletViewModel) async throws -> MoveToSparkQuote {
        let quote = try await makeQuote(channels: wallet.channels)
        guard quote.partSats == quote.amountSats else { throw MoveToSparkError.noRoute }
        return quote
    }

    /// Spark's fee for a payment of `amountSats` once the spending balance is updated; Spark's service fee alone when
    /// nothing can price it, or when there is no invoice yet, as for an LNURL before its callback.
    func estimateFeeAfterUpdate(bolt11: String?, amountSats: UInt64) async -> UInt64 {
        if let bolt11, let feeSats = try? await services.estimateSparkFee(bolt11: bolt11, amountSats: amountSats) {
            return feeSats
        }
        Logger.debug("Fell back to Spark's service fee for an update payment", context: "MoveToSpark")
        return ChannelFreeRailFees.serviceFeeSats(amountSats: amountSats)
    }

    /// Before a payment of `bolt11` for `amountSats` that fits only across the channels and Spark, quotes the update
    /// again and moves the channels' balance to Spark, then waits until Spark can pay. Moves nothing and throws
    /// `updateFeeUnseen` when no update fee was shown, or the fresh fee is above `shown`, handing the fresh quote to
    /// `onUnseen` to show. Any other failure throws a `MoveToSparkError`, so the payment is known as not sent.
    func updateSpendingBalanceIfNeeded(
        bolt11: String,
        amountSats: UInt64,
        shown: MoveToSparkQuote?,
        wallet: WalletViewModel,
        transfer: TransferViewModel,
        onUnseen: (MoveToSparkQuote) -> Void
    ) async throws {
        guard MoveToSparkMath.needsUpdateToSend(amountSats: amountSats) else { return }
        do {
            let fresh = try await updateQuote(wallet: wallet)
            if MoveToSparkMath.isUpdateFeeUnseen(shownFeeSats: shown?.feeSats, freshFeeSats: fresh.feeSats) {
                Logger.info("Stopped a payment to show the update fee '\(fresh.feeSats)'", context: "MoveToSpark")
                onUnseen(fresh)
                throw MoveToSparkError.updateFeeUnseen
            }
            try await updateToSend(quote: fresh, bolt11: bolt11, amountSats: amountSats, wallet: wallet, transfer: transfer)
        } catch let error as MoveToSparkError {
            throw error
        } catch {
            Logger.warn("Failed to update the spending balance for '\(amountSats)' sats: \(error)", context: "MoveToSpark")
            throw MoveToSparkError.updateFailed
        }
    }

    /// Moves the channels' balance to Spark with `quote`, whose fee the user saw, and waits until Spark can pay
    /// `amountSats`. Once the move settles, closes the channels it emptied, also when the payment then fails.
    func updateToSend(
        quote: MoveToSparkQuote,
        bolt11: String,
        amountSats: UInt64,
        wallet: WalletViewModel,
        transfer: TransferViewModel
    ) async throws {
        try await checkCoverage(quote: quote, bolt11: bolt11, amountSats: amountSats)
        let channelsBefore = wallet.channels ?? []
        let paymentsBefore = await LightningService.shared.listPayments()
        let settled = try await payOverChannels(
            quote,
            wallet: wallet,
            onLateSuccess: { [weak self, weak wallet, weak transfer] _ in
                guard let self, let wallet, let transfer else { return }
                closeEmptied(before: channelsBefore, paymentsBefore: paymentsBefore, wallet: wallet, transfer: transfer)
            }
        )
        // Still in flight: the funds reach Spark or return to the channels on their own.
        guard settled != nil else { throw MoveToSparkError.updateUnsettled }
        closeEmptied(before: channelsBefore, paymentsBefore: paymentsBefore, wallet: wallet, transfer: transfer)
        try await waitForSpark(toSend: amountSats)
    }

    /// Before any move: Spark must price the payment, and the quote with Spark's balance must cover it and that fee.
    func checkCoverage(quote: MoveToSparkQuote, bolt11: String, amountSats: UInt64) async throws {
        guard let feeSats = try? await services.estimateSparkFee(bolt11: bolt11, amountSats: amountSats),
              MoveToSparkMath.coversPayment(quote: quote, spark: services.spark, amountSats: amountSats, feeSats: feeSats)
        else {
            throw MoveToSparkError.updateFallsShort(amountSats: amountSats)
        }
    }

    private func waitForSpark(toSend amountSats: UInt64) async throws {
        let deadline = ContinuousClock.now + Self.sparkBalanceWait
        while !services.spark.canSend(amountSats) {
            await services.refreshSpark()
            guard !services.spark.canSend(amountSats) else { return }
            guard ContinuousClock.now < deadline else { throw MoveToSparkError.updateUnsettled }
            try await Task.sleep(for: Self.sparkBalanceRecheck)
        }
    }

    /// Once a move settled, closes each channel it emptied, with the usual transfer to Savings; a close that fails leaves
    /// its channel for a manual close. Runs on its own, so it also finishes after the modal closes.
    func closeEmptied(
        before: [ChannelDetails],
        paymentsBefore moveStart: [PaymentDetails]?,
        wallet: WalletViewModel,
        transfer: TransferViewModel
    ) {
        Task { @MainActor in
            // The channels are read between two reads of the payments, so a payment that starts or ends meanwhile
            // leaves no send limit it lowered in the channels read.
            var emptied = await Self.readEmptied(before: before, moveStart: moveStart, wallet: wallet)
            var previous: [ChannelDetails]?
            // A channel whose limit rises once the move's HTLC clears drops out. One not emptied for good after the wait
            // stays open for a manual close, so a close never starts on a reading the HTLC may have lowered.
            let deadline = ContinuousClock.now + Self.htlcClearWait
            while emptied.contains(where: { !MoveToSparkMath.isEmptiedForGood($0, previous: previous) }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.htlcClearRecheck)
                previous = emptied
                emptied = await Self.readEmptied(before: before, moveStart: moveStart, wallet: wallet)
            }
            emptied.removeAll { !MoveToSparkMath.isEmptiedForGood($0, previous: previous) }
            guard !emptied.isEmpty else { return }
            do {
                let failed = try await transfer.closeChannels(channels: emptied)
                Logger.info("Closed '\(emptied.count - failed.count)' of '\(emptied.count)' channels a move emptied", context: "MoveToSpark")
            } catch {
                Logger.warn("Failed to close the channels a move emptied: \(error)", context: "MoveToSpark")
            }
        }
    }

    private static func readEmptied(
        before: [ChannelDetails],
        moveStart: [PaymentDetails]?,
        wallet: WalletViewModel
    ) async -> [ChannelDetails] {
        let paymentsBefore = await LightningService.shared.listPayments()
        await wallet.syncStateAsync()
        let channels = wallet.channels
        let paymentsAfter = await LightningService.shared.listPayments()
        return MoveToSparkMath.emptiedChannels(
            before: before,
            after: channels,
            payments: MoveToSparkMath.paymentsAround(
                moveStart: moveStart,
                channelsRead: paymentsBefore,
                paymentsAfter,
                isMovePayment: { MoveToSparkPayments.contains($0) }
            )
        )
    }

    /// Starts a move: it keeps its outcome and stays in flight until it settles. Returns the move's generation.
    func beginMove() -> Int {
        generation += 1
        keepsOutcome = true
        isMoveInFlight = true
        return generation
    }

    /// Quotes moving everything the channels can send: the largest part that routes, halving one that does not, and as
    /// fee the part's fee for each part the balance takes.
    func makeQuote(channels: [ChannelDetails]?) async throws -> MoveToSparkQuote {
        let limitSats = MoveToSparkMath.movableSats(channels: channels)
        guard MoveToSparkMath.hasMovableBalance(limitSats: limitSats) else { throw MoveToSparkError.nothingToMove }
        guard services.isSparkUsable else { throw MoveToSparkError.sparkUnavailable }

        let invoice = try await services.receiveInvoice(description: MoveToSparkMath.invoiceDescription, expirySecs: Self.invoiceExpirySecs)
        guard let part = try await quotePart(invoice: invoice, limitSats: limitSats, wantedSats: limitSats) else {
            throw MoveToSparkError.noRoute
        }
        let partCount = MoveToSparkMath.partCount(limitSats: limitSats, part: part)
        guard partCount > 1 else { return MoveToSparkQuote(invoice: invoice, amountSats: part.amountSats, feeSats: part.feeSats) }
        let feeSats = part.feeSats * partCount
        return MoveToSparkQuote(
            invoice: invoice,
            amountSats: MoveToSparkMath.amountAfterFee(limitSats: limitSats, feeSats: feeSats),
            feeSats: feeSats,
            partSats: part.amountSats
        )
    }

    /// The largest part up to `wantedSats` that routes with its fee under `limitSats`, halving an amount that does not;
    /// `nil` once the amount falls below the minimum.
    func quotePart(invoice: String, limitSats: UInt64, wantedSats: UInt64) async throws -> MoveToSparkPart? {
        var wantedSats = wantedSats
        while true {
            let candidateSats = MoveToSparkMath.firstCandidate(wantedSats: wantedSats, limitSats: limitSats)
            guard candidateSats >= MoveToSparkMath.minMoveSats else { return nil }
            if let part = try await fittingPart(invoice: invoice, limitSats: limitSats, wantedSats: wantedSats) {
                return part
            }
            guard let smallerSats = MoveToSparkMath.smallerAmount(candidateSats) else { return nil }
            wantedSats = smallerSats
        }
    }

    /// Prices up to `wantedSats` under `limitSats`; `nil` when it does not route or its fee never fits.
    private func fittingPart(invoice: String, limitSats: UInt64, wantedSats: UInt64) async throws -> MoveToSparkPart? {
        var amountSats = MoveToSparkMath.firstCandidate(wantedSats: wantedSats, limitSats: limitSats)
        var fitting: MoveToSparkPart?
        // The first amount leaves room for a guessed fee; once the real fee is known, the amount grows to fit it.
        for _ in 0 ..< Self.maxQuoteRounds where amountSats >= MoveToSparkMath.minMoveSats {
            let estimateSats: UInt64
            do {
                estimateSats = try await services.estimateChannelFee(bolt11: invoice, amountSats: amountSats)
            } catch {
                guard fitting != nil || Self.isNoRoute(error) else { throw error }
                return fitting
            }
            let feeSats = MoveToSparkMath.quotedFeeSats(estimateSats: estimateSats)
            let nextSats = min(wantedSats, MoveToSparkMath.amountAfterFee(limitSats: limitSats, feeSats: estimateSats))
            if amountSats + feeSats <= limitSats {
                let part = MoveToSparkPart(amountSats: amountSats, feeSats: feeSats)
                fitting = part
                if nextSats <= amountSats {
                    return part
                }
            }
            amountSats = nextSats
        }
        return fitting
    }

    /// Whether the screen still shows the in-flight move of `moveGeneration`: a later move counts a new generation.
    nonisolated static func showsInFlightMove(_ state: MoveToSparkState, generation: Int, moveGeneration: Int) -> Bool {
        guard generation == moveGeneration, case .inFlight = state else { return false }
        return true
    }

    /// The wait for the move of `moveGeneration` ended unsettled: the screen, if it still shows that move, shows it in
    /// flight.
    func showInFlight(amountSats: UInt64, moveGeneration: Int) {
        guard generation == moveGeneration else { return }
        state = .inFlight(amountSats: amountSats)
    }

    /// A move that was still in flight paid after the wait: the screen, if it still shows that same move, shows it moved.
    private func lateSuccess(amountSats: UInt64, feeSats: UInt64, moveGeneration: Int, wallet: WalletViewModel) async {
        Logger.info("Move to Spark of '\(amountSats)' sats succeeded after the wait", context: "MoveToSpark")
        defer {
            if generation == moveGeneration {
                isMoveInFlight = false
            }
        }
        guard Self.showsInFlightMove(state, generation: generation, moveGeneration: moveGeneration) else { return }
        await wallet.syncStateAsync()
        guard Self.showsInFlightMove(state, generation: generation, moveGeneration: moveGeneration) else { return }
        state = .done(amountSats: amountSats, feeSats: feeSats)
    }

    /// A part that was still in flight failed after the wait: its amount stays in the channel, so the screen, if it still
    /// shows that same move, says it could not move, with Try again for what is left, and a toast tells the user wherever
    /// they are.
    private func lateFailure(movedSats: UInt64, feeSats _: UInt64, moveGeneration: Int) {
        Logger.warn("A Move to Spark part failed after the wait, '\(movedSats)' sats moved before it", context: "MoveToSpark")
        if generation == moveGeneration {
            isMoveInFlight = false
        }
        if Self.showsInFlightMove(state, generation: generation, moveGeneration: moveGeneration) {
            state = .failed(.unknown)
        }
        guard !ToastWindowManager.areToastsDisabled() else { return }
        Haptics.notify(.error)
        ToastWindowManager.shared.showToast(Toast(
            type: .error,
            title: t("wallet__toast_payment_failed_title"),
            description: t("wallet__payment_failed_description"),
            accessibilityIdentifier: "PaymentFailedToast"
        ))
    }

    /// Whether the payment failed for want of a route that carries the amount, so a smaller one may route.
    static func isNoRoute(_ error: Error) -> Bool {
        let appError = error as? AppError
        if case .RouteNotFound = (appError?.underlyingError ?? error) as? NodeError {
            return true
        }
        switch appError?.paymentFailureReason {
        case .routeNotFound, .retriesExhausted: return true
        default: return false
        }
    }

    /// LDK reports a route lost since the quote, before any payment exists, as a sending failure on a live invoice.
    static func isSendWithoutRoute(_ error: Error, invoice: String) -> Bool {
        guard case .PaymentSendingFailed = ((error as? AppError)?.underlyingError ?? error) as? NodeError else { return false }
        return (try? Bolt11Invoice.fromStr(invoiceStr: invoice).isExpired()) == false
    }

    private static func state(for error: Error) -> MoveToSparkState {
        switch error as? MoveToSparkError {
        case .nothingToMove: .failed(.nothingToMove)
        case .sparkUnavailable: .failed(.sparkUnavailable)
        case .noRoute, .updateFallsShort, .updateFeeUnseen, .updateUnsettled, .updateFailed, nil: .failed(.unknown)
        }
    }
}
