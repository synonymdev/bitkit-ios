import Foundation
import LDKNode

/// The amounts behind moving the channels' balance to Spark, kept apart so they can be tested without a node.
enum MoveToSparkMath {
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
        spark.isReady
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

    /// The smaller amount to offer after one did not route: half of it, or nothing below the minimum.
    static func smallerAmount(_ sats: UInt64) -> UInt64? {
        let half = sats / 2
        return half >= minMoveSats ? half : nil
    }
}

struct MoveToSparkQuote: Equatable {
    let invoice: String
    let amountSats: UInt64
    let feeSats: UInt64
}

enum MoveToSparkError: Error {
    case nothingToMove
    case sparkUnavailable
    /// `amountSats` did not route from the channels to Spark in one payment.
    case tooLarge(amountSats: UInt64)
}

/// The payments that move a channel balance to Spark, whose send and receive the app does not announce as payments.
@MainActor
enum MoveToSparkPayments {
    private static var paymentHashes = Set<String>()

    static func insert(_ paymentHash: String) {
        paymentHashes.insert(paymentHash.lowercased())
    }

    static func contains(_ paymentHash: String?) -> Bool {
        paymentHash.map { paymentHashes.contains($0.lowercased()) } ?? false
    }
}

enum MoveToSparkFailure {
    case nothingToMove
    case sparkUnavailable
    case unknown
}

enum MoveToSparkState: Equatable {
    case quoting
    case confirm(MoveToSparkQuote, isMoving: Bool)
    /// `hasRest`: the channels can still send enough to move again, as after a smaller amount.
    case done(amountSats: UInt64, feeSats: UInt64, closeChannel: ChannelDetails?, hasRest: Bool)
    /// The payment had no outcome within the wait; it may still settle or return to the channel.
    case inFlight(amountSats: UInt64)
    /// `amountSats` did not route in one payment; `smallerSats` is the next amount to try, if any is left.
    case tooLarge(amountSats: UInt64, smallerSats: UInt64?)
    case failed(MoveToSparkFailure)

    static func == (lhs: MoveToSparkState, rhs: MoveToSparkState) -> Bool {
        switch (lhs, rhs) {
        case (.quoting, .quoting): true
        case let (.confirm(a, am), .confirm(b, bm)): a == b && am == bm
        case let (.done(a, af, ac, ar), .done(b, bf, bc, br)): a == b && af == bf && ac?.channelId == bc?.channelId && ar == br
        case let (.inFlight(a), .inFlight(b)): a == b
        case let (.tooLarge(a, asm), .tooLarge(b, bsm)): a == b && asm == bsm
        case let (.failed(a), .failed(b)): a == b
        default: false
        }
    }
}

/// Moves the channels' balance to the user's own Spark wallet, paying a Spark invoice over the channels only.
/// Blocktank is closing its channels, and this is the cheapest way to keep the balance in Spending.
@Observable @MainActor
final class MoveToSparkManager {
    /// Shared so a move and its outcome outlive the screen, which is rebuilt when the app is unlocked.
    static let shared = MoveToSparkManager()

    private static let invoiceDescription = "Move to Spark"
    private static let invoiceExpirySecs: UInt32 = 3600
    private static let maxQuoteRounds = 4

    private(set) var state: MoveToSparkState = .quoting
    /// A move was started and its outcome is still the screen's, so showing the screen again keeps it.
    private var keepsOutcome = false
    /// Counts quotes, moves and resets; a quote writes its result only while it is still the latest.
    private var generation = 0
    private var isQuoting = false
    /// A swiped payment that has not settled yet; leaving the screen keeps it, so it is never quoted over.
    private var isMoveInFlight = false

    private let lightningService: LightningService
    private let spark: SparkManager

    init() {
        lightningService = .shared
        spark = .shared
    }

    /// Opens the screen: quotes a new move, unless a quote is still running or a move started earlier is still running
    /// or showing its outcome.
    func start(wallet: WalletViewModel) async {
        guard !keepsOutcome, !isQuoting else { return }
        await quote(wallet: wallet)
    }

