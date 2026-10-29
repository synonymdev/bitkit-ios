import BitkitCore
import Combine
import LDKNode
import SwiftUI

@MainActor
class TransferViewModel: ObservableObject {
    @Published var selectedChannelIds: [String] = []
    @Published var channelsToClose: [ChannelDetails] = []

    /// How the LN -> onchain "transfer to savings" is executed. Closing a channel is the
    /// default because it always works; swapping funds out keeps channels open and is used
    /// whenever a priced quote is available.
    @Published var savingsTransferMode: SavingsTransferMode = .close
    @Published var savingsSwapState = SavingsSwapState()

    private let lightningService: LightningService
    private let transferService: TransferService
    private let sheetViewModel: SheetViewModel
    private let onBalanceRefresh: (() async -> Void)?

    private let retryInterval: TimeInterval = 60 // 1 min
    private let giveUpInterval: TimeInterval = 30 * 60 // 30 min
    private var coopCloseRetryTask: Task<Void, Never>?

    private let boltzService: BoltzService = .shared
    /// The in-flight or completed swap execution for the current transfer commit. Held here so
    /// SwiftUI cancelling and re-running the progress screen's `.task` neither cancels the swap
    /// nor creates and pays a second one: re-entry awaits the same run and its memoized result.
    private var savingsSwapRun: Task<SavingsSwapResult, Never>?
    /// The amount (sat) that will actually be swapped out; adjustable via the confirm slider.
    private var pendingSwapAmountSat: UInt64 = 0
    /// Cached swap limits so the slider can re-price locally without hitting the network.
    private var reverseSwapLimits: BoltzPairInfo?
    /// How long the confirm/progress flow waits for the on-chain claim before backgrounding it.
    private let swapClaimTimeout: TimeInterval = 30
    /// Upper bound for fetching swap limits before the confirm screen gives up on a quote.
    private let swapQuoteTimeout: TimeInterval = 15
    /// Minimum sats held back from a swap to cover Lightning routing fees.
    private static let minLnRoutingFeeReserveSats: UInt64 = 10

    init(
        lightningService: LightningService = .shared,
        transferService: TransferService,
        sheetViewModel: SheetViewModel,
        onBalanceRefresh: (() async -> Void)? = nil
    ) {
        self.lightningService = lightningService
        self.transferService = transferService
        self.sheetViewModel = sheetViewModel
        self.onBalanceRefresh = onBalanceRefresh
    }

    /// Convenience initializer for testing and previews. Leave `transferDefaults` nil to persist through
    /// `TransferStorage.shared`, whose change notifications drive backups; tests pass an isolated suite
    /// so mock transfers never reach the app's own store.
    convenience init(
        lightningService: LightningService = .shared,
        sheetViewModel: SheetViewModel = SheetViewModel(),
        transferDefaults: UserDefaults? = nil
    ) {
        let transferService = TransferService(
            storage: transferDefaults.map { TransferStorage(defaults: $0) } ?? .shared,
            lightningService: lightningService
        )
        self.init(
            lightningService: lightningService,
            transferService: transferService,
            sheetViewModel: sheetViewModel
        )
    }

    // MARK: - Manual Channel Opening

