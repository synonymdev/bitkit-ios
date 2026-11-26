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
        let landed = record.funding.compactMap(\.txid) + record.leftover.map(\.txid) + [record.fundingPaymentTxid].compactMap { $0 }
        guard !landed.contains(where: { attempt.containsCandidate($0) }) else { return false }
        return !record.isActive || record.fundingShortfallSats == nil
    }

    /// Whether savings may pay `attempt` to the exit again now, over what its funding address holds (`utxos`, nil when
    /// it could not be read): only while the exit still asks for funding there and nothing reached it, or while it
    /// waits for this very payment. A send to no exit's address is not this check's to refuse.
    static func mayPayAgain(_ attempt: OnchainSendAttempt, exit: Exit, utxos: [EsploraUtxo]?) -> Bool {
        guard isExitFunding(attempt, exit: exit) else { return true }
        guard let record = exit.record, record.isActive, record.funding.first?.address == attempt.address, let utxos else { return false }
        switch SparkExitMath.fundingState(record, utxos: utxos) {
        case .ask(_, 0): return true
        case let .paid(txid): return attempt.containsCandidate(txid)
        default: return false
        }
    }

    /// The stored exit of the wallet `attempt` was sent from; nil when it cannot be read, so nothing is released.
    static func storedExit(for attempt: OnchainSendAttempt) -> Exit? {
        let walletIndex = LightningService.shared.currentWalletIndex
        guard attempt.walletId == OnchainSendAttemptService.walletId(index: walletIndex) else { return nil }
        do {
            return try Exit(
                record: SparkExitStore(walletIndex: walletIndex).load(),
                earlier: SparkExitEarlierAddressStore(walletIndex: walletIndex).load()
            )
        } catch {
            return nil
        }
    }

    /// Refuses paying `attempt` to a Spark exit again once the exit no longer asks for it, read right before dispatch.
    static func authorizePayAgain(_ attempt: OnchainSendAttempt, exit: Exit, chain: SparkExitChain?) async throws {
        guard isExitFunding(attempt, exit: exit) else { return }
        let utxos = try? await chain?.utxos(address: attempt.address)
        guard mayPayAgain(attempt, exit: exit, utxos: utxos) else {
            throw AppError(message: t("wallet__send_error_tx_failed"), debugMessage: "The Spark exit no longer asks for this funding")
        }
    }
}
