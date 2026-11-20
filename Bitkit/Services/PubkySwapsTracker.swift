import BitkitCore
import Foundation

/// The hold payment of a committed swap: its hash, and its invoice, which the channel-free rail is asked about.
struct PubkySwapHoldPayment: Codable, Equatable {
    let paymentHash: String
    let invoice: String
}

/// The swaps committed or restored whose claim has not confirmed, with the hold payment of each committed one, kept
/// across launches so each start resumes them. A wipe clears it with the rest of the app's defaults.
struct UnfinishedPubkySwapsStore {
    static let swapIdsKey = "unfinishedPubkySwaps"
    static let holdPaymentsKey = "pubkySwapHoldPayments"

    var defaults: UserDefaults = .standard

    var swapIds: [String] {
        defaults.stringArray(forKey: Self.swapIdsKey) ?? []
    }

    func track(_ ids: [String]) {
        var tracked = swapIds
        for id in ids where !tracked.contains(id) {
            tracked.append(id)
        }
        defaults.set(tracked, forKey: Self.swapIdsKey)
    }

    func untrack(_ id: String) {
        defaults.set(swapIds.filter { $0 != id }, forKey: Self.swapIdsKey)
        var payments = holdPayments
        payments[id] = nil
        save(payments)
    }

    func holdPayment(for id: String) -> PubkySwapHoldPayment? {
        holdPayments[id]
    }

    func setHoldPayment(_ payment: PubkySwapHoldPayment, for id: String) {
        var payments = holdPayments
        payments[id] = payment
        save(payments)
    }

    func clear() {
        defaults.removeObject(forKey: Self.swapIdsKey)
        defaults.removeObject(forKey: Self.holdPaymentsKey)
    }

    private var holdPayments: [String: PubkySwapHoldPayment] {
        guard let data = defaults.data(forKey: Self.holdPaymentsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: PubkySwapHoldPayment].self, from: data)) ?? [:]
    }

    private func save(_ payments: [String: PubkySwapHoldPayment]) {
        guard let data = try? JSONEncoder().encode(payments) else { return }
        defaults.set(data, forKey: Self.holdPaymentsKey)
    }
}

