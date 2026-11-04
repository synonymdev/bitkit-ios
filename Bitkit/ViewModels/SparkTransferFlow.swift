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
}

/// Where a transfer to spending stands once its deposit is broadcast.
enum SparkClaimState: Equatable {
    /// Instant was chosen and Spark has not listed the deposit yet.
    case looking
    /// Accepting the early claim.
    case claiming
    /// The early claim is accepted, so the deposit reaches the spending balance shortly.
    case adding
    /// The early claim now costs more than the user accepted.
    case repriced(feeSats: UInt64)
    /// No early claim is offered for this deposit, so Spark adds it after 3 confirmations.
    case unavailable
    /// Later was chosen (or the user chose to wait), so Spark adds it after 3 confirmations.
    case later
    /// Spark did not list the deposit within the polling window.
    case notSeen

    var isDone: Bool {
        self == .adding
    }
}

/// The claim decision after a broadcast, kept free of the SDK so it can be tested.
enum SparkClaimDecision {
    /// What to do once Spark lists the deposit. `.claiming` means accept the early claim now.
    static func onOffer(_ kind: SparkClaimOffer.Kind, speed: SparkTransferSpeed, ceilingSats: UInt64) -> SparkClaimState {
        guard speed == .instant else { return .later }
        switch kind {
        case .automatic:
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
        case .claimed: .adding
        case let .repriced(requiredFeeSats): .repriced(feeSats: requiredFeeSats)
        case .declined: .unavailable
        case .waiting: nil
        }
    }
}

/// Savings to Spending through Spark: the amount, speed and quote of the confirm screen, and the deposit's claim on the
/// setting-up screen. Lives for the navigation stack so the claim goes on after the user leaves the setting-up screen.
@Observable
@MainActor
final class SparkTransferFlow {
    /// Looks for the deposit for 5 minutes, after which Spark still adds it after 3 confirmations.
    static let pollAttempts = 60
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
    @ObservationIgnored private var offer: SparkClaimOffer?
    @ObservationIgnored private var ceilingSats: UInt64 = 0
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var quoteRequestId = 0

    init(
        amountSats: UInt64 = 0,
        isMaxAmount: Bool = false,
        speed: SparkTransferSpeed = .instant,
        quote: SparkTransferQuote? = nil,
        claimState: SparkClaimState = .looking
    ) {
        self.amountSats = amountSats
        self.isMaxAmount = isMaxAmount
        self.speed = speed
        self.quote = quote
        self.claimState = claimState
    }

    func start(amountSats: UInt64, isMaxAmount: Bool, walletId: String? = nil) {
        if self.amountSats != amountSats || self.isMaxAmount != isMaxAmount || self.walletId != walletId {
            quote = nil
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
                networkFeeSats = try await wallet.calculateTotalFee(address: address, amountSats: amountSats, satsPerVByte: rate)
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
    func onBroadcast(txid: String) {
        self.txid = txid
        ceilingSats = quote?.claimFees.instantMaxSats ?? 0
        offer = nil
        claimState = speed == .instant ? .looking : .later
        watchTask?.cancel()
        watchTask = nil
        if speed == .instant {
            watch(txid: txid)
        }
    }

    /// Accepts the early claim at the repriced fee.
    func payRepriced() {
        guard case let .repriced(feeSats) = claimState, let txid else { return }
        ceilingSats = feeSats
        claimState = .claiming
        watch(txid: txid)
    }

    /// Leaves the deposit to the claim after 3 confirmations.
    func waitForConfirmations() {
        watchTask?.cancel()
        watchTask = nil
        claimState = .later
    }

    private func watch(txid: String) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            await self?.pollDeposit(txid: txid)
        }
    }

    private func pollDeposit(txid: String) async {
        for _ in 0 ..< Self.pollAttempts {
            if Task.isCancelled {
                return
            }
            do {
                let found = try await SparkManager.shared.depositClaimOffer(txid: txid)
                if found == nil, offer != nil {
                    // Listed before and no longer unclaimed: the early claim went through.
                    claimState = .adding
                    return
                }
                if let found {
                    offer = found
                    let next = SparkClaimDecision.onOffer(found.kind, speed: .instant, ceilingSats: ceilingSats)
                    guard next == .claiming else {
                        claimState = next
                        return
                    }
                    claimState = .claiming
                    let claim = try await SparkManager.shared.claimEarly(found)
                    if let state = SparkClaimDecision.onClaim(claim) {
                        claimState = state
                        return
                    }
                }
            } catch {
                Logger.warn("Failed to claim Spark deposit \(txid) early: \(error)", context: "SparkTransferFlow")
            }
            await SparkManager.shared.refreshState()
            try? await Task.sleep(for: Self.pollInterval)
        }
        guard !Task.isCancelled else { return }
        Logger.warn("Spark did not list deposit \(txid) in time", context: "SparkTransferFlow")
        claimState = .notSeen
    }
}
