import BitkitCore
import Foundation
import LDKNode

/// Cost of delivering `deliverSat` on-chain out of the spending balance.
struct SendSwapQuote: Equatable {
    /// What the recipient receives on-chain.
    let deliverSat: UInt64
    /// What the Lightning invoice pays, i.e. what leaves the spending balance.
    let invoiceSat: UInt64
    /// Everything the swap costs on top of `deliverSat`: Boltz's cut plus miner fees.
    let serviceFeeSat: UInt64
    /// Boltz's lockup and claim miner fee estimate, already included in `serviceFeeSat`.
    let networkFeeSat: UInt64

    /// Boltz's percentage fee expressed as a fraction, clamped so the inversion below always
    /// converges even if the pair ever reports a nonsensical rate. A non-finite percentage would
    /// otherwise poison every UInt64 conversion downstream, so it is coerced to zero.
    private static func rate(_ limits: BoltzPairInfo) -> Double {
        guard limits.feePercentage.isFinite else { return 0 }
        return min(max(limits.feePercentage / 100, 0), 0.99)
    }

    /// What a reverse swap of `invoiceSat` leaves on-chain. Mirrors the forward pricing Boltz
    /// applies: it charges `ceil(percentage% * invoice)` and takes the miner fees on top. The
    /// savings quote rounds this fee to nearest instead, which is a fraction of a sat out and
    /// harmless there because the user keeps the remainder; here it would short the recipient.
    static func delivered(invoiceSat: UInt64, limits: BoltzPairInfo) -> UInt64 {
        let serviceFee = UInt64((rate(limits) * Double(invoiceSat)).rounded(.up))
        let cost = serviceFee + limits.minerFeesSat
        return invoiceSat > cost ? invoiceSat - cost : 0
    }

    /// Solve for the Lightning invoice amount that leaves exactly `deliverSat` on-chain. Seeded
    /// from the closed form, then corrected against the integer forward formula so rounding can
    /// never leave the recipient a satoshi short of what the review screen promised.
    static func build(deliverSat: UInt64, limits: BoltzPairInfo) -> SendSwapQuote {
        let seed = (Double(deliverSat) + Double(limits.minerFeesSat)) / (1 - rate(limits))
        var invoiceSat = max(UInt64(seed.rounded(.up)), deliverSat)

        while delivered(invoiceSat: invoiceSat, limits: limits) < deliverSat {
            invoiceSat += 1
        }
        while invoiceSat > 0, delivered(invoiceSat: invoiceSat - 1, limits: limits) >= deliverSat {
            invoiceSat -= 1
        }

        return SendSwapQuote(
            deliverSat: deliverSat,
            invoiceSat: invoiceSat,
            serviceFeeSat: invoiceSat > deliverSat ? invoiceSat - deliverSat : 0,
            networkFeeSat: limits.minerFeesSat
        )
    }

    /// Largest amount a swap can deliver on-chain given what the spending balance can pay.
    static func maxDeliverable(sendableSat: UInt64, limits: BoltzPairInfo) -> UInt64 {
        delivered(invoiceSat: min(limits.maximalSat, sendableSat), limits: limits)
    }

    /// Smallest amount worth offering: the swap minimum applies to the invoice, so the delivered
    /// equivalent is walked up until its quote clears that minimum. Rounding puts this within a
    /// couple of satoshis, and each step raises the invoice by at least one, so it converges.
    static func minDeliverable(limits: BoltzPairInfo) -> UInt64 {
        var deliverSat = delivered(invoiceSat: limits.minimalSat, limits: limits)
        while build(deliverSat: deliverSat, limits: limits).invoiceSat < limits.minimalSat {
            deliverSat += 1
        }
        return deliverSat
    }
}

/// The bounds the amount screen enforces for a swap send, in delivered satoshis.
struct SendSwapBounds: Equatable {
    let minDeliverSat: UInt64
    let maxDeliverSat: UInt64

    var isUsable: Bool { maxDeliverSat > 0 && maxDeliverSat >= minDeliverSat }
}

