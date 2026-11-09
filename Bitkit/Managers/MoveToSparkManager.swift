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
        isSparkUsable && movableSats(channels: channels) >= minMoveSats
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
    /// `amountSats` did not route in one payment; `smallerSats` is the next amount to try, if any is left.
    case tooLarge(amountSats: UInt64, smallerSats: UInt64?)
    case failed(MoveToSparkFailure)

    static func == (lhs: MoveToSparkState, rhs: MoveToSparkState) -> Bool {
        switch (lhs, rhs) {
        case (.quoting, .quoting): true
        case let (.confirm(a, am), .confirm(b, bm)): a == b && am == bm
        case let (.done(a, af, ac, ar), .done(b, bf, bc, br)): a == b && af == bf && ac?.channelId == bc?.channelId && ar == br
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

    /// Forgets the last move once its screen is left.
    func reset() {
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
        keepsOutcome = true
        state = .confirm(quote, isMoving: true)
        do {
            let paymentHash = try Bolt11Invoice.fromStr(invoiceStr: quote.invoice).paymentHash()
            MoveToSparkPayments.insert(String(describing: paymentHash))
            let settled = try await wallet.sendOverChannels(
                bolt11: quote.invoice,
                sats: quote.amountSats,
                maxFeeMsat: MoveToSparkMath.feeCapMsat(feeSats: quote.feeSats)
            )
            await wallet.syncStateAsync()
            let openChannels = (wallet.channels ?? []).filter(\.isChannelReady)
            state = .done(
                amountSats: quote.amountSats,
                feeSats: settled.feePaidSats,
                closeChannel: openChannels.count == 1 ? openChannels.first : nil,
                hasRest: MoveToSparkMath.movableSats(channels: wallet.channels) >= MoveToSparkMath.minMoveSats
            )
        } catch {
            Logger.error("Failed to move '\(quote.amountSats)' sats to Spark: \(error)", context: "MoveToSpark")
            state = Self.isNoRoute(error)
                ? .tooLarge(amountSats: quote.amountSats, smallerSats: MoveToSparkMath.smallerAmount(quote.amountSats))
                : .failed(.unknown)
        }
    }

    func makeQuote(channels: [ChannelDetails]?, targetSats: UInt64?) async throws -> MoveToSparkQuote {
        let limitSats = MoveToSparkMath.movableSats(channels: channels)
        let wantedSats = min(targetSats ?? limitSats, limitSats)
        guard wantedSats >= MoveToSparkMath.minMoveSats else { throw MoveToSparkError.nothingToMove }
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

    private static func state(for error: Error) -> MoveToSparkState {
        switch error as? MoveToSparkError {
        case let .tooLarge(amountSats): .tooLarge(amountSats: amountSats, smallerSats: MoveToSparkMath.smallerAmount(amountSats))
        case .nothingToMove: .failed(.nothingToMove)
        case .sparkUnavailable: .failed(.sparkUnavailable)
        case nil: .failed(.unknown)
        }
    }
}