    /// Forgets the last move once its screen is left, unless its payment is still in flight.
    func reset() {
        guard !isMoveInFlight else { return }
        generation += 1
        isQuoting = false
        keepsOutcome = false
        state = .quoting
    }

    /// Quotes moving `targetSats`, or everything the channels can send.
    func quote(wallet: WalletViewModel, targetSats: UInt64? = nil) async {
        generation += 1
        let quoteGeneration = generation
        isQuoting = true
        keepsOutcome = false
        state = .quoting
        await wallet.syncStateAsync()
        let result: MoveToSparkState
        do {
            result = try await .confirm(makeQuote(channels: wallet.channels, targetSats: targetSats), isMoving: false)
        } catch {
            Logger.warn("Failed to quote move to Spark of '\(String(describing: targetSats))': \(error)", context: "MoveToSpark")
            result = Self.state(for: error)
        }
        guard quoteGeneration == generation else { return }
        isQuoting = false
        state = result
    }

    func move(wallet: WalletViewModel) async {
        guard case let .confirm(quote, isMoving) = state, !isMoving else { return }
        generation += 1
        let moveGeneration = generation
        keepsOutcome = true
        isMoveInFlight = true
        // A payment still unsettled after the wait keeps the move until its late outcome, so leaving and reopening the
        // screen shows it again instead of a new quote.
        var isSettled = true
        defer {
            if isSettled {
                isMoveInFlight = false
            }
        }
        state = .confirm(quote, isMoving: true)
        do {
            let paymentHash = try Bolt11Invoice.fromStr(invoiceStr: quote.invoice).paymentHash()
            MoveToSparkPayments.insert(String(describing: paymentHash))
            guard let settled = try await wallet.sendOverChannels(
                bolt11: quote.invoice,
                sats: quote.amountSats,
                maxFeeMsat: MoveToSparkMath.feeCapMsat(feeSats: quote.feeSats),
                // Shown in the step that stops waiting, so a late outcome right after it finds this move in flight.
                onTimeout: { [weak self] in self?.showInFlight(amountSats: quote.amountSats, moveGeneration: moveGeneration) },
                onLateFailure: { [weak self] in self?.lateFailure(amountSats: quote.amountSats, moveGeneration: moveGeneration) },
                onLateSuccess: { [weak self, weak wallet] settled in
                    guard let self, let wallet else { return }
                    Task {
                        await self.lateSuccess(
                            amountSats: quote.amountSats,
                            feeSats: settled.feePaidSats,
                            moveGeneration: moveGeneration,
                            wallet: wallet
                        )
                    }
                }
            ) else {
                isSettled = false
                return
            }
            await wallet.syncStateAsync()
            state = Self.doneState(amountSats: quote.amountSats, feeSats: settled.feePaidSats, channels: wallet.channels)
        } catch {
            Logger.error("Failed to move '\(quote.amountSats)' sats to Spark: \(error)", context: "MoveToSpark")
            state = Self.isNoRoute(error) || Self.isSendWithoutRoute(error, invoice: quote.invoice)
                ? .tooLarge(amountSats: quote.amountSats, smallerSats: MoveToSparkMath.smallerAmount(quote.amountSats))
                : .failed(.unknown)
        }
    }