/// Keeps each committed or restored swap advancing until its claim confirms or it fails, also after a restart: the
/// provider settles the hold invoice once it sees the claim, so a claim that never confirms could leave the contact
/// unpaid.
actor PubkySwapsTracker {
    typealias Advance = @Sendable (_ swapId: String) async throws -> PubkySwapRouteState
    typealias HoldPaymentCheck = @Sendable (PubkySwapHoldPayment) async -> Bool
    typealias Finished = @Sendable (_ swapId: String) async -> Void

    static let shared: PubkySwapsTracker = .init(
        advance: { try await PubkySwapsRouteService.advance(swapId: $0) },
        isHoldPaymentFailed: { await PubkySwapsRouteService.isHoldPaymentFailed($0) },
        didFinish: { await PubkySwapsWakeGrants.shared.revoke(swapId: $0) }
    )

    private let store: UnfinishedPubkySwapsStore
    private let advance: Advance
    private let isHoldPaymentFailed: HoldPaymentCheck
    /// Runs once a swap stops being tracked, so its wake grant is revoked.
    private let didFinish: Finished
    private let claimPollInterval: Duration
    private let confirmationPollInterval: Duration

    /// Swaps a caller awaits the claim of, which no resume advances beside it.
    private var claiming: Set<String> = []
    /// The loop advancing each swap in the background, one per swap.
    private var advancing: [String: Task<Void, Never>] = [:]
    /// Swaps this session committed, which the send flow drives, so a restore listing them leaves them alone.
    private var committed: Set<String> = []
    /// Swaps whose hold payment failed this session, which nothing advances again.
    private var dropped: Set<String> = []

    init(
        store: UnfinishedPubkySwapsStore = UnfinishedPubkySwapsStore(),
        advance: @escaping Advance,
        isHoldPaymentFailed: @escaping HoldPaymentCheck,
        didFinish: @escaping Finished = { _ in },
        claimPollInterval: Duration = .seconds(2),
        confirmationPollInterval: Duration = .seconds(30)
    ) {
        self.store = store
        self.advance = advance
        self.isHoldPaymentFailed = isHoldPaymentFailed
        self.didFinish = didFinish
        self.claimPollInterval = claimPollInterval
        self.confirmationPollInterval = confirmationPollInterval
    }

    var unfinishedSwapIds: [String] {
        store.swapIds
    }

    func isAdvancing(_ swapId: String) -> Bool {
        advancing[swapId] != nil
    }

    func didCommit(_ swapId: String) {
        committed.insert(swapId)
        store.track([swapId])
    }

    /// Recorded before the hold payment goes out, so a hold failing at any point stops the swap, also after a restart.
    func watchHold(_ payment: PubkySwapHoldPayment, swapId: String) {
        store.setHoldPayment(payment, for: swapId)
    }

    /// Takes up the swaps a restore found. A swap committed or dropped this session is the send flow's, so the known
    /// swaps returned leave it out.
    func adoptRestored(restored: [String], known: [String]) -> (restored: [String], known: [String]) {
        let known = known.filter { !committed.contains($0) && !dropped.contains($0) }
        store.track(restored + known)
        return (restored, known)
    }

    /// Advances each swap a closed app left unfinished until its claim confirms or it fails.
    func resume() {
        for swapId in store.swapIds where !claiming.contains(swapId) {
            advanceInBackground(swapId)
        }
    }

    /// Stops a swap whose hold payment failed or never went out: the provider never funds it, so advancing it would
    /// only poll until bitkit-core gives up.
    func drop(_ swapId: String) {
        dropped.insert(swapId)
        advancing.removeValue(forKey: swapId)?.cancel()
        finish(swapId)
    }

    /// Stops the wiped wallet's swaps, so a wallet restored next starts from nothing.
    func resetForWipe() {
        advancing.values.forEach { $0.cancel() }
        advancing.removeAll()
        claiming.removeAll()
        committed.removeAll()
        dropped.removeAll()
        store.clear()
    }

    /// Advances the swap until bitkit-core broadcasts the claim, returning the claim txid, then keeps advancing it in the
    /// background until the claim confirms. A wait that runs out, or a caller that stops waiting, leaves it advancing in
    /// the background too, as the provider may still settle the hold payment.
    func awaitClaim(swapId: String, timeout: TimeInterval) async throws -> String {
        guard !dropped.contains(swapId) else { throw PubkySwapClaimError.holdFailed }
        claiming.insert(swapId)
        defer { claiming.remove(swapId) }
        do {
            let txid = try await pollClaim(swapId: swapId, interval: claimPollInterval, timeout: timeout, untilConfirmed: false)
            advanceInBackground(swapId)
            return txid
        } catch let PubkySwapClaimError.timedOut(lastFailure) {
            advanceInBackground(swapId)
            throw PubkySwapClaimError.timedOut(lastFailure)
        } catch is CancellationError {
            advanceInBackground(swapId)
            throw CancellationError()
        } catch {
            finish(swapId)
            throw error
        }
    }

    private func advanceInBackground(_ swapId: String) {
        guard advancing[swapId] == nil, !dropped.contains(swapId) else { return }
        advancing[swapId] = Task { await self.awaitConfirmation(swapId) }
    }

    private func awaitConfirmation(_ swapId: String) async {
        do {
            let txid = try await pollClaim(swapId: swapId, interval: confirmationPollInterval, timeout: nil, untilConfirmed: true)
            Logger.info("Confirmed Pubky Swaps claim \(txid) for \(swapId)", context: "PubkySwapsRoute")
        } catch is CancellationError {
            return
        } catch {
            if case PubkySwapClaimError.holdFailed = error {
                dropped.insert(swapId)
            }
            Logger.warn("Failed to confirm Pubky Swaps claim for \(swapId): \(error)", context: "PubkySwapsRoute")
        }
        // A drop or a wipe that cancelled this loop already removed it.
        guard !Task.isCancelled else { return }
        advancing[swapId] = nil
        finish(swapId)
    }

    private func finish(_ swapId: String) {
        store.untrack(swapId)
        let didFinish = didFinish
        Task { await didFinish(swapId) }
    }

    /// A `swap.claimable` wake names no swap, and wakes on the topic collapse, so one may stand for several swaps. Every
    /// unfinished swap is advanced until each has its claim broadcast or has ended, or `timeout` passes, and then keeps
    /// advancing in the background. Returns whether a claim went out or no swap is left open.
    func advanceForClaimableWake(timeout: Duration, interval: Duration) async -> Bool {
        let run = ClaimableWakeRun(open: Set(store.swapIds))
        _ = await withDeadline(timeout) { await self.advanceOpenSwaps(run, interval: interval) }
        for swapId in store.swapIds where !claiming.contains(swapId) {
            advanceInBackground(swapId)
        }
        return run.isClaimBroadcast || run.open.isEmpty
    }

    private func advanceOpenSwaps(_ run: ClaimableWakeRun, interval: Duration) async {
        while !run.open.isEmpty, !Task.isCancelled {
            for swapId in run.open.sorted() {
                guard !Task.isCancelled else { return }
                do {
                    switch try await advance(swapId) {
                    case .claimBroadcast:
                        run.isClaimBroadcast = true
                        run.open.remove(swapId)
                    case .claimed, .failed:
                        run.open.remove(swapId)
                    case .awaitingPayment, .awaitingLockup:
                        break
                    }
                } catch {
                    if PubkySwapsRouteService.isUnknownSwap(error) {
                        run.open.remove(swapId)
                    } else {
                        Logger.warn("Failed to advance Pubky Swaps route \(swapId) for a wake: \(error)", context: "PubkySwapsRoute")
                    }
                }
            }
            guard !run.open.isEmpty else { return }
            try? await Task.sleep(for: interval)
        }
    }

    private func pollClaim(swapId: String, interval: Duration, timeout: TimeInterval?, untilConfirmed: Bool) async throws -> String {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var lastFailure: Error = AppError(message: "Swap \(swapId) not claimed yet", debugMessage: nil)
        while true {
            try Task.checkCancellation()
            // A swap whose hold failed, also while the app was closed or over Spark, is never funded.
            if dropped.contains(swapId) {
                throw PubkySwapClaimError.holdFailed
            }
            if untilConfirmed, let hold = store.holdPayment(for: swapId), await isHoldPaymentFailed(hold) {
                throw PubkySwapClaimError.holdFailed
            }
            let state: PubkySwapRouteState?
            do {
                state = try await advance(swapId)
            } catch {
                // A swap bitkit-core has no record of, as one carried over by a backup, never advances.
                if PubkySwapsRouteService.isUnknownSwap(error) {
                    throw error
                }
                // A failed advance, such as a transient Electrum error, is retried: the swap is already funded.
                Logger.warn("Failed to advance Pubky Swaps route \(swapId): \(error)", context: "PubkySwapsRoute")
                lastFailure = error
                state = nil
            }
            switch state {
            case let .claimed(txid)?:
                return txid
            case let .claimBroadcast(txid)? where !untilConfirmed:
                return txid
            case let .failed(reason)?:
                throw PubkySwapClaimError.failed(reason)
            case let state?:
                Logger.debug("Pubky Swaps route \(swapId): \(state)", context: "PubkySwapsRoute")
                lastFailure = AppError(message: "Swap \(swapId) not claimed yet", debugMessage: "\(state)")
            case nil:
                break
            }
            if let deadline, Date() >= deadline {
                throw PubkySwapClaimError.timedOut(lastFailure)
            }
            try await Task.sleep(for: interval)
        }
    }
}

/// What a `swap.claimable` wake reached so far, read once its deadline passes.
private final class ClaimableWakeRun {
    var open: Set<String>
    var isClaimBroadcast = false

    init(open: Set<String>) {
        self.open = open
    }
}