/// What a completed swap send leaves behind. The Lightning leg is settled either way.
struct SendSwapReceipt: Equatable {
    /// Hash of the hold invoice payment, i.e. the activity the send produces.
    let paymentHash: String
    /// Transaction paying the recipient, nil while the updates stream is still broadcasting it.
    let claimTxId: String?
}

/// Pays an on-chain address out of the spending balance with a Boltz reverse swap, so a send can
/// go through when savings are short but spending is not.
///
/// A reverse swap claims to any address, so the recipient's address is used as the claim address
/// and Boltz's payout lands directly on them. Boltz prices a reverse swap from the Lightning
/// invoice amount while a send starts from the amount the recipient must receive, so the quote
/// here inverts the forward pricing `SavingsSwapQuote` does for the transfer to savings.
@MainActor
class SendSwapService {
    static let shared = SendSwapService()

    private let boltzService: BoltzService
    private let lightningService: LightningService

    private var cachedLimits: BoltzPairInfo?
    private var cachedLimitsAt: Date?

    /// Upper bound for fetching swap limits before the send flow gives up on a quote.
    private let limitsTimeout: TimeInterval = 15
    /// How long cached pair terms are reused before Boltz is asked again. The send flow re-prices
    /// as the amount changes and the terms only move with Boltz's fee schedule.
    private let limitsTtl: TimeInterval = 60
    /// How long the send waits for the on-chain claim before backgrounding it.
    private let claimTimeout: TimeInterval = 30
    /// Minimum sats held back from a swap to cover Lightning routing fees.
    private static let minLnRoutingFeeReserveSats: UInt64 = 10

    init(boltzService: BoltzService = .shared, lightningService: LightningService = .shared) {
        self.boltzService = boltzService
        self.lightningService = lightningService
    }

    // MARK: - Quoting

    /// Bounds a swap can deliver right now, so the amount screen can cap its input without
    /// pricing every keystroke against Boltz. Nil whenever no swap is on offer.
    func bounds() async -> SendSwapBounds? {
        guard let limits = await limits() else { return nil }

        let bounds = SendSwapBounds(
            minDeliverSat: SendSwapQuote.minDeliverable(limits: limits),
            maxDeliverSat: SendSwapQuote.maxDeliverable(sendableSat: sendableLightningSats(), limits: limits)
        )
        return bounds.isUsable ? bounds : nil
    }

    /// Price a swap that delivers exactly `deliverSat` on-chain. Nil when swaps are off, Boltz is
    /// unreachable, or the amount falls outside the swap limits or the spendable balance, so
    /// callers can simply not offer the swap.
    func quote(deliverSat: UInt64) async -> SendSwapQuote? {
        guard deliverSat > 0 else { return nil }
        guard let limits = await limits() else { return nil }

        // A swap can never deliver more than it locks, and it locks at most `maximalSat`, so an
        // amount above that is unquotable. Bailing here also keeps the quote math off absurd
        // inputs (e.g. a crafted BIP21 amount near UInt64.max) that would otherwise overflow.
        guard deliverSat <= limits.maximalSat else {
            Logger.debug("Swap send of \(deliverSat) sat is above the swap maximum", context: "SendSwapService")
            return nil
        }

        let quote = SendSwapQuote.build(deliverSat: deliverSat, limits: limits)

        guard quote.invoiceSat >= limits.minimalSat, quote.invoiceSat <= limits.maximalSat else {
            Logger.debug("Swap send of \(quote.invoiceSat) sat is outside the swap limits", context: "SendSwapService")
            return nil
        }
        guard quote.invoiceSat <= sendableLightningSats() else {
            Logger.debug("Swap send of \(quote.invoiceSat) sat is over the spendable balance", context: "SendSwapService")
            return nil
        }
        guard lightningService.canSend(amountSats: quote.invoiceSat) else {
            Logger.debug("Swap send of \(quote.invoiceSat) sat cannot be routed", context: "SendSwapService")
            return nil
        }

        return quote
    }

    // MARK: - Paying

