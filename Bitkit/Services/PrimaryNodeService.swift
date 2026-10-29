import Foundation
import LDKNode

/// A move of confirmed savings into the primary channel: `amountSats` arrives, `feeSats` pays the miners.
struct PrimaryFundingPlan: Equatable {
    let amountSats: UInt64
    let feeSats: UInt64
    let opensChannel: Bool
    let isAutomatic: Bool

    /// Confirmed savings below this stay on-chain instead of moving into the primary channel.
    static let minFundingSats: UInt64 = 25000
    /// Automatic funding waits while its mining fee is above this share of the amount moved.
    static let maxFundingFeePercent: UInt64 = 5
    /// Virtual size of a splice or channel funding before its inputs, for fee estimates.
    static let fundingBaseVbytes: UInt64 = 300
    /// Virtual size each wallet input adds to a funding transaction.
    static let fundingInputVbytes: UInt64 = 300

    /// Plans moving `spendableSats` of savings, held in `inputs` outputs, into the primary channel at `feeRate`.
    /// Returns nil when there is nothing worth moving; `isAutomatic` is false when the fee is above
    /// `maxFundingFeePercent`, so only a manual transfer moves it.
    static func plan(spendableSats: UInt64, inputs: UInt64, feeRate: UInt64, hasChannel: Bool) -> PrimaryFundingPlan? {
        guard inputs > 0, feeRate > 0 else { return nil }
        let fee = feeRate * (fundingBaseVbytes + fundingInputVbytes * inputs)
        guard spendableSats > fee else { return nil }
        return PrimaryFundingPlan(
            amountSats: spendableSats - fee,
            feeSats: fee,
            opensChannel: !hasChannel,
            isAutomatic: spendableSats >= minFundingSats && fee <= spendableSats / 100 * maxFundingFeePercent
        )
    }
}

/// Lightning-first wallet operations through the primary node: pairing, just-in-time receives,
/// moving confirmed savings into the primary channel, and paying on-chain from that channel.
final class PrimaryNodeService {
    static let shared = PrimaryNodeService()

    private let lightningService: LightningService
    private let defaults: UserDefaults
    private var spliceWaiters: [String: CheckedContinuation<String, Error>] = [:]
    private let waitersLock = NSLock()
    private var isFunding = false

    /// How long a splice may take to reach its pending funding transaction.
    private static let spliceTimeoutSecs: UInt64 = 60

    init(lightningService: LightningService = .shared, defaults: UserDefaults = .standard) {
        self.lightningService = lightningService
        self.defaults = defaults
    }

    var primaryNode: PrimaryNode? {
        lightningService.primaryNode
    }

    var isFundingPaused: Bool {
        get { defaults.bool(forKey: PrimaryNode.fundingPausedKey) }
        set { defaults.set(newValue, forKey: PrimaryNode.fundingPausedKey) }
    }

    @MainActor
    func primaryChannel() -> ChannelDetails? {
        guard let primary = primaryNode else { return nil }
        return lightningService.channels?.first { $0.counterpartyNodeId == primary.nodeId && $0.isChannelReady }
    }

    @MainActor
    func isPrimaryConnected() -> Bool {
        guard let primary = primaryNode else { return false }
        return lightningService.peers?.contains { $0.nodeId == primary.nodeId && $0.isConnected } ?? false
    }

    // MARK: Pairing

    /// Pairs `input` as the primary: saves it, restarts the node so it trusts the new primary, connects,
    /// and checks the node speaks the primary-wallet protocol. A failure restores the previous primary.
    @MainActor
    func pair(_ input: String) async throws -> PrimaryNode {
        var primary = try PrimaryNode.parse(input)
        if primary.address == nil {
            guard let known = lightningService.peers?.first(where: { $0.nodeId == primary.nodeId }) else {
                throw PrimaryNodeError.addressUnknown
            }
            primary = PrimaryNode(nodeId: primary.nodeId, address: known.address)
        }
        if let current = primaryNode, current.nodeId != primary.nodeId,
           lightningService.channels?.contains(where: { $0.counterpartyNodeId == current.nodeId }) == true
        {
            throw PrimaryNodeError.connectionInUse
        }

        let previousUri = defaults.string(forKey: PrimaryNode.uriKey)
        let previousPaused = isFundingPaused
        defaults.set(primary.uri == Env.defaultPrimaryNodeUri ? "" : primary.uri, forKey: PrimaryNode.uriKey)
        isFundingPaused = false

        do {
            try await lightningService.restart()
            guard let peer = primary.peer else { throw PrimaryNodeError.addressUnknown }
            try await lightningService.connectPeer(peer: peer)
            try await lightningService.checkPrimaryConnection(nodeId: primary.nodeId)
            return primary
        } catch {
            defaults.set(previousUri, forKey: PrimaryNode.uriKey)
            isFundingPaused = previousPaused
            try? await lightningService.restart()
            throw Self.mapError(error)
        }
    }

