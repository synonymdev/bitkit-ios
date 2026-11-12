import Foundation
import Observation

/// How fast Spark adds a transfer to the spending balance.
enum SparkTransferSpeed: Equatable {
    /// The provider adds it before confirmations, for a fee up to `SparkClaimFees.instantMaxSats`.
    case instant
    /// Spark adds it after 3 confirmations for about `SparkClaimFees.laterSats`.
    case later
}

/// What a transfer to spending costs, priced for the amount on the confirm screen.
struct SparkTransferQuote: Equatable {
    let address: String
    let satsPerVbyte: UInt32
    let networkFeeSats: UInt64
    /// What reaches the deposit address: the amount, or for a max transfer the balance less the network fee.
    let depositSats: UInt64
    let claimFees: SparkClaimFees

    func claimFeeSats(for speed: SparkTransferSpeed) -> UInt64 {
        switch speed {
        case .instant: claimFees.instantMaxSats
        case .later: claimFees.laterSats
        }
    }

    /// What reaches the spending balance once Spark claims the deposit.
    func toSpendingSats(for speed: SparkTransferSpeed) -> UInt64 {
        depositSats.saturatingSub(claimFeeSats(for: speed))
    }

    /// What leaves savings.
    var totalSats: UInt64 {
        depositSats.saturatingAdd(networkFeeSats)
    }

    /// How much more this fresh quote asks than the approved one at `speed`, 0 when it asks no more, so a rise needs
    /// another swipe: the larger of the rise in the Total leaving savings and the fall in what reaches spending. A lower
    /// fee on one side doesn't offset a higher one on the other.
    func increase(over approved: SparkTransferQuote, speed: SparkTransferSpeed) -> UInt64 {
        max(
            totalSats.saturatingSub(approved.totalSats),
            approved.toSpendingSats(for: speed).saturatingSub(toSpendingSats(for: speed))
        )
    }

    /// Whether the deposit stays claimable at the most Spark may charge to claim it, at either speed: the mature claim
    /// runs at that hour's rate under the same cap, so a deposit at or below `instantMaxSats` could be left unclaimed.
    var coversClaimFee: Bool {
        depositSats > claimFees.instantMaxSats
    }

    /// The minimum transfer, for a quote that doesn't cover the claim fee.
    var belowClaimFeeMessage: String {
        t(
            "lightning__spending_amount__error_min__description",
            variables: ["amount": CurrencyFormatter.formatSats(claimFees.instantMaxSats.saturatingAdd(1))]
        )
    }
}

extension AppViewModel {
    /// The toast for a transfer below the claim minimum, shown wherever the transfer is priced, as on Android.
    func toastBelowClaimFee(_ quote: SparkTransferQuote) {
        toast(
            type: .warning,
            title: t("lightning__spending_amount__error_min__title"),
            description: quote.belowClaimFeeMessage
        )
    }
}

/// Where a transfer to spending stands once its deposit is broadcast.
enum SparkClaimState: Equatable {
    /// Instant was chosen and Spark has not listed the deposit yet.
    case looking
    /// Accepting the early claim.
    case claiming
    /// The early claim is submitted, so Spark is adding the deposit to the spending balance.
    case adding
    /// The deposit reached the spending balance.
    case added
    /// The early claim now costs more than the user accepted.
    case repriced(feeSats: UInt64)
    /// No early claim is offered for this deposit, so Spark adds it after 3 confirmations.
    case unavailable
    /// Later was chosen (or the user chose to wait), so Spark adds it after 3 confirmations.
    case later
    /// Spark did not list the deposit within the polling window.
    case notSeen

    var isDone: Bool {
        self == .added
    }
}

/// The claim decision after a broadcast, kept free of the SDK so it can be tested.
enum SparkClaimDecision {
    /// What to do once Spark lists the deposit. `.claiming` means accept the early claim now.
    static func onOffer(_ kind: SparkClaimOffer.Kind, speed: SparkTransferSpeed, ceilingSats: UInt64) -> SparkClaimState {
        guard speed == .instant else { return .later }
        switch kind {
        case .automatic:
            // Spark claims it by itself; success shows once it lists the deposit as claimed (`noteSettled`).
            return .adding
        case .standard:
            return .unavailable
        case let .choice(earlyFeeSats, _, _, _):
            return earlyFeeSats <= ceilingSats ? .claiming : .repriced(feeSats: earlyFeeSats)
        }
    }