    /// Opens a manual channel and tracks the transfer
    /// - Parameters:
    ///   - peer: The Lightning peer to open the channel with
    ///   - amountSats: The channel funding amount in satoshis
    ///   - onEvent: Closure to register an event listener (receives eventId and handler)
    ///   - removeEvent: Closure to remove an event listener (receives eventId)
    /// - Returns: Tuple containing the channel ID and optional funding transaction ID
    /// - Throws: Error if channel opening fails
    func openManualChannel(
        peer: LnPeer,
        amountSats: UInt64,
        onEvent: @escaping (String, @escaping (Event) -> Void) -> Void,
        removeEvent: @escaping (String) -> Void
    ) async throws -> (channelId: String, fundingTxId: String?) {
        // Open the channel - this returns the user channel ID
        let userChannelId = try await lightningService.openChannel(
            peer: peer,
            channelAmountSats: amountSats
        )

        Logger.info("Channel opened successfully with user channel ID: \(userChannelId)", context: "TransferViewModel")

        // Wait for the channel pending event to capture both the actual channel ID and funding tx
        let (actualChannelId, fundingTxId) = await Self.waitForChannelPendingEvent(
            userChannelId: userChannelId,
            onEvent: onEvent,
            removeEvent: removeEvent
        )

        guard let actualChannelId else {
            throw AppError(
                message: "Timeout waiting for channel pending event",
                debugMessage: "Did not receive channelPending event for userChannelId: \(userChannelId)"
            )
        }

        Logger.info(
            "Captured actual channel ID: \(actualChannelId) and fundingTxId: \(fundingTxId ?? "nil")",
            context: "TransferViewModel"
        )

        // Create transfer tracking record with the ACTUAL channel ID (not user channel ID)
        do {
            let transferId = try await transferService.createTransfer(
                type: .toSpending,
                amountSats: amountSats,
                channelId: actualChannelId,
                fundingTxId: fundingTxId
            )
            Logger.info(
                "Created transfer tracking record: \(transferId) with channelId: \(actualChannelId) fundingTxId: \(fundingTxId ?? "nil")",
                context: "TransferViewModel"
            )
        } catch {
            Logger.error("Failed to create transfer tracking record", context: error.localizedDescription)
            // Don't throw - channel is already open
        }

        return (actualChannelId, fundingTxId)
    }

    /// Waits for a channel pending event and captures both the channel ID and funding transaction ID
    /// - Parameters:
    ///   - userChannelId: The user channel ID returned from openChannel
    ///   - onEvent: Closure to register an event listener
    ///   - removeEvent: Closure to remove an event listener
    /// - Returns: Tuple with actual channel ID and funding transaction ID (both nil if timeout)
    private static func waitForChannelPendingEvent(
        userChannelId: String,
        onEvent: @escaping (String, @escaping (Event) -> Void) -> Void,
        removeEvent: @escaping (String) -> Void
    ) async -> (channelId: String?, fundingTxId: String?) {
        let channelCapture = ChannelPendingCapture()
        let eventId = "manual-channel-funding-\(userChannelId)"

        onEvent(eventId) { event in
            if case let .channelPending(
                eventChannelId,
                eventUserChannelId,
                _,
                _,
                fundingTxo
            ) = event,
                // Match by user channel ID
               eventUserChannelId.description == userChannelId
            {
                Task {
                    await channelCapture.setChannelData(
                        channelId: eventChannelId.description,
                        fundingTxId: fundingTxo.txid.description
                    )
                    Logger.debug(
                        "Captured channel pending event: channelId=\(eventChannelId.description) userChannelId=\(userChannelId) fundingTxId=\(fundingTxo.txid.description)",
                        context: "TransferViewModel"
                    )
                }
            }
        }

        let (channelId, fundingTxId) = await waitForChannelData(
            capture: channelCapture,
            maxAttempts: 10,
            initialDelayMs: 50
        )

        removeEvent(eventId)

        return (channelId, fundingTxId)
    }

    /// Wait for channel data (channel ID and funding tx) with exponential backoff
    /// - Parameters:
    ///   - capture: The actor holding the channel data
    ///   - maxAttempts: Maximum number of polling attempts
    ///   - initialDelayMs: Initial delay in milliseconds (will be doubled each attempt)
    /// - Returns: Tuple with channel ID and funding transaction ID (both nil if timeout)
    private static func waitForChannelData(
        capture: ChannelPendingCapture,
        maxAttempts: Int,
        initialDelayMs: UInt64
    ) async -> (channelId: String?, fundingTxId: String?) {
        var delayMs = initialDelayMs

        for attempt in 1 ... maxAttempts {
            // Check if we have the channel data
            if let data = await capture.getChannelData() {
                Logger.debug(
                    "Got channel data on attempt \(attempt): channelId=\(data.channelId)",
                    context: "TransferViewModel"
                )
                return (data.channelId, data.fundingTxId)
            }

            // Don't sleep after the last attempt
            guard attempt < maxAttempts else { break }

            // Sleep with exponential backoff
            let delayNs = delayMs * 1_000_000 // Convert ms to nanoseconds
            do {
                try await Task.sleep(nanoseconds: delayNs)
            } catch {
                Logger.debug("Sleep interrupted while waiting for channel data", context: "TransferViewModel")
                break
            }

            // Exponential backoff: double the delay, max 2 seconds
            delayMs = min(delayMs * 2, 2000)
        }

        return (nil, nil)
    }