    /// Create the swap, pay its hold invoice over Lightning and wait for the on-chain claim.
    ///
    /// Boltz reports the amount it will lock before anything is paid, so a swap that would short
    /// the recipient is abandoned while it is still free to abandon. Once the invoice is paid the
    /// claim is broadcast by the updates stream, so a timeout waiting for it leaves
    /// `SendSwapReceipt.claimTxId` nil rather than failing the send.
    ///
    /// `onInvoicePrepared` runs with the hold invoice's payment hash just before it is paid, so
    /// the caller can register the activity metadata the send will produce. `onEvent`/`removeEvent`
    /// register a node event listener so an unroutable payment can be observed.
    func payToAddress(
        address: String,
        deliverSat: UInt64,
        onInvoicePrepared: (String) async -> Void,
        onEvent: @escaping (String, @escaping (Event) -> Void) -> Void,
        removeEvent: @escaping (String) -> Void
    ) async throws -> SendSwapReceipt {
        guard let quote = await quote(deliverSat: deliverSat) else {
            throw AppError(message: t("other__try_again"), debugMessage: "No swap quote covers \(deliverSat) sat")
        }

        // Boltz never verifies the claim address, and a lockup to a wrong-network address is
        // unrecoverable, so re-check it here rather than trusting the decode that scanned it.
        try validateClaimAddress(address)

        // Subscribe before creating the swap so a claim settling faster than the payment call
        // returns is not missed; events buffer from the moment the stream is created.
        let events = boltzService.events()

        let swap = try await boltzService.createReverseSwap(amountSat: quote.invoiceSat, claimAddress: address)
        Logger.info("Created send swap \(swap.id) delivering \(deliverSat) sat", context: "SendSwapService")

        // Boltz reports what it will lock before anything is paid. The quote already holds back
        // Boltz's own claim fee estimate, so a lockup below the delivered amount means Boltz
        // priced on different terms than we quoted and the send is abandoned for free.
        guard swap.onchainAmountSat >= deliverSat else {
            throw AppError(
                message: t("other__try_again"),
                debugMessage: "Boltz locks \(swap.onchainAmountSat) sat, short of \(deliverSat) sat"
            )
        }

        // The invoice is what actually leaves the spending balance, and it is Boltz-supplied, so
        // confirm it encodes the amount we quoted before paying it blind. A mismatch means Boltz
        // priced on different terms; abandon while it is still free to abandon.
        let holdInvoice = try await decodeLightning(swap.invoice)
        guard holdInvoice.amountSatoshis == quote.invoiceSat else {
            throw AppError(
                message: t("other__try_again"),
                debugMessage: "Hold invoice is \(holdInvoice.amountSatoshis) sat, quoted \(quote.invoiceSat) sat"
            )
        }

        let paymentHash = holdInvoice.paymentHash.hex
        await onInvoicePrepared(paymentHash)

        // Pay the hold invoice. `send` returns a payment id as soon as the HTLC is dispatched; a
        // hold invoice never settles until Boltz claims on-chain, so this does not block on the
        // claim. A failure to dispatch the payment throws and is surfaced immediately.
        let paymentId = try await lightningService.send(bolt11: swap.invoice)

        let claimTxId = try await awaitClaim(
            swapId: swap.id,
            paymentId: paymentId,
            events: events,
            onEvent: onEvent,
            removeEvent: removeEvent
        )

        return SendSwapReceipt(paymentHash: paymentHash, claimTxId: claimTxId)
    }