    /// What accepting the early claim did; nil keeps polling, since the offer comes with a later confirmation.
    static func onClaim(_ claim: SparkEarlyClaim) -> SparkClaimState? {
        switch claim {
        case .claimed: .added
        case .submitted: .adding
        case let .repriced(requiredFeeSats): .repriced(feeSats: requiredFeeSats)
        case .declined: .unavailable
        case .waiting: nil
        }
    }
}

/// The Spark calls the deposit claim makes, injectable so the polling can be tested without the SDK.
struct SparkClaimOperations {
    var offer: (String) async throws -> SparkClaimOffer?
    var claimEarly: (SparkClaimOffer) async throws -> SparkEarlyClaim
    var refresh: () async -> Void
    var sleep: (Duration) async -> Void
    /// Clears the early-claim fee cap `claimEarly` left on the deposit, so only the claim at maturity is made. False when
    /// the cap may still be there, as while another claim of the deposit is running.
    var releaseEarlyClaim: (SparkClaimOffer) async -> Bool = { _ in true }

    static var live: SparkClaimOperations {
        SparkClaimOperations(
            offer: { try await SparkManager.shared.depositClaimOffer(txid: $0) },
            claimEarly: { try await SparkManager.shared.claimEarly($0) },
            refresh: { await SparkManager.shared.refreshState() },
            sleep: { try? await Task.sleep(for: $0) },
            releaseEarlyClaim: { await SparkManager.shared.releaseEarlyClaim($0) }
        )
    }
}

/// Savings to Spending through Spark: the amount, speed and quote of the confirm screen, and the deposit's claim on the
/// setting-up screen. Lives for the navigation stack so the claim goes on after the user leaves the setting-up screen.
@Observable
@MainActor
final class SparkTransferFlow {
    /// Looks for the deposit for 5 minutes, after which Spark still adds it after 3 confirmations.
    nonisolated static let pollAttempts = 60
    static let pollInterval: Duration = .seconds(5)
    /// Confirmations before Spark claims a deposit by itself, and roughly how long they take.
    static let matureConfirmations = 3
    static let matureMinutes = 30
    /// Previews show the state they set up, so screens skip the SDK calls there.
    static var isRunningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    var amountSats: UInt64 = 0
    var isMaxAmount = false
    /// The paired hardware wallet that funds the transfer, or nil for savings.
    private(set) var walletId: String?
    /// Signs and broadcasts a transfer funded from a hardware wallet.
    let hwSend = HwSendCoordinator()
    var speed: SparkTransferSpeed = .instant

    var quote: SparkTransferQuote?
    var isQuoting = false
    var quoteError: String?

    private(set) var txid: String?
    var claimState: SparkClaimState = .looking
    /// Each broadcast deposit keeps its own claim: a later transfer neither stops an earlier one's early claim nor takes
    /// its results, which only the current transfer's screen shows.
    @ObservationIgnored private var offers: [String: SparkClaimOffer] = [:]
    /// Offers whose early claim was attempted, so the fee cap it left on the deposit can be cleared on Wait.
    @ObservationIgnored private var claimedOffers: [String: SparkClaimOffer] = [:]
    @ObservationIgnored private var ceilings: [String: UInt64] = [:]
    @ObservationIgnored private var approved: (ceilingSats: UInt64, speed: SparkTransferSpeed)?
    @ObservationIgnored private var approvals: [UUID: (ceilingSats: UInt64, speed: SparkTransferSpeed)] = [:]
    @ObservationIgnored private var watchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var quoteRequestId = 0
    /// The mining fee a refused fixed-amount funding needed, which this transfer's quotes show at least.
    @ObservationIgnored private(set) var fixedFeeFloorSats: UInt64?
    @ObservationIgnored private let operations: SparkClaimOperations
    @ObservationIgnored private let pollAttempts: Int