    // MARK: - Savings Transfer Methods

    func setSelectedChannelIds(_ ids: [String]) {
        selectedChannelIds = ids
    }

    /// Commit the transfer and pick how it runs. A swap needs a priced quote, so without one
    /// (swaps unsupported on this network, Boltz unreachable, or an amount below the swap
    /// minimum) the transfer closes a channel exactly as it did before swaps existed.
    func onTransferToSavingsConfirm(channels: [ChannelDetails], mode: SavingsTransferMode? = nil) {
        savingsTransferMode = mode ?? resolvedSavingsTransferMode
        selectedChannelIds = []
        channelsToClose = channels
        // Each swipe commit is a new transfer; the previous run's memo must not satisfy it.
        savingsSwapRun = nil
    }

    private var resolvedSavingsTransferMode: SavingsTransferMode {
        savingsSwapState.quote != nil ? .swap : .close
    }

    /// Whether Transfer to Savings closes channels, rather than only withdrawing Arkade's balance.
    var hasChannelsToClose: Bool {
        !channelsToClose.isEmpty
    }

    func closeSelectedChannels() async throws -> [ChannelDetails] {
        try await withdrawArkadeToSavings()
        return try await closeChannels(channels: channelsToClose)
    }

    private func withdrawArkadeToSavings() async throws {
        let arkade = ArkadeManager.shared
        guard arkade.balanceSats > 0 else { return }
        let address = try await lightningService.newAddress()
        try await arkade.withdrawAll(to: address)
    }

    // MARK: - Arkade Funding

    /// Sends `amountSats` of savings to the Arkade boarding address and returns its txid. Once it confirms, the Arkade
    /// wallet boards it into the operator's next batch.
    func fundArkade(address: String, amountSats: UInt64, satsPerVbyte: UInt32, txFee: UInt64, isMaxAmount: Bool) async throws -> String {
        let walletId = OnchainSendAttemptService.walletId(index: lightningService.currentWalletIndex)
        let attempts = OnchainSendAttemptService.shared
        let result = try await attempts.send(
            using: lightningService,
            address: address,
            amountSats: amountSats,
            satsPerVbyte: satsPerVbyte,
            utxosToSpend: nil,
            isMaxAmount: isMaxAmount,
            followupContext: OnchainSendFollowupContext(
                feeSats: txFee,
                feeRate: satsPerVbyte,
                tags: [],
                contact: nil,
                createdAt: UInt64(Date().timeIntervalSince1970)
            )
        )
        guard case let .accepted(txid) = result else {
            throw AppError(message: t("wallet__send_error_tx_failed"), debugMessage: "Arkade funding outcome: \(result)")
        }
        _ = try? await attempts.resumeAcceptedOrdinarySend(walletId: walletId, observedTxid: txid)
        await CoreService.shared.activity.markOnchainActivityAsTransfer(txId: txid)
        ArkadeManager.shared.onDepositBroadcast(txid: txid, amountSats: amountSats)
        Logger.info("Funded Arkade wallet with \(amountSats) sats in \(txid)", context: "TransferViewModel")
        await onBalanceRefresh?()
        return txid
    }

