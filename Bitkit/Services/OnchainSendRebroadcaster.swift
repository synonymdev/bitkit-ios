import Combine
import Foundation

/// Rebroadcasts an on-chain payment whose broadcast outcome is unknown once the wallet syncs
/// again, so a send cut off by a dropped connection still reaches the network.
///
/// It spends the same coins at no higher fee than the user approved, so it can never create a
/// second payment. A resend that reaches the network adds a candidate, so each payment is
/// resent at most once; a try that stops before dispatch is repeated on a later sync.
@MainActor
final class OnchainSendRebroadcaster {
    static let shared = OnchainSendRebroadcaster()

    nonisolated static let retryInterval: TimeInterval = 60
    /// Background syncs report only their completion, so this, not `isSyncingWallet`, marks a working connection.
    nonisolated static let onchainSyncCompleted = PassthroughSubject<Void, Never>()

    private var lastTriedAt: [UUID: Date] = [:]
    private var isRunning = false

    func rebroadcastIfNeeded(
        paymentRequests: PaykitPaymentRequestManager,
        attempts: OnchainSendAttemptService = .shared,
        proofService: PaykitPaymentProofService = .shared
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let walletId = OnchainSendAttemptService.walletId(index: LightningService.shared.currentWalletIndex)
        let now = Date()
        guard let attempt = try? await attempts.unresolvedAttempt(walletId: walletId),
              Self.shouldRebroadcast(attempt),
              Self.isDue(lastTriedAt: lastTriedAt[attempt.id], now: now),
              let txid = attempt.txid, let approvedFee = Self.approvedFee(attempt)
        else { return }
        lastTriedAt[attempt.id] = now

        let context = OnchainSendPendingContext(attemptId: attempt.id, walletId: attempt.walletId, txid: txid)
        Logger.info("Rebroadcasting on-chain payment \(txid) with an unknown outcome", context: "OnchainSendRebroadcaster")
        do {
            let paymentDeadline: PaykitPreciseInstant? = if attempt.requestId != nil {
                try await proofService.authorizeOnchainRecovery(attempt, restoreStartedProof: false).paymentDeadline
            } else {
                nil
            }
            let result = try await attempts.retrySamePayment(
                using: LightningService.shared, context: context, paymentDeadline: paymentDeadline,
                approvePrepared: { prepared in
                    guard let fee = prepared.miningFeeSats, fee <= approvedFee else {
                        throw OnchainSendAttemptError.retryConstruction
                    }
                },
                authorize: { attempt, _ in
                    guard attempt.requestId != nil else { return }
                    let authorization = try await paymentRequests.ensureOnchainRecoveryAllowed(attempt, proofService: proofService)
                    guard authorization.paymentDeadline == paymentDeadline else { throw PaykitPaymentRequestError.requestUnavailable }
                }
            )
            Logger.info("Rebroadcast of on-chain payment \(txid) ended as \(result)", context: "OnchainSendRebroadcaster")
            try await completeAccepted(context: context, attempts: attempts, proofService: proofService)
        } catch {
            Logger.warn("Could not rebroadcast on-chain payment \(txid): \(error)", context: "OnchainSendRebroadcaster")
        }
    }

    /// Ordinary sends and Paykit payment requests whose original broadcast outcome is unknown.
    /// Transfers keep their manual retry, which re-checks the order with Blocktank.
    nonisolated static func shouldRebroadcast(_ attempt: OnchainSendAttempt) -> Bool {
        attempt.status == .unknown && attempt.orderId == nil && attempt.canRetrySamePayment &&
            attempt.recoveryContext?.candidateTxids.count == 1
    }

    nonisolated static func isDue(lastTriedAt: Date?, now: Date) -> Bool {
        guard let lastTriedAt else { return true }
        return now.timeIntervalSince(lastTriedAt) >= retryInterval
    }

    nonisolated static func approvedFee(_ attempt: OnchainSendAttempt) -> UInt64? {
        guard let txid = attempt.txid else { return nil }
        let fee = attempt.recoveryContext?.candidateFeeSats?[txid.lowercased()] ?? attempt.followupContext?.feeSats
        return fee.flatMap { $0 > 0 ? $0 : nil }
    }

    private func completeAccepted(
        context: OnchainSendPendingContext,
        attempts: OnchainSendAttemptService,
        proofService: PaykitPaymentProofService
    ) async throws {
        guard let attempt = try await attempts.pendingAttempt(context: context), attempt.status == .accepted else { return }
        if let requestId = attempt.requestId {
            if let payer = attempt.recoveryContext?.paymentIdentity {
                _ = await proofService.resolvedOnchainPayment(requestId: requestId, identity: payer, context: context)
            }
            await proofService.reconcile()
        } else {
            _ = try await attempts.resumeAcceptedOrdinarySend(walletId: attempt.walletId, pendingContext: context)
        }
    }
}