    init(
        amountSats: UInt64 = 0,
        isMaxAmount: Bool = false,
        speed: SparkTransferSpeed = .instant,
        quote: SparkTransferQuote? = nil,
        claimState: SparkClaimState = .looking,
        operations: SparkClaimOperations = .live,
        pollAttempts: Int = SparkTransferFlow.pollAttempts
    ) {
        self.operations = operations
        self.pollAttempts = pollAttempts
        self.amountSats = amountSats
        self.isMaxAmount = isMaxAmount
        self.speed = speed
        self.quote = quote
        self.claimState = claimState
    }

    func start(amountSats: UInt64, isMaxAmount: Bool, walletId: String? = nil) {
        if self.amountSats != amountSats || self.isMaxAmount != isMaxAmount || self.walletId != walletId {
            quote = nil
            fixedFeeFloorSats = nil
            // A funding followed for the earlier transfer never stands in for this one's swipe.
            txid = nil
        }
        self.amountSats = amountSats
        self.isMaxAmount = isMaxAmount
        self.walletId = walletId
        quoteError = nil
    }

    /// A new transfer after a broadcast one starts from Instant with nothing priced; the earlier claim goes on.
    func beginIfBroadcast() {
        guard txid != nil else { return }
        txid = nil
        amountSats = 0
        isMaxAmount = false
        speed = .instant
        quote = nil
        quoteError = nil
        fixedFeeFloorSats = nil
    }

    // MARK: Quote

    /// Prices the transfer at the fast rate with fresh fee estimates, so the confirm screen never shows a stale fee.
    @discardableResult
    func refreshQuote(
        wallet: WalletViewModel,
        feeEstimatesManager: FeeEstimatesManager,
        hwWalletManager: HwWalletManager? = nil
    ) async -> SparkTransferQuote? {
        quoteRequestId += 1
        let requestId = quoteRequestId
        let amountSats = amountSats
        let isMaxAmount = isMaxAmount
        let walletId = walletId
        let fixedFeeFloorSats = fixedFeeFloorSats ?? 0
        isQuoting = true
        defer {
            if requestId == quoteRequestId {
                isQuoting = false
            }
        }
        do {
            let address = try await SparkManager.shared.depositAddress()
            guard let feeRates = await feeEstimatesManager.getEstimates(refresh: true) else {
                throw AppError(message: t("lightning__spending_confirm__error_quote"), debugMessage: "No fee estimates")
            }
            let rate = TransactionSpeed.fast.getFeeRate(from: feeRates)
            let networkFeeSats: UInt64
            let depositSats: UInt64
            if let walletId, let hwWalletManager {
                networkFeeSats = try await hwWalletManager.estimateOfflineFundingMiningFee(
                    walletId: walletId,
                    address: address,
                    sats: amountSats,
                    satsPerVByte: UInt64(rate)
                )
                depositSats = amountSats
            } else if isMaxAmount {
                networkFeeSats = try await wallet.estimateSendAllFee(address: address, satsPerVByte: rate)
                depositSats = UInt64(max(0, wallet.spendableOnchainBalanceSats)).saturatingSub(networkFeeSats)
            } else {
                // A fixed amount's coin selection can need more fee than its quote, so after a refusal it shows at least that.
                networkFeeSats = try await max(
                    wallet.calculateTotalFee(address: address, amountSats: amountSats, satsPerVByte: rate),
                    fixedFeeFloorSats
                )
                depositSats = amountSats
            }
            let claimFees = try await SparkManager.shared.depositClaimFees(amountSats: depositSats)
            let fresh = SparkTransferQuote(
                address: address,
                satsPerVbyte: rate,
                networkFeeSats: networkFeeSats,
                depositSats: depositSats,
                claimFees: claimFees
            )
            guard requestId == quoteRequestId else { return nil }
            quote = fresh
            quoteError = nil
            return fresh
        } catch {
            Logger.error("Failed to price the transfer to spending: \(error)", context: "SparkTransferFlow")
            guard requestId == quoteRequestId else { return nil }
            quote = nil
            quoteError = t("lightning__spending_confirm__error_quote")
            return nil
        }
    }

    // MARK: Claim

    /// Records the broadcast deposit and starts its claim for the chosen speed.
    func onBroadcast(txid: String, ceilingSats: UInt64? = nil) {
        self.txid = txid
        ceilings[txid] = ceilingSats ?? quote?.claimFees.instantMaxSats ?? 0
        offers[txid] = nil
        claimState = speed == .instant ? .looking : .later
        watchTasks[txid]?.cancel()
        watchTasks[txid] = nil
        if speed == .instant {
            watch(txid: txid)
        }
    }