    func makeQuote(channels: [ChannelDetails]?, targetSats: UInt64?) async throws -> MoveToSparkQuote {
        let limitSats = MoveToSparkMath.movableSats(channels: channels)
        let wantedSats = min(targetSats ?? limitSats, limitSats)
        guard wantedSats >= MoveToSparkMath.minMoveSats, MoveToSparkMath.hasMovableBalance(limitSats: limitSats) else {
            throw MoveToSparkError.nothingToMove
        }
        guard MoveToSparkMath.isSparkUsable(spark) else { throw MoveToSparkError.sparkUnavailable }

        let invoice = try await spark.receive(
            amountSats: nil,
            description: Self.invoiceDescription,
            expirySecs: Self.invoiceExpirySecs
        )
        var amountSats = MoveToSparkMath.firstCandidate(wantedSats: wantedSats, limitSats: limitSats)
        var fitting: MoveToSparkQuote?
        // The first amount leaves room for a guessed fee; once the real fee is known, the amount grows to fit it.
        for _ in 0 ..< Self.maxQuoteRounds where amountSats >= MoveToSparkMath.minMoveSats {
            let estimateSats: UInt64
            do {
                estimateSats = try await lightningService.estimateRoutingFees(bolt11: invoice, amountSats: amountSats, channelsOnly: true)
            } catch {
                if let fitting {
                    return fitting
                }
                throw Self.isNoRoute(error) ? MoveToSparkError.tooLarge(amountSats: amountSats) : error
            }
            let feeSats = MoveToSparkMath.quotedFeeSats(estimateSats: estimateSats)
            let nextSats = min(wantedSats, MoveToSparkMath.amountAfterFee(limitSats: limitSats, feeSats: estimateSats))
            if amountSats + feeSats <= limitSats {
                let quote = MoveToSparkQuote(invoice: invoice, amountSats: amountSats, feeSats: feeSats)
                fitting = quote
                if nextSats <= amountSats {
                    return quote
                }
            }
            amountSats = nextSats
        }
        if let fitting {
            return fitting
        }
        throw MoveToSparkError.tooLarge(amountSats: amountSats)
    }

    /// The outcome of a move that paid `feeSats`: Close when one channel is left, Move The Rest when it can still send.
    nonisolated static func doneState(amountSats: UInt64, feeSats: UInt64, channels: [ChannelDetails]?) -> MoveToSparkState {
        let openChannels = (channels ?? []).filter(\.isChannelReady)
        return .done(
            amountSats: amountSats,
            feeSats: feeSats,
            closeChannel: openChannels.count == 1 ? openChannels.first : nil,
            hasRest: MoveToSparkMath.hasMovableBalance(limitSats: MoveToSparkMath.movableSats(channels: channels))
        )
    }

    /// Whether the screen still shows the in-flight move of `moveGeneration`: a later move counts a new generation.
    nonisolated static func showsInFlightMove(_ state: MoveToSparkState, generation: Int, moveGeneration: Int) -> Bool {
        guard generation == moveGeneration, case .inFlight = state else { return false }
        return true
    }

    /// The wait for the move of `moveGeneration` ended unsettled: the screen, if it still shows that move, shows it in
    /// flight.
    private func showInFlight(amountSats: UInt64, moveGeneration: Int) {
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
        state = Self.doneState(amountSats: amountSats, feeSats: feeSats, channels: wallet.channels)
    }

    /// A move that was still in flight failed after the wait: its amount stays in the channel, so the screen, if it still
    /// shows that same move, says it could not move, and a toast tells the user wherever they are.
    private func lateFailure(amountSats: UInt64, moveGeneration: Int) {
        Logger.warn("Move to Spark of '\(amountSats)' sats failed after the wait", context: "MoveToSpark")
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
    private static func isNoRoute(_ error: Error) -> Bool {
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
    private static func isSendWithoutRoute(_ error: Error, invoice: String) -> Bool {
        guard case .PaymentSendingFailed = ((error as? AppError)?.underlyingError ?? error) as? NodeError else { return false }
        return (try? Bolt11Invoice.fromStr(invoiceStr: invoice).isExpired()) == false
    }

    private static func state(for error: Error) -> MoveToSparkState {
        switch error as? MoveToSparkError {
        case let .tooLarge(amountSats): .tooLarge(amountSats: amountSats, smallerSats: MoveToSparkMath.smallerAmount(amountSats))
        case .nothingToMove: .failed(.nothingToMove)
        case .sparkUnavailable: .failed(.sparkUnavailable)
        case nil: .failed(.unknown)
        }
    }
}
