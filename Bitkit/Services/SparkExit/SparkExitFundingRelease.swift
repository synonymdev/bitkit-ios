import Foundation

/// A savings send to a Spark exit's funding address, told apart by that address alone. Once the exit no longer needs
/// it, the send can be released like a Shop payment whose request ended, instead of blocking every new send.
enum SparkExitFundingRelease {
    /// The exit state the checks read: the wallet's record and its earlier exits' addresses.
    struct Exit: Equatable {
        var record: SparkExitRecord?
        var earlier: [SparkExitEarlierAddress]
    }

    /// Whether `attempt` pays the funding address of the exit in `record` or of an earlier exit.
    static func isExitFunding(_ attempt: OnchainSendAttempt, exit: Exit) -> Bool {
        guard attempt.mayFundSparkExit else { return false }
        return exit.record?.funding.first?.address == attempt.address || exit.earlier.contains { $0.address == attempt.address }
    }

    /// Whether the exit no longer needs `attempt`: it was cancelled or ended, or it holds all the funding it asked for
    /// and none of it is `attempt`'s. While the exit still waits for one of `attempt`'s transactions, or asks for
    /// funding at its address, it needs it; one it adopted means the payment landed, so it is never released.
    static func exitNoLongerNeeds(_ attempt: OnchainSendAttempt, exit: Exit) -> Bool {
        guard attempt.mayFundSparkExit else { return false }
        guard let record = exit.record, record.funding.first?.address == attempt.address else {
            return exit.earlier.contains { $0.address == attempt.address }
        }
        // A payment the exit still waits for; once other funding filled it, the txid stays behind unwatched.
        let awaited = record.isAwaitingOwnPayment || record.isEndedPaymentPending ? record.fundingPaymentTxid : nil
        let landed = record.funding.compactMap(\.txid) + record.leftover.map(\.txid) + [awaited].compactMap { $0 }
        guard !landed.contains(where: { attempt.containsCandidate($0) }) else { return false }
        return !record.isActive || record.fundingShortfallSats == nil
    }

    /// Whether one of `attempt`'s transactions landed at the exit, as funding or as leftover: it reached the network.
    static func isAdopted(_ attempt: OnchainSendAttempt, exit: Exit) -> Bool {
        guard let record = exit.record else { return false }
        return (record.funding.compactMap(\.txid) + record.leftover.map(\.txid)).contains { attempt.containsCandidate($0) }
    }

    /// Whether savings may pay `attempt` to the exit again now, over what its funding address holds (`utxos`, nil when
    /// it could not be read): while the exit still asks for funding there, waits for this very payment, or holds this
    /// payment's own coin, and never once its release was approved. A retry re-signs the same inputs, so it never pays
    /// twice, and what savings pays beyond the ask comes back as leftover. A send to no exit's address is not this
    /// check's to refuse.
    static func mayPayAgain(_ attempt: OnchainSendAttempt, exit: Exit, utxos: [EsploraUtxo]?) -> Bool {
        // A release approved for it is Send Pending's to finish, even once the exit's record is gone.
        guard !(attempt.mayFundSparkExit && attempt.releaseApproved == true) else { return false }
        guard isExitFunding(attempt, exit: exit) else { return true }
        guard let record = exit.record, record.isActive,
              record.funding.first?.address == attempt.address, let utxos
        else { return false }
        // Other wallets' coins alone cover the funding: nothing is left to ask, and its release takes care of it.
        let isOwnPaid = record.fundingPaymentTxid.map { attempt.containsCandidate($0) } ?? false
        var unpaid = record
        if isOwnPaid {
            unpaid.fundingPaymentTxid = nil
        }
        if case .seen = SparkExitMath.fundingState(unpaid, utxos: utxos.filter { !attempt.containsCandidate($0.txid) }) {
            return false
        }
        switch SparkExitMath.fundingState(record, utxos: utxos) {
        // Partial payments from other wallets still leave an ask.
        case .ask: return true
        // Waiting for this very payment.
        case .paid: return isOwnPaid
        // Covered with this payment's own unconfirmed coin: a retry only bumps it.
        case .seen:
            return SparkExitMath.newFunding(utxos, record: record).contains { !$0.status.confirmed && attempt.containsCandidate($0.txid) }
        default: return false
        }
    }

    /// The stored exit of the wallet `attempt` was sent from; nil when it cannot be read, so nothing is released.
    static func storedExit(for attempt: OnchainSendAttempt) -> Exit? {
        let walletIndex = LightningService.shared.currentWalletIndex
        guard attempt.walletId == OnchainSendAttemptService.walletId(index: walletIndex) else { return nil }
        do {
            // An unreadable list of earlier addresses holds no exit that is still asking.
            return try Exit(
                record: SparkExitStore(walletIndex: walletIndex).load(),
                earlier: (try? SparkExitEarlierAddressStore(walletIndex: walletIndex).load()) ?? []
            )
        } catch {
            return nil
        }
    }

    /// Refuses paying `attempt` to a Spark exit again once the stored exit of its wallet no longer asks for it, read right
    /// before dispatch; an exit that cannot be read refuses a send that may fund one.
    static func authorizePayAgain(_ attempt: OnchainSendAttempt) async throws {
        guard attempt.mayFundSparkExit else { return }
        guard let exit = storedExit(for: attempt) else {
            throw AppError(message: t("wallet__send_error_tx_failed"), debugMessage: "The Spark exit could not be read")
        }
        let chain = SparkManager.exitNetwork.map { EsploraSparkExitChain.network($0) }
        try await authorizePayAgain(attempt, exit: exit, chain: chain)
    }

    /// Refuses paying `attempt` to a Spark exit again once the exit no longer asks for it, read right before dispatch.
    static func authorizePayAgain(_ attempt: OnchainSendAttempt, exit: Exit, chain: SparkExitChain?) async throws {
        guard attempt.releaseApproved == true || isExitFunding(attempt, exit: exit) else { return }
        let utxos = try? await chain?.utxos(address: attempt.address)
        guard mayPayAgain(attempt, exit: exit, utxos: utxos) else {
            throw AppError(message: t("wallet__send_error_tx_failed"), debugMessage: "The Spark exit no longer asks for this funding")
        }
    }
}