    func closeChannels(channels: [ChannelDetails]) async throws -> [ChannelDetails] {
        var failedChannels: [ChannelDetails] = []
        var successfulChannels: [ChannelDetails] = []

        // Close channels in parallel and track which ones succeeded
        try await withThrowingTaskGroup(of: ChannelDetails?.self) { group in
            for channel in channels {
                group.addTask {
                    do {
                        Logger.info("Closing channel: \(channel.channelId)")
                        try await self.lightningService.closeChannel(channel)
                        return nil
                    } catch {
                        Logger.error("Error closing channel: \(channel.channelId)", context: error.localizedDescription)
                        return channel
                    }
                }
            }

            for try await result in group {
                if let failedChannel = result {
                    failedChannels.append(failedChannel)
                }
            }
        }

        // Determine which channels closed successfully
        successfulChannels = channels.filter { channel in
            !failedChannels.contains { $0.channelId == channel.channelId }
        }

        // Create transfer tracking records only for successfully closed channels
        for channel in successfulChannels {
            do {
                let transferId = try await transferService.createTransfer(
                    type: .toSavings,
                    amountSats: channel.amountOnClose,
                    channelId: channel.channelId.description
                )
                Logger.info("Created transfer tracking record for channel closure: \(transferId)", context: "TransferViewModel")
            } catch {
                Logger.error("Failed to create transfer tracking record for channel: \(channel.channelId)", context: error.localizedDescription)
                // Don't fail the entire operation - the channel is already closed
            }
        }

        // Sync transfer states after attempting closures
        try? await transferService.syncTransferStates()

        await onBalanceRefresh?()

        return failedChannels
    }