    /// A fixed-amount funding refused for needing `preparedFeeSats` keeps that fee in this transfer's quotes, so the next
    /// swipe approves it.
    func onFundingChanged(preparedFeeSats: UInt64?) {
        guard !isMaxAmount, walletId == nil else { return }
        fixedFeeFloorSats = preparedFeeSats
    }

    /// Records the early-claim ceiling and speed the user swiped, as the confirm screen keeps requoting while a payment
    /// whose outcome is unknown waits on the pending screen.
    func approveSwipe() {
        approved = (ceilingSats: quote?.claimFees.instantMaxSats ?? 0, speed: speed)
    }

    /// Ties the last swipe's approval to the funding it left unresolved. A later swipe rejected while that funding is
    /// still unresolved finds it already tied, so it can't change the ceiling or speed the user approved for it.
    func bindApproval(to attemptId: UUID) {
        guard let approved, approvals[attemptId] == nil else { return }
        approvals[attemptId] = approved
    }

    /// Ties the approval to the unresolved funding only when the swipe that failed with `error` created it. A swipe
    /// refused before that, as blocked by or a duplicate of an earlier funding, finds the earlier one unresolved, and
    /// after a relaunch nothing is tied to it yet, so its early claim must still ask.
    func bindApproval(to attemptId: UUID, after error: Error) {
        switch error {
        case OnchainSendAttemptError.blocked, OnchainSendAttemptError.duplicate: return
        default: bindApproval(to: attemptId)
        }
    }

    /// Follows a recovered funding a swipe of this flow approved, whichever screen shows when it resolves, so its claim
    /// starts and a later swipe can't fund it again. False for one it doesn't own or already follows.
    func followIfOwned(txid: String, attemptId: UUID) -> Bool {
        guard approvals[attemptId] != nil, self.txid != txid else { return false }
        onRecoveredBroadcast(txid: txid, attemptId: attemptId)
        return true
    }

    /// Starts the claim of a funding whose outcome was unknown at the swipe, at the ceiling and speed then approved; with
    /// nothing approved for that funding, an early claim asks first.
    func onRecoveredBroadcast(txid: String, attemptId: UUID) {
        let approved = approvals.removeValue(forKey: attemptId) ?? (ceilingSats: 0, speed: speed)
        speed = approved.speed
        onBroadcast(txid: txid, ceilingSats: approved.ceilingSats)
    }

    /// Shows the progress of the deposit in `txid`, as when the transfer banner opens it. A deposit this flow doesn't
    /// follow, as after a relaunch, is added by Spark at 3 confirmations.
    func showDeposit(txid: String) {
        guard self.txid?.caseInsensitiveCompare(txid) != .orderedSame else { return }
        self.txid = txid
        claimState = .later
    }

    /// Ends the transfer on screen once Spark lists its deposit as claimed, whatever the speed, so Later or Wait
    /// doesn't stay in progress after the deposit reached spending.
    func noteSettled(_ deposits: [SparkDeposit]) {
        guard let txid, !claimState.isDone,
              deposits.contains(where: { $0.isClaimed && $0.txid.caseInsensitiveCompare(txid) == .orderedSame })
        else { return }
        watchTasks[txid]?.cancel()
        watchTasks[txid] = nil
        claimState = .added
    }

    /// Accepts the early claim at the repriced fee.
    func payRepriced() {
        guard case let .repriced(feeSats) = claimState, let txid else { return }
        ceilings[txid] = feeSats
        claimState = .claiming
        watch(txid: txid)
    }

    /// Leaves the deposit to the claim after 3 confirmations, clearing the fee cap an early claim attempt left on it, so
    /// Spark doesn't still claim it early.
    func waitForConfirmations() {
        if let txid {
            watchTasks[txid]?.cancel()
            watchTasks[txid] = nil
            if let offer = claimedOffers.removeValue(forKey: txid) {
                let operations = operations
                let attempts = max(pollAttempts, 1)
                // Not awaited: the SDK call ignores cancellation and can take a while. Tried again while another claim of
                // the deposit, such as Spark's own sync, leaves the cap in place.
                Task {
                    for attempt in 1 ... attempts {
                        if await operations.releaseEarlyClaim(offer) {
                            return
                        }
                        if attempt < attempts {
                            await operations.sleep(Self.pollInterval)
                        }
                    }
                    Logger.warn("Gave up clearing the early claim cap of Spark deposit \(offer.txid)", context: "SparkTransferFlow")
                }
            }
        }
        claimState = .later
    }