    /// Wait for whichever swap outcome resolves first. `send` returning does not mean the payment
    /// routed, and a paid hold invoice never settles until the on-chain claim, so an unroutable
    /// payment would otherwise idle into the claim timeout and read as a completed send. Watching
    /// the node's payment-failed event alongside the claim surfaces it as a failure instead. A
    /// timeout is not a failure: the updates stream broadcasts the claim in the background.
    private func awaitClaim(
        swapId: String,
        paymentId: String,
        events: AsyncStream<BoltzSwapEvent>,
        onEvent: @escaping (String, @escaping (Event) -> Void) -> Void,
        removeEvent: @escaping (String) -> Void
    ) async throws -> String? {
        let eventId = "send-swap-\(swapId)"
        let paymentFailure = SwapPaymentFailureCapture()

        // LDK events are dispatched on the main actor, so this handler runs there. The returned
        // payment id may land in either the event's payment id or its payment hash field.
        onEvent(eventId) { event in
            guard case let .paymentFailed(eventPaymentId, eventPaymentHash, _) = event else { return }
            guard [eventPaymentId, eventPaymentHash].compactMap({ $0 }).contains(paymentId) else { return }
            Task { await paymentFailure.markFailed() }
        }

        // Capture main-actor state locally so the detached group tasks stay Sendable.
        let timeout = claimTimeout
        let paymentFailedMessage = t("wallet__toast_payment_failed_description")

        let outcome = await withTaskGroup(of: SendSwapClaimOutcome?.self) { group in
            // On-chain claim or a Boltz-side error.
            group.addTask {
                for await event in events {
                    switch event {
                    case let .claimed(swapId: id, txid: txid) where id == swapId:
                        return .claimed(txid: txid)
                    case let .error(swapId: id, message: message) where id == swapId:
                        return .failed(message: message)
                    default:
                        continue
                    }
                }
                return nil
            }
            // Lightning routing failure on the paid hold invoice.
            group.addTask {
                while !Task.isCancelled {
                    if await paymentFailure.hasFailed {
                        return .failed(message: paymentFailedMessage)
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                return nil
            }
            // Bounded wait: a timeout is not a failure, the claim settles in the background.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .settling
            }

            var result: SendSwapClaimOutcome = .settling
            for await value in group {
                if let value {
                    result = value
                    break
                }
            }
            group.cancelAll()
            return result
        }

        removeEvent(eventId)

        switch outcome {
        case let .claimed(txid):
            return txid
        case .settling:
            return nil
        case let .failed(message):
            throw AppError(message: message, debugMessage: "Send swap \(swapId) failed")
        }
    }

    // MARK: - Helpers

    /// Pair terms, cached briefly. Nil whenever swaps are unavailable, which is the only signal
    /// callers need: without terms there is no swap to offer.
    private func limits() async -> BoltzPairInfo? {
        guard boltzService.isSwapEnabled else { return nil }

        if let cachedLimits, let cachedLimitsAt, Date().timeIntervalSince(cachedLimitsAt) < limitsTtl {
            return cachedLimits
        }

        guard let fresh = await fetchReverseLimits() else { return nil }
        cachedLimits = fresh
        cachedLimitsAt = Date()
        return fresh
    }

    /// Bounded so a hanging Boltz request cannot leave the send flow stuck loading.
    private func fetchReverseLimits() async -> BoltzPairInfo? {
        let timeout = limitsTimeout
        let service = boltzService

        return await withTaskGroup(of: BoltzPairInfo?.self) { group in
            group.addTask {
                do {
                    return try await service.reverseLimits()
                } catch {
                    Logger.error("Failed to load reverse swap limits", context: error.localizedDescription)
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    /// Lightning outbound minus a routing reserve. Paying an invoice for 100% of outbound capacity
    /// leaves nothing for fees and fails to route.
    private func sendableLightningSats() -> UInt64 {
        let spendable = (lightningService.channels ?? [])
            .filter(\.isUsable)
            .map(\.nextOutboundHtlcLimitMsat)
            .reduce(0, +) / 1000
        let reserve = max(spendable / 100, Self.minLnRoutingFeeReserveSats)
        return spendable > reserve ? spendable - reserve : 0
    }

    private func validateClaimAddress(_ address: String) throws {
        let validation = try? validateBitcoinAddress(address: address)
        let addressNetwork = validation.map { NetworkValidationHelper.convertNetworkType($0.network) }
        guard !NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: Env.network) else {
            throw AppError(message: t("other__scan_err_decoding"), debugMessage: "Claim address is not on \(Env.network)")
        }
    }

    /// Decode the Boltz hold invoice so its amount and payment hash can be inspected before paying.
    private func decodeLightning(_ bolt11: String) async throws -> LightningInvoice {
        guard case let .lightning(invoice) = try await decode(invoice: bolt11) else {
            throw AppError(message: t("other__try_again"), debugMessage: "Boltz returned an invoice that is not a bolt11")
        }
        return invoice
    }
}

/// How a paid swap resolved while the send was still on screen.
private enum SendSwapClaimOutcome {
    case claimed(txid: String)
    case settling
    case failed(message: String)
}