    func startCoopCloseRetries(channels: [ChannelDetails], startTime: Date = Date()) {
        channelsToClose = channels
        coopCloseRetryTask?.cancel()

        coopCloseRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let giveUpTime = startTime.addingTimeInterval(giveUpInterval)

            while !Task.isCancelled && Date() < giveUpTime {
                Logger.info("Trying coop close...")
                do {
                    let channelsFailedToCoopClose = try await closeChannels(channels: channelsToClose)

                    if channelsFailedToCoopClose.isEmpty {
                        channelsToClose = []
                        Logger.info("Coop close success.")

                        // Final sync after successful closure
                        try? await transferService.syncTransferStates()
                        await onBalanceRefresh?()

                        return
                    } else {
                        channelsToClose = channelsFailedToCoopClose
                        Logger.info("Coop close failed: \(channelsFailedToCoopClose.map(\.channelId))")
                    }
                } catch {
                    Logger.error("Error during coop close retry", context: error.localizedDescription)
                }

                try? await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000))
            }

            Logger.info("Giving up on coop close.")
            sheetViewModel.showSheet(.forceTransfer)
        }
    }

    /// Force close all channels that failed to cooperatively close
    func forceCloseChannel() async throws {
        guard !channelsToClose.isEmpty else {
            Logger.warn("No channels to force close")
            return
        }

        let channels = channelsToClose
        Logger.info("Force closing \(channels.count) channel(s)")

        var errors: [(channelId: String, error: Error)] = []
        var successfulChannels: [ChannelDetails] = []

        for channel in channels {
            do {
                // Force close the channel first
                try await lightningService.closeChannel(
                    channel,
                    force: true,
                    forceCloseReason: "User requested force close after cooperative close failed"
                )
                Logger.info("Successfully initiated force close for channel: \(channel.channelId)")
                successfulChannels.append(channel)

                // Only create transfer tracking record if force close succeeded
                do {
                    let transferId = try await transferService.createTransfer(
                        type: .toSavings,
                        amountSats: channel.amountOnClose,
                        channelId: channel.channelId.description
                    )
                    Logger.info("Created transfer tracking record for force channel closure: \(transferId)", context: "TransferViewModel")
                } catch {
                    Logger.error(
                        "Failed to create transfer tracking record for force-closed channel: \(channel.channelId)",
                        context: error.localizedDescription
                    )
                    // Don't fail the entire operation - the channel is already force-closed
                }
            } catch {
                Logger.error("Failed to force close channel: \(channel.channelId)", context: error.localizedDescription)
                errors.append((channelId: channel.channelId, error: error))
            }
        }

        channelsToClose.removeAll { channel in
            successfulChannels.contains { $0.channelId == channel.channelId }
        }

        try? await transferService.syncTransferStates()

        await onBalanceRefresh?()

        // If any errors occurred, throw an aggregated error
        if !errors.isEmpty {
            let errorMessages = errors.map { "\($0.channelId): \($0.error.localizedDescription)" }.joined(separator: ", ")
            throw AppError(
                message: "Failed to force close \(errors.count) of \(errors.count + successfulChannels.count) channel(s)",
                debugMessage: errorMessages
            )
        }
    }

    // MARK: - Savings Swap (Boltz reverse swap)

    /// Fetch swap limits, derive the adjustable amount range, and publish an initial fee quote
    /// (defaulting to the maximum transferable) so the user sees the cost before confirming.
    /// The confirm slider then re-prices locally via `onSwapAmountChange`. A quote is the only
    /// thing that unlocks the swap, so every failure simply leaves it nil and the transfer
    /// falls back to closing a channel. Skipped entirely where swaps are unsupported or the
    /// flow is switched off in dev settings, see `BoltzService.isSwapEnabled`.
    /// Show the quote's loading state ahead of `loadSavingsSwapQuote`, covering work that runs
    /// before the fetch (the confirm screen's balance sync) so the swipe cannot briefly land in
    /// the channel-close fallback while a quote is still on its way.
    func beginSavingsSwapQuoteLoad() {
        guard boltzService.isSwapEnabled else { return }
        savingsSwapState = SavingsSwapState(isLoading: true)
    }

    func loadSavingsSwapQuote(requestedSat: UInt64, spendableSats: UInt64) async {
        guard boltzService.isSwapEnabled else { return }
        guard requestedSat > 0 else {
            savingsSwapState = SavingsSwapState()
            return
        }
        savingsSwapState = SavingsSwapState(isLoading: true)

        let fetchedLimits = await fetchReverseSwapLimits()
        // The confirm screen restarts this whenever the amount changes; a superseded invocation
        // must not clobber the state its replacement is about to publish.
        guard !Task.isCancelled else { return }

        guard let limits = fetchedLimits else {
            reverseSwapLimits = nil
            savingsSwapState = SavingsSwapState()
            return
        }
        reverseSwapLimits = limits

        // Reserve headroom for Lightning routing fees. Paying an invoice for 100% of
        // outbound capacity leaves nothing for fees and fails to route, so cap the
        // swap at outbound minus ~1% (with a small floor).
        let routingReserve = max(spendableSats / 100, Self.minLnRoutingFeeReserveSats)
        let sendable = spendableSats > routingReserve ? spendableSats - routingReserve : 0
        let maxSat = min(requestedSat, limits.maximalSat, sendable)
        let minSat = limits.minimalSat

        guard maxSat >= minSat, maxSat > 0 else {
            // Below the swap minimum: revert to the pre-swap view where the swipe closes
            // the channel instead. No fees, slider, or extra close action are shown.
            pendingSwapAmountSat = 0
            savingsSwapState = SavingsSwapState()
            return
        }

        // Default to transferring as much as possible; the slider can lower it.
        pendingSwapAmountSat = maxSat
        savingsSwapState = SavingsSwapState(
            quote: SavingsSwapQuote.build(amountSat: maxSat, limits: limits),
            minSat: minSat,
            maxSat: maxSat
        )
    }

    /// Bounded so a hanging Boltz request cannot leave the confirm swipe stuck loading.
    private func fetchReverseSwapLimits() async -> BoltzPairInfo? {
        await withTaskGroup(of: BoltzPairInfo?.self) { group in
            group.addTask {
                do {
                    return try await self.boltzService.reverseLimits()
                } catch {
                    Logger.error("Failed to load reverse swap limits", context: error.localizedDescription)
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.swapQuoteTimeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    /// Re-price the swap for a slider-selected amount, clamped to the allowed range.
    func onSwapAmountChange(_ sat: UInt64) {
        guard let limits = reverseSwapLimits, savingsSwapState.quote != nil, savingsSwapState.maxSat >= savingsSwapState.minSat else {
            return
        }
        let amount = min(max(sat, savingsSwapState.minSat), savingsSwapState.maxSat)
        pendingSwapAmountSat = amount
        savingsSwapState.quote = SavingsSwapQuote.build(amountSat: amount, limits: limits)
    }

    /// Execute the LN -> onchain swap: derive a fresh claim address, create the swap, pay the
    /// returned hold invoice over Lightning, then wait for whichever resolves first: the on-chain
    /// claim, a Boltz error, or a Lightning routing failure on the payment. A timeout is not a
    /// failure; the claim is auto-broadcast by the updates stream once the lockup confirms, so the
    /// swap completes in the background. `onEvent`/`removeEvent` register a node event listener so
    /// an unroutable payment can be observed (see `awaitSwapOutcome`).
    ///
    /// At most one swap runs per confirm commit: the run is owned by the view model, so the
    /// progress screen's `.task` being cancelled and re-entered joins the same run instead of
    /// creating and paying a second swap.
    func executeSavingsSwap(
        onEvent: @escaping (String, @escaping (Event) -> Void) -> Void,
        removeEvent: @escaping (String) -> Void
    ) async -> SavingsSwapResult {
        if let run = savingsSwapRun {
            return await run.value
        }
        let run = Task { await performSavingsSwap(onEvent: onEvent, removeEvent: removeEvent) }
        savingsSwapRun = run
        return await run.value
    }

    private func performSavingsSwap(
        onEvent: @escaping (String, @escaping (Event) -> Void) -> Void,
        removeEvent: @escaping (String) -> Void
    ) async -> SavingsSwapResult {
        let amount = pendingSwapAmountSat
        guard amount > 0 else {
            return .failure(message: t("lightning__savings_confirm__amount_too_low"))
        }

        do {
            // The confirm screen counts Arkade's balance in the transfer, and the swap moves only the channel's.
            try await withdrawArkadeToSavings()
            let claimAddress = try await lightningService.newAddress()
            let swap = try await boltzService.createReverseSwap(amountSat: amount, claimAddress: claimAddress)
            Logger.info("Created savings transfer swap \(swap.id)", context: "TransferViewModel")

            // Subscribe before paying so a claim settling faster than the payment call returns is
            // not missed (events buffer from stream creation).
            let events = boltzService.events()

            // Pay the hold invoice. `send` returns a payment id as soon as the HTLC is dispatched;
            // a hold invoice never settles until Boltz claims on-chain, so this does not block on
            // the claim. A failure to dispatch the payment throws and is surfaced immediately.
            let paymentId = try await lightningService.send(bolt11: swap.invoice)

            let result = await awaitSwapOutcome(
                swapId: swap.id,
                paymentId: paymentId,
                events: events,
                onEvent: onEvent,
                removeEvent: removeEvent
            )
            await onBalanceRefresh?()
            return result
        } catch {
            Logger.error("Savings transfer swap failed", context: error.localizedDescription)
            return .failure(message: error.localizedDescription)
        }
    }

    /// Wait for whichever swap outcome resolves first. `send` returning does not mean the payment
    /// routed, and a paid hold invoice never settles until the on-chain claim, so an unroutable
    /// payment would otherwise idle into the claim timeout and read as a settling transfer that
    /// never completes. Watching the node's payment-failed event alongside the claim surfaces it
    /// as a failure instead. A timeout still resolves to `.pending`: the claim settles later.
    private func awaitSwapOutcome(
        swapId: String,
        paymentId: String,
        events: AsyncStream<BoltzSwapEvent>,
        onEvent: @escaping (String, @escaping (Event) -> Void) -> Void,
        removeEvent: @escaping (String) -> Void
    ) async -> SavingsSwapResult {
        let eventId = "savings-swap-\(swapId)"
        let paymentFailure = SwapPaymentFailureCapture()

        // LDK events are dispatched on the main actor, so this handler runs there; it records a
        // routing failure for the paid hold invoice and resumes the failure wait below. The
        // returned payment id may land in either the event's payment id or its payment hash field.
        onEvent(eventId) { event in
            guard case let .paymentFailed(eventPaymentId, eventPaymentHash, reason) = event,
                  [eventPaymentId, eventPaymentHash].compactMap({ $0 }).contains(paymentId) else { return }
            Task { await paymentFailure.markFailed(reason: reason) }
        }

        // Capture main-actor state locally so the detached group tasks stay Sendable.
        let claimTimeout = swapClaimTimeout

        let outcome = await withTaskGroup(of: SavingsSwapResult?.self) { group in
            // On-chain claim or a Boltz-side error.
            group.addTask {
                for await event in events {
                    switch event {
                    case let .claimed(swapId: id, txid: txid) where id == swapId:
                        return .success(txid: txid)
                    case let .error(swapId: id, message: message) where id == swapId:
                        return .failure(message: message)
                    default:
                        continue
                    }
                }
                return nil
            }
            // Lightning routing failure on the paid hold invoice, surfaced the moment the node
            // reports it, with the failure reason mapped to a user-facing message.
            group.addTask {
                let wait = await withTaskCancellationHandler {
                    await paymentFailure.waitForFailure()
                } onCancel: {
                    Task { await paymentFailure.cancelWaits() }
                }
                guard case let .failed(reason) = wait else { return nil }
                return .failure(message: PaymentFailureReason.userMessage(for: reason))
            }
            // Bounded wait: a timeout is not a failure, the claim settles in the background.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(claimTimeout * 1_000_000_000))
                return .pending
            }

            var result: SavingsSwapResult = .pending
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
        return outcome
    }
}

/// Captures a Lightning routing failure for the savings swap's hold-invoice payment. The node
/// event handler runs on the main actor and resumes the waiting continuation, so the racing
/// wait in `awaitSwapOutcome` surfaces the failure the moment it is reported instead of polling.
actor SwapPaymentFailureCapture {
    enum Wait: Equatable {
        case failed(reason: PaymentFailureReason?)
        case cancelled
    }

    private var outcome: Wait?
    private var waiters: [CheckedContinuation<Wait, Never>] = []

    func markFailed(reason: PaymentFailureReason?) {
        finish(with: .failed(reason: reason))
    }

    /// Unblocks the wait when its surrounding task is cancelled (another branch of the race
    /// won); a continuation left pending would keep the task group from ever finishing.
    func cancelWaits() {
        finish(with: .cancelled)
    }

    func waitForFailure() async -> Wait {
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func finish(with wait: Wait) {
        guard outcome == nil else { return }
        outcome = wait
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume(returning: wait)
        }
    }
}

/// Whether a transfer to savings swaps funds out or closes a channel (default).
enum SavingsTransferMode {
    case swap
    case close
}

struct SavingsSwapQuote: Equatable {
    let amountSat: UInt64
    let networkFeeSat: UInt64
    let swapFeeSat: UInt64
    let receiveSat: UInt64

    /// Estimate the fee breakdown for swapping `amountSat` out under the given pair limits.
    static func build(amountSat: UInt64, limits: BoltzPairInfo) -> SavingsSwapQuote {
        let swapFee = UInt64(max(0, (Double(amountSat) * limits.feePercentage / 100.0).rounded()))
        let networkFee = limits.minerFeesSat
        let totalFees = swapFee + networkFee
        let receive = amountSat > totalFees ? amountSat - totalFees : 0
        return SavingsSwapQuote(amountSat: amountSat, networkFeeSat: networkFee, swapFeeSat: swapFee, receiveSat: receive)
    }
}

struct SavingsSwapState {
    var isLoading = false
    var quote: SavingsSwapQuote?
    /// Inclusive adjustable range for the confirm slider (sat). Equal/zero when unavailable.
    var minSat: UInt64 = 0
    var maxSat: UInt64 = 0
}

enum SavingsSwapResult: Equatable {
    /// Funds landed on-chain during the flow.
    case success(txid: String)
    /// Swap created and invoice paid; the claim completes in the background.
    case pending
    case failure(message: String)
}

/// Actor to safely capture channel data from channel pending events
/// Ensures thread-safe access when the event callback may execute on different threads
actor ChannelPendingCapture {
    struct ChannelData {
        let channelId: String
        let fundingTxId: String
    }

    private var channelData: ChannelData?

    func setChannelData(channelId: String, fundingTxId: String) {
        channelData = ChannelData(channelId: channelId, fundingTxId: fundingTxId)
    }

    func getChannelData() -> ChannelData? {
        return channelData
    }
}