    // MARK: Receive

    func quoteReceive(amountSats: UInt64) async throws -> PrimaryReceiveQuote {
        do {
            let quote = try await lightningService.quotePrimaryReceive(amountSats: amountSats)
            guard quote.amountMsat == amountSats * 1000, quote.feeMsat < quote.amountMsat else {
                throw PrimaryReceiveError.amountTooSmall
            }
            return quote
        } catch {
            throw Self.mapError(error)
        }
    }

    func createInvoice(amountSats: UInt64, description: String, maxFeeMsat: UInt64) async throws -> String {
        do {
            return try await lightningService.receiveViaPrimary(amountSats: amountSats, description: description, maxFeeMsat: maxFeeMsat)
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: Funding

    /// How much of the confirmed savings can move into the primary channel now, and at what fee.
    @MainActor
    func fundingPlan() async throws -> PrimaryFundingPlan? {
        guard primaryNode != nil, isPrimaryConnected() else { return nil }
        guard try await !lightningService.hasPendingFundingOperation() else { return nil }
        let spendable = lightningService.balances?.spendableOnchainBalanceSats ?? 0
        let inputs = try await UInt64(lightningService.listSpendableOutputs().count)
        let feeRate = try await lightningService.channelFundingFeeRate()
        return PrimaryFundingPlan.plan(spendableSats: spendable, inputs: inputs, feeRate: feeRate, hasChannel: primaryChannel() != nil)
    }

    /// Moves confirmed savings into the primary channel when the plan allows it and funding isn't paused.
    @MainActor
    func fundIfNeeded() async {
        guard !isFundingPaused, !isFunding else { return }
        isFunding = true
        defer { isFunding = false }
        do {
            guard let plan = try await fundingPlan(), plan.isAutomatic else { return }
            Logger.info("Funding primary channel with \(plan.amountSats) sats, fee \(plan.feeSats)", context: "PrimaryNodeService")
            try await executeFunding(plan)
        } catch {
            Logger.warn("Failed to fund primary channel: \(error)", context: "PrimaryNodeService")
        }
    }

    /// Transfer to Spending: moves the planned savings now, below the automatic fee limit too, and resumes funding.
    @MainActor
    func transferToSpending(_ plan: PrimaryFundingPlan) async throws {
        isFundingPaused = false
        do {
            try await executeFunding(plan)
        } catch {
            throw Self.mapError(error)
        }
    }

    @MainActor
    private func executeFunding(_ plan: PrimaryFundingPlan) async throws {
        guard let primary = primaryNode else { throw PrimaryNodeError.notConfigured }
        if let channel = primaryChannel() {
            try await lightningService.spliceIn(channel: channel, amountSats: plan.amountSats)
        } else {
            guard let peer = primary.peer else { throw PrimaryNodeError.addressUnknown }
            _ = try await lightningService.openChannel(peer: peer, channelAmountSats: plan.amountSats)
        }
    }

    // MARK: Splice out

    /// Fee for paying `amountSats` on-chain out of the primary channel, or nil when the channel can't cover it.
    @MainActor
    func spliceOutFee(amountSats: UInt64, feeRate: UInt64) -> UInt64? {
        guard let channel = primaryChannel(), channel.isUsable else { return nil }
        let fee = feeRate * PrimaryFundingPlan.fundingBaseVbytes
        return amountSats + fee <= channel.outboundCapacityMsat / 1000 ? fee : nil
    }

    /// The most a single on-chain payment can take out of the primary channel at `feeRate`.
    @MainActor
    func maxSpliceOutSats(feeRate: UInt64) -> UInt64 {
        guard let channel = primaryChannel(), channel.isUsable else { return 0 }
        let outbound = channel.outboundCapacityMsat / 1000
        let fee = feeRate * PrimaryFundingPlan.fundingBaseVbytes
        return outbound > fee ? outbound - fee : 0
    }

    /// Pays `amountSats` to `address` from the primary channel by splicing it out; returns the splice txid.
    @MainActor
    func sendOnchain(address: String, amountSats: UInt64, feeRate: UInt64) async throws -> String {
        guard let channel = primaryChannel(), channel.isUsable else { throw PrimaryNodeError.notConfigured }
        guard try await !lightningService.hasPendingFundingOperation() else { throw PrimaryReceiveError.busy }
        let userChannelId = channel.userChannelId

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.awaitSplice(userChannelId: userChannelId) }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.spliceTimeoutSecs * 1_000_000_000)
                throw PrimaryReceiveError.busy
            }
            do {
                try await lightningService.spliceOut(channel: channel, address: address, amountSats: amountSats, feeRateSatsPerVByte: feeRate)
                let txid = try await group.next() ?? ""
                group.cancelAll()
                return txid
            } catch {
                group.cancelAll()
                cancelSpliceWaiter(userChannelId: userChannelId)
                throw Self.mapError(error)
            }
        }
    }

    /// Transfer to Savings: splices the channel's spendable balance out to the wallet and pauses funding.
    @MainActor
    func transferToSavings() async throws -> String {
        let feeRate = try await lightningService.channelFundingFeeRate()
        let amount = maxSpliceOutSats(feeRate: feeRate)
        guard amount > 0 else { throw PrimaryNodeError.notConfigured }
        let address = try await lightningService.newAddress()
        isFundingPaused = true
        do {
            return try await sendOnchain(address: address, amountSats: amount, feeRate: feeRate)
        } catch {
            isFundingPaused = false
            throw error
        }
    }

    /// Resolves a pending splice with its new funding transaction; call for every node event.
    func handle(event: Event) {
        switch event {
        case let .splicePending(_, userChannelId, _, newFundingTxo):
            takeSpliceWaiter(userChannelId: userChannelId)?.resume(returning: newFundingTxo.txid.description)
        case let .spliceFailed(_, userChannelId, _, _):
            takeSpliceWaiter(userChannelId: userChannelId)?.resume(throwing: PrimaryReceiveError.spliceFailed)
        default:
            break
        }
    }

    private func awaitSplice(userChannelId: String) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waitersLock.lock()
                spliceWaiters[userChannelId] = continuation
                waitersLock.unlock()
            }
        } onCancel: {
            cancelSpliceWaiter(userChannelId: userChannelId)
        }
    }

    private func takeSpliceWaiter(userChannelId: String) -> CheckedContinuation<String, Error>? {
        waitersLock.lock()
        defer { waitersLock.unlock() }
        return spliceWaiters.removeValue(forKey: userChannelId)
    }

    private func cancelSpliceWaiter(userChannelId: String) {
        takeSpliceWaiter(userChannelId: userChannelId)?.resume(throwing: CancellationError())
    }

    // MARK: Errors

    /// Maps a node error to what the user is told about the primary node.
    static func mapError(_ error: Error) -> Error {
        guard let nodeError = error as? NodeError else { return error }
        switch nodeError {
        case .LiquiditySourceInsufficientFunds: return PrimaryReceiveError.insufficientFunds
        case .LiquidityRequestRejected: return PrimaryReceiveError.rejected
        case .LiquidityRequestTimedOut: return PrimaryReceiveError.timedOut
        case .LiquidityReceiveAmountTooSmall: return PrimaryReceiveError.amountTooSmall
        case .ConnectionFailed, .LiquiditySourceUnavailable, .NotRunning: return PrimaryReceiveError.offline
        default: return error
        }
    }
}

extension Error {
    /// The localized message shown to the user for a primary node failure.
    var primaryErrorMessage: String {
        switch PrimaryNodeService.mapError(self) {
        case PrimaryReceiveError.insufficientFunds: return t("primary_node__error_insufficient_funds")
        case PrimaryReceiveError.rejected: return t("primary_node__error_rejected")
        case PrimaryReceiveError.timedOut: return t("primary_node__error_timed_out")
        case PrimaryReceiveError.amountTooSmall: return t("primary_node__error_amount_too_small")
        case PrimaryReceiveError.offline: return t("primary_node__error_offline")
        case PrimaryReceiveError.busy, PrimaryReceiveError.spliceFailed: return t("primary_node__busy")
        case PrimaryNodeError.invalidInput: return t("primary_node__invalid")
        case PrimaryNodeError.addressUnknown: return t("primary_node__address_required")
        case PrimaryNodeError.connectionInUse: return t("primary_node__connection_in_use")
        case PrimaryNodeError.notConfigured: return t("primary_node__not_configured")
        default: return t("primary_node__error_generic")
        }
    }
}