    /// Waits for the current transfer's claim to settle; for tests.
    func waitForClaim() async {
        guard let txid else { return }
        await watchTasks[txid]?.value
    }

    private func watch(txid: String) {
        watchTasks[txid]?.cancel()
        watchTasks[txid] = Task { [weak self] in
            await self?.pollDeposit(txid: txid)
            self?.watchTasks[txid] = nil
        }
    }

    /// Shows a claim's progress only while its deposit is the transfer on screen.
    private func setClaimState(_ state: SparkClaimState, for txid: String) {
        guard !Task.isCancelled, self.txid == txid else { return }
        claimState = state
    }

    private func pollDeposit(txid: String) async {
        for _ in 0 ..< pollAttempts {
            if Task.isCancelled {
                return
            }
            do {
                let found = try await operations.offer(txid)
                guard !Task.isCancelled else { return }
                if found == nil, offers[txid] != nil {
                    // Listed before and no longer unclaimed: the early claim went through.
                    setClaimState(.added, for: txid)
                    return
                }
                if let found {
                    offers[txid] = found
                    let next = SparkClaimDecision.onOffer(found.kind, speed: .instant, ceilingSats: ceilings[txid] ?? 0)
                    guard next == .claiming else {
                        setClaimState(next, for: txid)
                        return
                    }
                    setClaimState(.claiming, for: txid)
                    claimedOffers[txid] = found
                    let claim = try await operations.claimEarly(found)
                    guard !Task.isCancelled else { return }
                    if let state = SparkClaimDecision.onClaim(claim) {
                        setClaimState(state, for: txid)
                        return
                    }
                }
            } catch {
                Logger.warn("Failed to claim Spark deposit \(txid) early: \(error)", context: "SparkTransferFlow")
            }
            await operations.refresh()
            await operations.sleep(Self.pollInterval)
        }
        guard !Task.isCancelled else { return }
        // A deposit Spark listed whose early claim never came is waiting for its confirmations, not unseen.
        guard offers[txid] == nil else {
            Logger.info("No early claim for Spark deposit \(txid) within the polling window", context: "SparkTransferFlow")
            setClaimState(.unavailable, for: txid)
            return
        }
        Logger.warn("Spark did not list deposit \(txid) in time", context: "SparkTransferFlow")
        setClaimState(.notSeen, for: txid)
    }
}

/// A transfer to the Spark deposit address whose outcome was unknown, resolved later from the Send sheet's pending screen.
enum SparkFundingRecovery {
    /// Set while Spending Confirm is open: it then owns a recovered funding, at the speed the user chose.
    @MainActor static var confirmScreenOpen = false

    /// The Send sheet's pending screen goes home only when no open Spending Confirm owns the recovered funding, so one
    /// path decides the claim speed and where the user lands.
    static func pendingScreenGoesHome(confirmScreenOpen: Bool) -> Bool {
        !confirmScreenOpen
    }

    /// Lists the deposit as a transfer and tells Spark about it, so it shows as pending and is claimed.
    static func handOff(txid: String, amountSats: UInt64) async {
        await CoreService.shared.activity.markOnchainActivityAsTransfer(txId: txid)
        await SparkManager.shared.onDepositBroadcast(txid: txid, amountSats: amountSats)
    }

    /// Hands a recovered Spark funding to Spark and returns true, so the caller leaves the funding flow whose confirm
    /// screen would offer the sent transfer again; false for any other resolution.
    static func follow(
        _ resolution: OnchainSendLocalResolution,
        handOff: (String, UInt64) async -> Void = { await handOff(txid: $0, amountSats: $1) }
    ) async -> Bool {
        guard resolution.isSparkFunding else { return false }
        await handOff(resolution.txid, resolution.amountSats)
        return true
    }
}
