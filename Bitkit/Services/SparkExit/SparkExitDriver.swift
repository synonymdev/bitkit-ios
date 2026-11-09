import BreezSdkSpark
import CryptoKit
import Foundation

/// The SDK calls an exit makes. `BreezSdk` in the app, a fake in tests.
protocol SparkExitRecovering: Sendable {
    func prepare(_ request: PrepareRecoverFundsRequest) async throws -> PrepareRecoverFundsResponse
    func recover(_ request: RecoverFundsRequest, signer: CpfpSigner?) async throws -> RecoverFundsResponse
    func check(_ recovery: RecoverFundsResponse) async throws -> CheckRecoverFundsResponse
    func exportExitState() async throws -> String
    func importExitState(_ exitState: String) async throws
}

enum SparkExitFeeBumpError: Error, Equatable {
    case notConnected
    /// At this rate a leaf could no longer pay its own exit and would stay on Spark: the rate is not offered.
    case leavesBehind(sats: UInt64)
}

/// Moves an exit one step forward each tick: builds it once its fee funding confirms, broadcasts what is ready,
/// rebuilds when the chain diverged, and finishes when everything confirmed. Without the SDK (a background launch,
/// or operators down at connect) it still broadcasts the stored, already signed transactions whose parents
/// confirmed. Every built recovery is saved before anything of it is broadcast, and every broadcast is saved as
/// soon as its outcome is known. Once the task running it is cancelled (a background run expiring) it starts no
/// SDK call and no broadcast, and saves what it did, so the next run resumes without sending anything twice.
struct SparkExitDriver {
    let chain: SparkExitChain
    /// nil while the Spark SDK is not connected.
    let recovering: SparkExitRecovering?
    /// The signer of the funding key at the record's index.
    let makeSigner: (UInt32) throws -> CpfpSigner
    let save: (SparkExitRecord) throws -> Void
    var now: () -> Date = Date.init

    /// A ready transaction accepted in this generation is sent again after this long, in case a node dropped it.
    static let rebroadcastInterval: TimeInterval = 600
    /// After this many rejections of one transaction the progress screen shows the error.
    static let rejectionsToSurface = 3
    /// The least time between two builds, so a divergence that persists does not rebuild every tick.
    static let rebuildInterval: TimeInterval = 600
    /// Chain host reads in flight at once.
    static let concurrentReads = 8
    /// Rebuilds in a row that reproduce a step whose input another transaction spent before its leaf counts as lost:
    /// an older state of the wallet claimed it, and every rebuild would send the same refund again.
    static let strikesToLoseLeaf = 2
    /// Fee chain failures in a row of one step, its parents confirmed, that rebuild the exit.
    static let feeChainFailuresToRebuild = 3
    /// Rebuilds over stuck steps with no step confirming in between, after which the exit says it is not moving.
    static let stallRebuildsToSurface = 3
    /// Blocks an accepted step may stay unconfirmed before the exit says the network is busier than its rate.
    static let unconfirmedBlocksToSurface: UInt32 = 6
    /// A leaf the operators' watchtower stopped is relabelled promptly; one still stopped after this many blocks
    /// never will be.
    static let stoppedLeafBlocks: UInt32 = 6
    /// A build waiting for a leaf that may still move tries again after this many blocks, doubling up to a day.
    static let retryBlocks: UInt32 = 6
    static let retryMaxBlocks: UInt32 = 144
    /// About a week: what is still waiting then is let go, so the exit can end.
    static let releaseBlocks: UInt32 = 1008
    /// Blocks an accepted leftover sweep may stay unconfirmed before it is replaced at a higher rate.
    static let sweepReplaceBlocks: UInt32 = 144
    /// While the fee change is not worth sending, the sweep checks the network's rate again after this many blocks.
    static let sweepRecheckBlocks: UInt32 = 144
    /// About four weeks: then the change too small to send stays at the funding address.
    static let sweepWaitBlocks: UInt32 = 4032
    /// A savings payment Bitkit sent that no host knows for this many blocks, or that the exit did not adopt within
    /// `ownPaymentTimeoutBlocks`, is forgotten: the exit asks for the funding, and reminds, again.
    static let ownPaymentMissingBlocks: UInt32 = 1
    static let ownPaymentTimeoutBlocks: UInt32 = 144

    @discardableResult
    func tick(_ record: SparkExitRecord) async throws -> SparkExitRecord {
        var record = record
        switch record.phase {
        case .done, .failed:
            guard record.needsDriving, !Task.isCancelled else { return record }
            let before = record
            await followEndedPayment(&record)
            if record.isLeftoverSweepPending {
                try await sweepLeftover(&record)
                try save(record)
                return record
            }
            return try saveIfChanged(record, from: before)
        case .awaitingFunding, .needsFunding:
            guard !Task.isCancelled else { return record }
            let before = record
            await noteOwnPayment(&record)
            // A higher fee's top-up leaves the current generation valid: it keeps being checked and sent meanwhile.
            if record.isDrivingWhileFunding {
                if let recovering {
                    try await driveWhileFunding(&record, recovering: recovering)
                } else {
                    try await broadcastWithoutSdk(&record)
                }
            }
            // Still waiting for funding (a generation that finished meanwhile is back to running).
            if record.phase != .running {
                guard let recovering else { return try saveIfChanged(record, from: before) }
                // Nothing to fund when every leaf is recovered cooperatively.
                if let shortfall = record.fundingShortfallSats {
                    guard try await adoptFunding(&record, requiredSats: shortfall) else { return try saveIfChanged(record, from: before) }
                }
                try await build(&record, recovering: recovering)
            }
        case .running where record.isRebuilding:
            // The diverged generation is never broadcast again; only a rebuild moves on from here.
            guard let recovering, !Task.isCancelled, isRebuildDue(record) else { return record }
            try await build(&record, recovering: recovering)
        case .running:
            if Task.isCancelled {
                return record
            }
            if let recovering {
                try await check(&record, recovering: recovering)
            } else {
                try await broadcastWithoutSdk(&record)
                // Every step in a block, as the chain host shows: the exit ends without waiting for the SDK. Leaves the
                // operators could not co-sign need the SDK's retry, so that exit waits for it.
                if let recovery = record.recovery?.response, !recovery.transactions.isEmpty, recovery.failed.isEmpty,
                   recovery.transactions.allSatisfy(\.isConfirmed)
                {
                    await finish(&record, phase: .done)
                }
            }
        }
        // Without the tip the countdown keeps its last target rather than jump to another measure.
        if let tip = try? await chain.tipHeight() {
            record.claimableAtHeight = record.recovery.flatMap { SparkExitMath.claimableAtHeight($0.response, tip: tip) }
        } else if record.claimableAtHeight == nil {
            record.claimableAtHeight = record.recovery.flatMap { SparkExitMath.claimableAtHeight($0.response) }
        }
        try save(record)
        return record
    }

    private func saveIfChanged(_ record: SparkExitRecord, from before: SparkExitRecord) throws -> SparkExitRecord {
        if record != before {
            try save(record)
        }
        return record
    }

    // MARK: Funding

    /// Forgets a savings payment the exit waits for once no host knows it for `ownPaymentMissingBlocks` (dropped or
    /// replaced), or once it is older than `ownPaymentTimeoutBlocks` without being adopted, so the ask and the reminder
    /// come back. Nothing changes without a tip.
    private func noteOwnPayment(_ record: inout SparkExitRecord) async {
        guard record.isAwaitingOwnPayment || record.isEndedPaymentPending, let paid = record.fundingPaymentTxid,
              let tip = try? await chain.tipHeight()
        else { return }
        let seenAt = record.fundingPaymentSeenAtHeight ?? tip
        record.fundingPaymentSeenAtHeight = seenAt
        switch try? await chain.isKnown(txid: paid) {
        case true?: record.fundingPaymentMissingSince = nil
        case false?: record.fundingPaymentMissingSince = record.fundingPaymentMissingSince ?? tip
        case nil: break
        }
        let isMissing = record.fundingPaymentMissingSince.map { tip.saturatingSub($0) >= Self.ownPaymentMissingBlocks } ?? false
        let isTooOld = tip.saturatingSub(seenAt) >= Self.ownPaymentTimeoutBlocks
        guard isMissing || isTooOld else { return }
        Logger.warn("Spark exit forgets its funding payment \(paid) (missing: \(isMissing), too old: \(isTooOld))", context: "SparkExitDriver")
        record.fundingPaymentTxid = nil
        record.fundingPaymentSeenAtHeight = nil
        record.fundingPaymentMissingSince = nil
    }

    /// An ended exit's savings payment that had not arrived: once at the funding address it joins the leftover and is
    /// swept with it, after any sweep in flight settles (a confirmed one is kept in `sweptLeftover`). One no host
    /// sees is forgotten by the own-payment expiry.
    private func followEndedPayment(_ record: inout SparkExitRecord) async {
        guard !record.isActive, let paid = record.fundingPaymentTxid else { return }
        guard record.isEndedPaymentPending else {
            // Already in the leftover (or adopted as funding): nothing more to follow.
            record.fundingPaymentTxid = nil
            record.fundingPaymentSeenAtHeight = nil
            record.fundingPaymentMissingSince = nil
            return
        }
        guard let address = record.funding.first?.address, let tip = try? await chain.tipHeight(),
              let listed = try? await chain.utxos(address: address)
        else { return }
        guard listed.contains(where: { $0.txid == paid }) else {
            await noteOwnPayment(&record)
            return
        }
        let sweep = record.leftoverSweep
        var isSweepConfirmed = sweep?.isConfirmed == true
        if let txid = sweep?.txid, !isSweepConfirmed, sweep?.rejection == nil {
            // In flight: its coins are settled first, so the payment is never mixed into a sweep that may replace it.
            guard let status = try? await chain.txStatus(txid: txid), status.confirmed else { return }
            isSweepConfirmed = true
        } else if sweep?.txid == nil, await isAnyKnown(sweep?.replacedTxids ?? []) {
            return
        }
        if isSweepConfirmed, let sweep, let txid = sweep.txid {
            if !(record.sweptLeftover ?? []).contains(where: { $0.txid == txid }) {
                record.sweptLeftover = (record.sweptLeftover ?? []) + [.init(txid: txid, valueSats: sweep.valueSats)]
            }
            // A host behind the block can still list what the sweep spent.
            let spent = Set((sweep.txHex.flatMap(SparkExitTxid.inputOutpoints(hex:)) ?? []).map { "\($0.txid):\($0.vout)" })
            record.leftover = listed.filter { !spent.contains("\($0.txid):\($0.vout)") }
                .map { SparkExitRecord.Leftover(txid: $0.txid, vout: $0.vout, valueSats: $0.value) }
        } else {
            let known = Set(record.leftover.map { "\($0.txid):\($0.vout)" })
            record.leftover += listed.filter { $0.txid == paid && !known.contains("\($0.txid):\($0.vout)") }
                .map { SparkExitRecord.Leftover(txid: $0.txid, vout: $0.vout, valueSats: $0.value) }
        }
        Logger.info("Spark exit funding payment \(paid) arrived after the exit ended; sweeping it back", context: "SparkExitDriver")
        record.leftoverSweep = SparkExitRecord.LeftoverSweep(waitingSince: tip, checkedAtHeight: tip, retryAtHeight: tip)
        record.fundingPaymentTxid = nil
        record.fundingPaymentSeenAtHeight = nil
        record.fundingPaymentMissingSince = nil
    }

    /// While a higher fee's top-up is awaited: the current generation is checked and its ready steps sent. A
    /// generation that finished in the meantime runs on to Done; one that diverged waits for the top-up's rebuild.
    private func driveWhileFunding(_ record: inout SparkExitRecord, recovering: SparkExitRecovering) async throws {
        guard let stored = record.recovery?.response else { return }
        let checked = try await recovering.check(withConfirmations(stored))
        record.recovery = StoredRecovery(checked.recovery)
        record.noteProgressAfterRebuildFromChain(checked.recovery)
        switch checked.verdict {
        case .valid:
            let tip = try? await chain.tipHeight()
            try await broadcastReady(&record, tip: tip)
        case .done:
            // Nothing is left to pay more for: back to running, whose next check finishes it (failed leaves included).
            // A payment still on its way is followed after the end and swept back with the leftover.
            record.phase = .running
        case .redo:
            break
        }
    }

    /// Adds every confirmed new UTXO at the funding address as a funding input once together they cover
    /// `requiredSats`.
    private func adoptFunding(_ record: inout SparkExitRecord, requiredSats: UInt64) async throws -> Bool {
        guard let address = record.funding.first?.address, let pubkey = record.funding.first?.pubkey else { return false }
        let utxos = try await chain.utxos(address: address)
        guard let topUp = SparkExitMath.fundingTopUp(
            SparkExitMath.newFunding(utxos, record: record),
            requiredSats: requiredSats,
            inputFeeSats: SparkExitMath.inputFeeSats(record)
        ) else {
            return false
        }
        let index = record.fundingIndex
        if record.funding.count == 1, record.funding[0].txid == nil {
            record.funding = []
        }
        record.funding += topUp.map {
            SparkExitRecord.Funding(index: index, address: address, pubkey: pubkey, txid: $0.txid, vout: $0.vout, valueSats: $0.value)
        }
        return true
    }

    // MARK: Build

    private func build(_ record: inout SparkExitRecord, recovering: SparkExitRecovering) async throws {
        let tip = try? await chain.tipHeight()
        // Waiting for a leaf that may still move: tried again at growing gaps of blocks, not every tick.
        if let since = record.retrySince {
            guard let tip, Self.isRetryDue(since: since, retriedAt: record.retriedAt ?? since, tip: tip) else { return }
        }
        await useExitStateSnapshot(&record, recovering: recovering)
        guard let prepared = try await prepare(&record, recovering: recovering) else {
            // The last leaf lost on a tick that could not read the funding address ends here, still as lost.
            await finish(&record, phase: .failed(reason: record.isEveryLeafLost ? SparkExitRecord.lostReason : "No leaf can be exited"))
            return
        }
        noteStoppedLeaves(prepared, tip: tip, in: &record)
        guard !prepared.leaves.isEmpty else {
            // A leaf the chain could not be read for, or one the operators' watchtower just stopped, may still move:
            // the build waits for it, for about a week. Finished leaves are not listed.
            if prepared.skipped.contains(where: { isProvisional($0, prepared: prepared, record: record, tip: tip) }) {
                guard let tip else { return }
                let since = record.retrySince ?? tip
                if tip.saturatingSub(since) < Self.releaseBlocks {
                    record.retrySince = since
                    record.retriedAt = tip
                    return
                }
                Logger.warn("Spark exit lets go of the leaves it waited about a week for", context: "SparkExitDriver")
            }
            record.retrySince = nil
            record.retriedAt = nil
            record.skippedLeafCount = max(record.skippedLeafCount, prepared.skipped.count)
            let isRecovered = record.recovery != nil || record.isRebuiltFromChain == true
            await finish(&record, phase: isRecovered ? .done : .failed(reason: "Nothing left to recover"))
            return
        }
        record.retrySince = nil
        record.retriedAt = nil
        let built: RecoverFundsResponse
        do {
            built = try await recovering.recover(
                RecoverFundsRequest(prepared: prepared, fundingInputs: prepared.funding == nil ? [] : record.fundingInputs),
                signer: prepared.funding == nil ? nil : makeSigner(record.fundingIndex)
            )
        } catch let SdkError.SparkError(message) where SparkExitMath.isUnexitableLeafError(message) {
            // Built at the same fee rate, a leaf can still fail here: leave it behind and rebuild at once.
            if let leafId = SparkExitMath.unexitableLeafId(message), record.exitLeafIds.contains(leafId) {
                leaveBehind([leafId], reason: message, in: &record)
            }
            record.isRebuilding = record.recovery != nil
            record.lastBuildAt = nil
            return
        } catch let SdkError.InsufficientCpfpFunds(requiredSats, _) {
            // The SDK names the total all inputs must hold, not what is missing.
            var utxos: [EsploraUtxo]?
            if let address = record.funding.first?.address {
                utxos = try? await chain.utxos(address: address)
            }
            record.phase = .needsFunding(requiredSats: SparkExitMath.neededFunding(requiredSats: requiredSats, record: record, utxos: utxos))
            return
        }
        guard !built.transactions.isEmpty else {
            // Only cooperative leaves the operators could not co-sign: kept as the exit's recovery, so the next check
            // puts them through the bounded failed-leaf retry (about a week), with the operators-waiting line.
            if !built.failed.isEmpty {
                record.adopt(built, at: now())
                return
            }
            await finish(&record, phase: .failed(reason: "Nothing to recover"))
            return
        }
        // A leaf the watchtower stopped moments ago is no older state's: it is never struck while it may still move.
        let waiting = Set(built.transactions.compactMap(\.nodeId).filter { isStoppedRecently($0, prepared: prepared, record: record, tip: tip) })
        let strikes = record.recovery == nil || record.isRedoRebuild != true ? [:] : record.strikes(rebuiltInto: built).filter { txid, _ in
            !built.transactions.contains { $0.txid == txid && $0.nodeId.map(waiting.contains) == true }
        }
        let lost = lostLeaves(built, strikes: strikes, record: record)
        if !lost.isEmpty {
            Logger.warn("Spark exit leaves claimed by an older state: \(lost.map(\.leafId))", context: "SparkExitDriver")
            record.lostLeaves = (record.lostLeaves ?? []) + lost
            record.spentStepStrikes = nil
            // Not adopted: the next tick rebuilds at once without the lost leaves.
            record.isRebuilding = true
            record.lastBuildAt = nil
            if record.exitLeafIds.isEmpty {
                await finish(&record, phase: .failed(reason: SparkExitRecord.lostReason))
            }
            return
        }
        record.adopt(built, at: now())
        record.spentStepStrikes = strikes.isEmpty ? nil : strikes
        // Saved before any of it is broadcast, so a crash never leaves broadcast transactions without their record.
        try save(record)
        try await broadcastReady(&record)
    }

    /// Prepares the exit's leaves. `Specific` fails as a whole when one fee-ladder leaf cannot pay its refund's fee:
    /// that leaf is left behind and the rest prepared again, and when the error names no leaf, `RecoverableOnly`
    /// prepares what it can and the leaves it leaves out stay behind. Nil once no leaf can be exited.
    private func prepare(_ record: inout SparkExitRecord, recovering: SparkExitRecovering) async throws -> PrepareRecoverFundsResponse? {
        var isRecoverableOnly = false
        while !record.exitLeafIds.isEmpty {
            do {
                let prepared = try await recovering.prepare(record.prepareRequest(
                    isRecoverableOnly ? .recoverableOnly : .specific(leafIds: record.exitLeafIds)
                ))
                guard isRecoverableOnly else { return prepared }
                let kept = Set(prepared.leaves.map(\.leafId))
                leaveBehind(record.exitLeafIds.filter { !kept.contains($0) }, reason: "Not recoverable at this fee rate", in: &record)
                // It also takes the wallet's leaves outside this exit, such as one an older state claimed in an
                // earlier exit: the exit's own are prepared again on their own.
                guard prepared.leaves.contains(where: { !record.exitLeafIds.contains($0.leafId) }) else { return prepared }
                guard !record.exitLeafIds.isEmpty else { return nil }
                return try await recovering.prepare(record.prepareRequest(.specific(leafIds: record.exitLeafIds)))
            } catch let SdkError.SparkError(message) where SparkExitMath.isUnexitableLeafError(message) {
                if let leafId = SparkExitMath.unexitableLeafId(message), record.exitLeafIds.contains(leafId) {
                    leaveBehind([leafId], reason: message, in: &record)
                } else if isRecoverableOnly {
                    throw SdkError.SparkError(message)
                } else {
                    isRecoverableOnly = true
                }
            }
        }
        return nil
    }

    private func leaveBehind(_ leafIds: [String], reason: String, in record: inout SparkExitRecord) {
        guard !leafIds.isEmpty else { return }
        let values = Dictionary((record.recovery?.response.leaves ?? []).map { ($0.leafId, $0.valueSats) }, uniquingKeysWith: { first, _ in first })
        Logger.warn("Spark exit leaves left behind: \(leafIds): \(reason)", context: "SparkExitDriver")
        record.leftBehindLeaves = (record.leftBehindLeaves ?? []) + leafIds.map {
            SparkExitRecord.LeftBehindLeaf(leafId: $0, valueSats: values[$0] ?? 0, reason: reason)
        }
    }

    /// The SDK's exit data from just before the first build, so every rebuild sees the leaves as they were then. The
    /// operators may stop reporting a leaf once it is being exited, and a later export would lack it.
    private func useExitStateSnapshot(_ record: inout SparkExitRecord, recovering: SparkExitRecovering) async {
        // An exit rebuilt from the chain is past its first build: an export now may already lack the moved leaves.
        if record.recovery == nil, record.generation == 0, record.exitStateSnapshot == nil, record.isRebuiltFromChain != true {
            do {
                record.exitStateSnapshot = try await recovering.exportExitState()
            } catch {
                Logger.warn("Failed to export the Spark exit data before the first build: \(error)", context: "SparkExitDriver")
            }
        } else if let snapshot = record.exitStateSnapshot, record.recovery != nil || record.generation > 0 {
            do {
                try await recovering.importExitState(snapshot)
            } catch {
                Logger.warn("Failed to import the Spark exit data before a rebuild: \(error)", context: "SparkExitDriver")
            }
        }
    }

    private func noteStoppedLeaves(_ prepared: PrepareRecoverFundsResponse, tip: UInt32?, in record: inout SparkExitRecord) {
        guard let tip else { return }
        let own = Set(record.exitLeafIds)
        let fresh = prepared.exitChainState.stoppedLeafIds.filter { own.contains($0) && record.stoppedLeafSince?[$0] == nil }
        guard !fresh.isEmpty else { return }
        var since = record.stoppedLeafSince ?? [:]
        for leafId in fresh {
            since[leafId] = tip
        }
        record.stoppedLeafSince = since
    }

    /// Stopped by the operators' watchtower fewer than `stoppedLeafBlocks` ago, or with no tip to tell.
    private func isStoppedRecently(_ leafId: String, prepared: PrepareRecoverFundsResponse, record: SparkExitRecord, tip: UInt32?) -> Bool {
        guard prepared.exitChainState.stoppedLeafIds.contains(leafId) else { return false }
        guard let tip, let since = record.stoppedLeafSince?[leafId] else { return true }
        return tip.saturatingSub(since) < Self.stoppedLeafBlocks
    }

    /// A skip of one of the exit's leaves that may still move: the chain could not be read for it, its funds were not
    /// found yet, the operators could not be asked where they are, or the watchtower stopped it moments ago.
    private func isProvisional(_ skip: SkippedLeaf, prepared: PrepareRecoverFundsResponse, record: SparkExitRecord, tip: UInt32?) -> Bool {
        guard record.exitLeafIds.contains(skip.leafId) else { return false }
        switch skip.reason {
        case .unverified, .fundsNotFound, .operatorsUnavailable: return true
        case .notRecoverable: return isStoppedRecently(skip.leafId, prepared: prepared, record: record, tip: tip)
        case .feeExceedsValue: return false
        }
    }

    /// Six blocks after the wait starts, then at doubling gaps up to a day (Glow's `retryDue`).
    static func isRetryDue(since: UInt32, retriedAt: UInt32, tip: UInt32) -> Bool {
        let last = max(since, retriedAt)
        let gap = min(retryMaxBlocks, max(retryBlocks, last - since))
        return tip.saturatingSub(last) >= gap
    }

    /// The leaves whose refund a rebuild reproduced after its input was spent by another transaction in each of the
    /// last generations. A refund's node id is its leaf.
    private func lostLeaves(_ built: RecoverFundsResponse, strikes: [String: Int], record: SparkExitRecord) -> [SparkExitRecord.LostLeaf] {
        let values = Dictionary(
            ((record.recovery?.response.leaves ?? []) + built.leaves).map { ($0.leafId, $0.valueSats) },
            uniquingKeysWith: { first, _ in first }
        )
        var lost: [SparkExitRecord.LostLeaf] = []
        for tx in built.transactions where tx.kind == .refund && strikes[tx.txid, default: 0] >= Self.strikesToLoseLeaf {
            guard let leafId = tx.nodeId, record.exitLeafIds.contains(leafId), !lost.contains(where: { $0.leafId == leafId }) else { continue }
            lost.append(.init(leafId: leafId, valueSats: values[leafId] ?? 0))
        }
        return lost
    }

    // MARK: Check

    private func check(_ record: inout SparkExitRecord, recovering: SparkExitRecovering) async throws {
        guard let stored = record.recovery?.response else {
            record.phase = .awaitingFunding(requiredSats: 0)
            return
        }
        // Nothing to check on-chain: only cooperative leaves the operators have not co-signed yet.
        if stored.transactions.isEmpty, !stored.failed.isEmpty {
            let tip = try? await chain.tipHeight()
            if try await retryFailedLeaves(&record, failed: stored.failed, recovering: recovering, tip: tip) {
                return
            }
            await finish(&record, phase: .done)
            return
        }
        let checked = try await recovering.check(withConfirmations(stored))
        record.recovery = StoredRecovery(checked.recovery)
        record.noteProgressAfterRebuildFromChain(checked.recovery)
        let tip = try? await chain.tipHeight()
        // A step that confirmed since the last rebuild over a stuck step shows the exit moves again.
        if let count = record.stallConfirmedCount, SparkExitMath.confirmedCount(checked.recovery) > count {
            record.stallRebuilds = nil
            record.stallConfirmedCount = nil
        }
        switch checked.verdict {
        case .valid:
            // A step the SDK could not read is settled by a fresh build, once a block, unless a step is still to send:
            // a build now would conflict with it at the same fee.
            if let tip, isUnverifiedRebuildDue(checked.recovery, record: record, tip: tip) {
                Logger.warn("Spark exit has a step the SDK could not read, rebuilding over it", context: "SparkExitDriver")
                record.unverifiedRebuiltAtHeight = tip
                try save(record)
                try await build(&record, recovering: recovering)
                return
            }
            // The SDK sees no divergence when another wallet's CPFP child confirmed a node our leaves share.
            let dead = record.isStalled ? [] : await deadCpfpChildren(checked.recovery, stored: stored)
            if !dead.isEmpty {
                Logger.warn("Spark exit fee chain lost a race (dead children \(dead)), rebuilding", context: "SparkExitDriver")
                try await rebuildStalled(&record, recovering: recovering)
                return
            }
            try await broadcastReady(&record, tip: tip)
            if !record.isStalled, let stuck = record.stuckStep {
                Logger.warn("Spark exit step \(stuck.txid) keeps being refused (\(stuck.lastOutcome)), rebuilding", context: "SparkExitDriver")
                try await rebuildStalled(&record, recovering: recovering)
            }
        case .done:
            if try await retryFailedLeaves(&record, failed: checked.recovery.failed, recovering: recovering, tip: tip) {
                return
            }
            await finish(&record, phase: .done)
        case .redo:
            Logger.warn("Spark exit diverged on-chain, rebuilding generation \(record.generation + 1)", context: "SparkExitDriver")
            record.isRedoRebuild = true
            try await rebuild(&record, recovering: recovering)
        }
    }

    /// Cooperative leaves a finished recovery lists as failed: the operators' watchtower moved them on-chain and the
    /// operators could not co-sign their recovery. They stay part of the exit and are prepared again as a recovery of
    /// their own, at once and then at Glow's doubling gaps (`isRetryDue`), until they land or about a week passed
    /// (`releaseBlocks`). True while the exit keeps waiting for them, false once it can end.
    private func retryFailedLeaves(
        _ record: inout SparkExitRecord,
        failed: [CooperativeRecoveryFailure],
        recovering: SparkExitRecovering,
        tip: UInt32?
    ) async throws -> Bool {
        let failedIds = failed.map(\.leafId)
        guard !failedIds.isEmpty, record.isFailedLeavesReleased != true else { return false }
        guard let tip else { return true }
        let since = record.failedLeafRetrySince ?? tip
        record.failedLeafRetrySince = since
        if tip.saturatingSub(since) >= Self.releaseBlocks {
            Logger.warn("Spark exit lets go of leaves the operators could not co-sign: \(failedIds)", context: "SparkExitDriver")
            record.isFailedLeavesReleased = true
            return false
        }
        if let retriedAt = record.failedLeafRetriedAt, !Self.isRetryDue(since: since, retriedAt: retriedAt, tip: tip) {
            return true
        }
        record.failedLeafRetriedAt = tip
        try save(record)
        guard !Task.isCancelled else { return true }
        await useExitStateSnapshot(&record, recovering: recovering)
        do {
            let prepared = try await recovering.prepare(record.prepareRequest(.specific(leafIds: failedIds)))
            noteFailedLeafValues(prepared, failedIds: failedIds, in: &record)
            guard !prepared.leaves.isEmpty else { return true }
            let built = try await recovering.recover(
                RecoverFundsRequest(prepared: prepared, fundingInputs: prepared.funding == nil ? [] : record.fundingInputs),
                signer: prepared.funding == nil ? nil : makeSigner(record.fundingIndex)
            )
            guard !built.transactions.isEmpty else { return true }
            Logger.info("Spark exit recovers \(built.leaves.count) leaves the operators moved on-chain", context: "SparkExitDriver")
            record.adopt(built, at: now())
            try save(record)
            try await broadcastReady(&record, tip: tip)
        } catch {
            Logger.warn("Spark exit could not recover the leaves the operators moved on-chain yet: \(error)", context: "SparkExitDriver")
        }
        return true
    }

    /// Keeps the value of each failed leaf from what the SDK reports for it, listed or skipped.
    private func noteFailedLeafValues(_ prepared: PrepareRecoverFundsResponse, failedIds: [String], in record: inout SparkExitRecord) {
        let reported = Dictionary(
            prepared.leaves.map { ($0.leafId, $0.valueSats) } + prepared.skipped.map { ($0.leafId, $0.valueSats) },
            uniquingKeysWith: { first, _ in first }
        )
        let known = Dictionary((record.failedLeaves ?? []).map { ($0.leafId, $0.valueSats) }, uniquingKeysWith: { first, _ in first })
        record.failedLeaves = failedIds.map { SparkExitRecord.FailedLeaf(leafId: $0, valueSats: reported[$0] ?? known[$0] ?? 0) }
    }

    // MARK: Fee bump

    /// What the funding address still has to receive for the exit to rebuild at `rate`, 0 when what it holds covers
    /// it. Builds the exit's leaves at that rate with the funding it has, the way a rebuild would, and broadcasts
    /// nothing; a shortfall is sized like a rebuild's (`neededFunding`), the input fee of the payment to come included.
    func feeBumpShortfall(_ record: SparkExitRecord, rate: UInt64) async throws -> UInt64 {
        guard let recovering else { throw SparkExitFeeBumpError.notConnected }
        // A copy at the new rate: a leaf the SDK refuses at that rate is left behind on the copy only, as a rebuild would.
        var record = record
        record.feeRateSatPerVbyte = rate
        await useExitStateSnapshot(&record, recovering: recovering)
        let leftBehindBefore = record.leftBehindSats
        let leavesBefore = Set(record.exitLeafIds)
        guard let prepared = try await prepare(&record, recovering: recovering) else {
            throw SparkExitFeeBumpError.leavesBehind(sats: record.leftBehindSats.saturatingSub(leftBehindBefore))
        }
        // A rate at which a leaf can't pay its own exit would leave it on Spark: never offered.
        if Set(record.exitLeafIds) != leavesBefore {
            let values = Dictionary((record.recovery?.response.leaves ?? []).map { ($0.leafId, $0.valueSats) }, uniquingKeysWith: { a, _ in a })
            let dropped = leavesBefore.subtracting(record.exitLeafIds).reduce(UInt64(0)) { $0 + (values[$1] ?? 0) }
            throw SparkExitFeeBumpError.leavesBehind(sats: dropped)
        }
        guard prepared.funding != nil, !prepared.leaves.isEmpty else { return 0 }
        do {
            _ = try await recovering.recover(
                RecoverFundsRequest(prepared: prepared, fundingInputs: record.fundingInputs),
                signer: makeSigner(record.fundingIndex)
            )
            return 0
        } catch let SdkError.SparkError(message) where SparkExitMath.isUnexitableLeafError(message) {
            // The build refused a leaf at this rate: it would stay on Spark, so the rate is not offered.
            let leafId = SparkExitMath.unexitableLeafId(message)
            let value = (record.recovery?.response.leaves ?? []).first { $0.leafId == leafId }?.valueSats ?? 0
            throw SparkExitFeeBumpError.leavesBehind(sats: value)
        } catch let SdkError.InsufficientCpfpFunds(requiredSats, _) {
            var atRate = record
            atRate.feeRateSatPerVbyte = rate
            let utxos = try? await chain.utxos(address: record.funding.first?.address ?? "")
            let needed = SparkExitMath.neededFunding(requiredSats: requiredSats, record: atRate, utxos: utxos)
            return max(needed.saturatingSub(record.fundedSats), SparkExitMath.fundingDustSats)
        }
    }

    /// A rebuild over a chain that stopped moving: refused steps, missing inputs, unpaid children or a dead CPFP child.
    /// Only `stallRebuildsToSurface` of them run while no step confirms, so a stale chain index or a step no build can
    /// fix does not rebuild forever; the exit then says it is not moving.
    private func rebuildStalled(_ record: inout SparkExitRecord, recovering: SparkExitRecovering) async throws {
        record.isRedoRebuild = nil
        record.stallRebuilds = (record.stallRebuilds ?? 0) + 1
        record.stallConfirmedCount = record.recovery.map { SparkExitMath.confirmedCount($0.response) } ?? 0
        try await rebuild(&record, recovering: recovering)
    }

    /// A unilateral step the SDK could not read, nothing unilateral ready to send, and no such rebuild at this tip yet.
    private func isUnverifiedRebuildDue(_ recovery: RecoverFundsResponse, record: SparkExitRecord, tip: UInt32) -> Bool {
        let unilateral = recovery.transactions.filter { $0.kind != .cooperative }
        return unilateral.contains { $0.status == .unverified } && !unilateral.contains { $0.status == .ready }
            && record.unverifiedRebuiltAtHeight != tip
    }

    /// Saved as rebuilding first, so nothing of the replaced generation is broadcast again, then rebuilt once due.
    private func rebuild(_ record: inout SparkExitRecord, recovering: SparkExitRecovering) async throws {
        record.isRebuilding = true
        try save(record)
        guard !Task.isCancelled, isRebuildDue(record) else { return }
        try await build(&record, recovering: recovering)
    }

    /// Our CPFP children that a step still to confirm builds on, and that can never confirm: the node each pays for
    /// is in a block, yet the child is neither in a block nor in the mempool. Another wallet's child won the race
    /// for a node both exits share, so the change ours would leave never exists. A child the hosts could not be
    /// asked about counts as alive.
    private func deadCpfpChildren(_ recovery: RecoverFundsResponse, stored: RecoverFundsResponse) async -> [String] {
        let confirmed = Set(recovery.transactions.filter(\.isConfirmed).map(\.txid))
        var stepOfChild: [String: String] = [:]
        for tx in stored.transactions {
            if let child = tx.cpfpTxHex.flatMap(SparkExitTxid.txid(hex:)) {
                stepOfChild[child] = tx.txid
            }
        }
        var suspects = Set<String>()
        for tx in stored.transactions where !confirmed.contains(tx.txid) {
            guard let inputs = tx.cpfpTxHex.flatMap(SparkExitTxid.inputTxids(hex:)) else { continue }
            suspects.formUnion(inputs.filter { stepOfChild[$0].map(confirmed.contains) == true })
        }
        var dead: [String] = []
        for child in suspects.sorted() where !Task.isCancelled {
            if await (try? chain.isKnown(txid: child)) == false {
                dead.append(child)
            }
        }
        return dead
    }

    /// Marks the next steps the chain host shows in a block as confirmed. The SDK asks the chain about a step only
    /// once the caller saw it in a block; otherwise it looks for who spent its input, which an Electrum-backed
    /// mempool, such as Spark's regtest, does not report.
    private func withConfirmations(_ recovery: RecoverFundsResponse) async -> RecoverFundsResponse {
        var recovery = recovery
        var confirmed = Set(recovery.transactions.filter(\.isConfirmed).map(\.txid))
        var asked = Set<String>()
        // One round per depth, each read at once: a 30-transaction exit takes a few rounds instead of 30 reads in a row.
        while !Task.isCancelled {
            let next = recovery.transactions.indices.filter { i in
                let tx = recovery.transactions[i]
                return !confirmed.contains(tx.txid) && !asked.contains(tx.txid) && tx.dependsOn.allSatisfy(confirmed.contains)
            }
            guard !next.isEmpty else { break }
            let statuses = await statuses(next.map { recovery.transactions[$0].txid })
            asked.formUnion(next.map { recovery.transactions[$0].txid })
            for i in next {
                guard let status = statuses[recovery.transactions[i].txid], status.confirmed else { continue }
                confirmed.insert(recovery.transactions[i].txid)
                recovery.transactions[i].status = .confirmed(blockHeight: status.blockHeight)
            }
        }
        return recovery
    }

    /// The chain host's status of each transaction, read concurrently; one it could not answer is left out.
    private func statuses(_ txids: [String]) async -> [String: EsploraTxStatus] {
        await withTaskGroup(of: (String, EsploraTxStatus?).self) { group in
            var results: [String: EsploraTxStatus] = [:]
            var pending = Set(txids).makeIterator()
            func addNext() -> Bool {
                guard let txid = pending.next() else { return false }
                group.addTask { [chain] in await (txid, try? chain.txStatus(txid: txid)) }
                return true
            }
            for _ in 0 ..< Self.concurrentReads {
                guard addNext() else { break }
            }
            while let (txid, status) = await group.next() {
                results[txid] = status
                _ = addNext()
            }
            return results
        }
    }

    private func isRebuildDue(_ record: SparkExitRecord) -> Bool {
        guard let last = record.lastBuildAt else { return true }
        return now().timeIntervalSince(last) >= Self.rebuildInterval
    }

    /// Ends the exit and notes what is left at the funding address, which the next step sweeps to savings. While the
    /// address cannot be read the exit keeps its phase: one ended without its leftover read would never sweep it, so
    /// the next tick ends it instead.
    private func finish(_ record: inout SparkExitRecord, phase: SparkExitRecord.Phase) async {
        guard let address = record.funding.first?.address else {
            record.phase = phase
            return
        }
        guard let utxos = try? await chain.utxos(address: address) else { return }
        record.phase = phase
        record.leftover = utxos.map { SparkExitRecord.Leftover(txid: $0.txid, vout: $0.vout, valueSats: $0.value) }
        if record.isLeftoverSweepPending, !Task.isCancelled {
            try? await sweepLeftover(&record)
        }
    }

    // MARK: Leftover

    /// Sends the confirmed leftover at the funding address to the exit's savings address, signed with the funding
    /// key. Built and saved once before it is sent, then sent again on later ticks until it confirms. Waits while
    /// the leftover is unconfirmed, and skips it when the fee would leave less than dust. One refused for its fee, or
    /// accepted but unconfirmed for `sweepReplaceBlocks`, is built again over the same coins at the network's current
    /// rate, which replaces it (RBF).
    private func sweepLeftover(_ record: inout SparkExitRecord) async throws {
        // A sweep it replaced may confirm instead: that ends the sweep as well.
        for txid in record.leftoverSweep?.replacedTxids ?? [] where record.leftoverSweep?.isConfirmed != true {
            if let status = try? await chain.txStatus(txid: txid), status.confirmed {
                record.leftoverSweep?.isConfirmed = true
                await followRemainingOutputs(&record)
                return
            }
        }
        // A sweep refused for its fee, before this rule or on the last tick, waits for the next block and a rate the
        // node takes.
        if let sweep = record.leftoverSweep, let rejection = sweep.rejection, sweep.isFeeRejection, !sweep.isAccepted {
            await waitAfterFeeRefusal(&record, refusal: rejection)
            try save(record)
        }
        if let sweep = record.leftoverSweep, let oldTxid = sweep.txid, sweep.isConfirmed != true, sweep.rejection == nil,
           !Task.isCancelled, let address = record.funding.first?.address
        {
            let oldRate = sweep.feeRateSatPerVbyte ?? record.feeRateSatPerVbyte
            var isReplaceDue = false
            if sweep.isAccepted, let sentAt = sweep.sentAtHeight, let tip = try? await chain.tipHeight(),
               tip.saturatingSub(sentAt) >= Self.sweepReplaceBlocks
            {
                // A node that dropped it answers not found: that is unconfirmed too.
                isReplaceDue = await (try? chain.txStatus(txid: oldTxid))?.confirmed != true
            }
            if isReplaceDue {
                // A host with no fee estimates still gets a replacement one sat/vB over the old rate.
                let fastest = try? await chain.fastestFeeRate()
                let rate = max(fastest ?? 0, oldRate + 1)
                let utxos = SparkExitMath.economicalUtxos(record.leftover.map {
                    EsploraUtxo(txid: $0.txid, vout: $0.vout, value: $0.valueSats, status: EsploraTxStatus(confirmed: true, blockHeight: nil))
                }, rate: rate)
                Logger.info("Spark exit rebuilds its leftover sweep at \(rate) sat/vB", context: "SparkExitDriver")
                let built = try await SparkExitLeftoverSweep.build(
                    utxos: utxos,
                    fundingAddress: address,
                    destination: record.destination,
                    feeRateSatPerVbyte: rate,
                    signer: makeSigner(record.fundingIndex)
                )
                if let built {
                    record.leftoverSweep = SparkExitRecord.LeftoverSweep(
                        txid: built.txid,
                        txHex: built.txHex,
                        valueSats: built.valueSats,
                        feeRateSatPerVbyte: rate,
                        replacedTxids: sweep.isAccepted ? (sweep.replacedTxids ?? []) + [oldTxid] : sweep.replacedTxids
                    )
                    try save(record)
                } else if !sweep.isAccepted, let tip = try? await chain.tipHeight() {
                    // Too small to send at the new rate, and nothing of it is in the mempool: it waits for fees to drop.
                    record.leftoverSweep = SparkExitRecord.LeftoverSweep(
                        feeRateSatPerVbyte: rate,
                        replacedTxids: sweep.replacedTxids,
                        waitingSince: sweep.waitingSince ?? tip,
                        checkedAtHeight: tip
                    )
                    try save(record)
                }
            }
        }
        if record.leftoverSweep == nil || record.leftoverSweep?.isWaitingForFees == true {
            try await sweepWhenEconomical(&record)
        }
        guard let sweep = record.leftoverSweep, let txid = sweep.txid, let hex = sweep.txHex, sweep.rejection == nil,
              sweep.isConfirmed != true, !Task.isCancelled
        else { return }
        if sweep.isAccepted, let status = try? await chain.txStatus(txid: txid), status.confirmed {
            record.leftoverSweep?.isConfirmed = true
            await followRemainingOutputs(&record)
            return
        }
        // Built but never accepted for `sweepRecheckBlocks`: its coins may have changed, so it is built again from what
        // the address holds now.
        if !sweep.isAccepted, let builtAt = sweep.builtAtHeight, let tip = try? await chain.tipHeight(),
           tip.saturatingSub(builtAt) >= Self.sweepRecheckBlocks
        {
            Logger.warn("Spark exit leftover sweep \(txid) never accepted, building it again", context: "SparkExitDriver")
            record.leftoverSweep = SparkExitRecord.LeftoverSweep(
                feeRateSatPerVbyte: sweep.feeRateSatPerVbyte,
                replacedTxids: sweep.replacedTxids,
                waitingSince: sweep.waitingSince ?? tip,
                checkedAtHeight: tip,
                refusedFeeRate: sweep.refusedFeeRate,
                retryAtHeight: tip + 1
            )
            return
        }
        let outcome = await chain.broadcast(RecoveryTransaction(
            kind: .sweep,
            nodeId: nil,
            txid: txid,
            txHex: hex,
            cpfpTxHex: nil,
            csvTimelockBlocks: nil,
            dependsOn: [],
            status: .ready
        ))
        Logger.info("Spark exit leftover sweep \(txid): \(outcome.summary)", context: "SparkExitDriver")
        switch outcome {
        case .accepted:
            record.leftoverSweep?.isAccepted = true
            if record.leftoverSweep?.sentAtHeight == nil {
                record.leftoverSweep?.sentAtHeight = try? await chain.tipHeight()
            }
        case let .rejected(reason) where !sweep.isAccepted:
            if SparkExitRecord.LeftoverSweep(rejection: reason).isFeeRejection {
                await waitAfterFeeRefusal(&record, refusal: reason)
            } else if await isAnyKnown(sweep.replacedTxids ?? []) {
                // A replacement refused for another reason while the sweep it replaces may still confirm: that one is
                // followed (the replaced txids end the sweep once in a block), and a new build is tried later.
                if let tip = try? await chain.tipHeight() {
                    record.leftoverSweep = SparkExitRecord.LeftoverSweep(
                        feeRateSatPerVbyte: sweep.feeRateSatPerVbyte,
                        replacedTxids: sweep.replacedTxids,
                        waitingSince: sweep.waitingSince ?? tip,
                        checkedAtHeight: tip
                    )
                }
            } else {
                record.leftoverSweep?.rejection = reason
            }
        // Once accepted, a later refusal is mostly a node that already has it or a conflict with it confirming. A fee
        // refusal of one no host holds any more means it was evicted when the mempool's floor rose: it waits and is
        // built again over the same coins at the rate the node asks for, replacing it (RBF).
        case let .rejected(reason) where SparkExitRecord.LeftoverSweep(rejection: reason).isFeeRejection:
            let isKnown = try? await chain.isKnown(txid: txid)
            if isKnown == false {
                Logger.warn("Spark exit leftover sweep \(txid) left the mempool unconfirmed", context: "SparkExitDriver")
                await waitAfterFeeRefusal(&record, refusal: reason)
            }
        case .inputsMissing where !sweep.isAccepted:
            // The coins it spends are gone or changed: built again from what the address holds, from the next block.
            if let tip = try? await chain.tipHeight() {
                record.leftoverSweep = SparkExitRecord.LeftoverSweep(
                    feeRateSatPerVbyte: sweep.feeRateSatPerVbyte,
                    replacedTxids: sweep.replacedTxids,
                    waitingSince: sweep.waitingSince ?? tip,
                    checkedAtHeight: tip,
                    refusedFeeRate: sweep.refusedFeeRate,
                    retryAtHeight: tip + 1
                )
            }
        default: break
        }
    }

    /// After a sweep confirms, reads the funding address again: outputs the sweep left out (too small for their fee,
    /// or unconfirmed when it was built) start a new wait of their own, so they are swept once worth it or kept with
    /// their path after `sweepWaitBlocks`. What the confirmed sweeps sent is kept for the result.
    private func followRemainingOutputs(_ record: inout SparkExitRecord) async {
        guard let sweep = record.leftoverSweep, let txid = sweep.txid, let address = record.funding.first?.address,
              let tip = try? await chain.tipHeight(), let listed = try? await chain.utxos(address: address)
        else { return }
        // A host behind the block can still list what the sweep spent.
        let spent = Set((sweep.txHex.flatMap(SparkExitTxid.inputOutpoints(hex:)) ?? []).map { "\($0.txid):\($0.vout)" })
        let utxos = listed.filter { !spent.contains("\($0.txid):\($0.vout)") }
        guard !utxos.isEmpty else { return }
        Logger.info("Spark exit sweep \(txid) left \(utxos.count) outputs at the funding address; following them", context: "SparkExitDriver")
        record.sweptLeftover = (record.sweptLeftover ?? []) + [.init(txid: txid, valueSats: sweep.valueSats)]
        record.leftover = utxos.map { SparkExitRecord.Leftover(txid: $0.txid, vout: $0.vout, valueSats: $0.value) }
        record.leftoverSweep = SparkExitRecord.LeftoverSweep(waitingSince: tip, checkedAtHeight: tip)
    }

    private func isAnyKnown(_ txids: [String]) async -> Bool {
        for txid in txids {
            let isKnown = try? await chain.isKnown(txid: txid)
            if isKnown == true {
                return true
            }
        }
        return false
    }

    /// A sweep refused for its fee is not final: the leftover waits again, keeping when its wait began, and is built
    /// again from the next block at the rate the refusal asks for (`refusedSweepRate`, capped by `refusedSweepFloor`), or
    /// the economy rate if higher.
    private func waitAfterFeeRefusal(_ record: inout SparkExitRecord, refusal: String) async {
        // Without a tip no height is written: the refusal is kept, and the next tick turns it into the wait.
        guard let sweep = record.leftoverSweep, let tip = try? await chain.tipHeight() else {
            if record.leftoverSweep?.isAccepted == false {
                record.leftoverSweep?.rejection = refusal
            }
            return
        }
        let rate = SparkExitMath.refusedSweepRate(refusal, paidRate: sweep.feeRateSatPerVbyte ?? record.feeRateSatPerVbyte)
        // One a node accepted may still confirm: any of the replaced sweeps confirming ends the sweep.
        let replaced = sweep.isAccepted ? (sweep.replacedTxids ?? []) + [sweep.txid].compactMap { $0 } : sweep.replacedTxids
        Logger.info("Spark exit leftover sweep refused for its fee (\(refusal)), tries again at \(rate) sat/vB", context: "SparkExitDriver")
        record.leftoverSweep = SparkExitRecord.LeftoverSweep(
            feeRateSatPerVbyte: sweep.feeRateSatPerVbyte,
            replacedTxids: replaced,
            waitingSince: sweep.waitingSince ?? tip,
            checkedAtHeight: tip,
            refusedFeeRate: rate,
            retryAtHeight: tip + 1
        )
    }

    /// Builds the leftover sweep at the network's economy rate (`sweepFeeRate`) from the UTXOs worth more than their
    /// own input fee. While nothing is worth sending it waits, checking the rate again every `sweepRecheckBlocks`,
    /// and after `sweepWaitBlocks` keeps the change at the funding address, shown with the path that spends it.
    private func sweepWhenEconomical(_ record: inout SparkExitRecord) async throws {
        guard let address = record.funding.first?.address else { return }
        let waiting = record.leftoverSweep
        // Every state below records a height: without the tip nothing changes this tick.
        guard let tip = try? await chain.tipHeight() else { return }
        if let waiting, let since = waiting.waitingSince {
            if tip.saturatingSub(since) >= Self.sweepWaitBlocks {
                Logger.info("Spark exit keeps its fee change at the funding address after waiting for fees", context: "SparkExitDriver")
                record.leftoverSweep?.isDustKept = true
                try save(record)
                return
            }
            let due = waiting.retryAtHeight ?? (waiting.checkedAtHeight ?? since).addingReportingOverflow(Self.sweepRecheckBlocks).partialValue
            guard tip >= due else { return }
        }
        let utxos = try await chain.utxos(address: address)
        record.leftover = utxos.map { SparkExitRecord.Leftover(txid: $0.txid, vout: $0.vout, valueSats: $0.value) }
        let confirmed = utxos.filter(\.status.confirmed)
        guard !confirmed.isEmpty else { return }
        // An unconfirmed output (a stuck payment, say) holds the sweep back for one recheck at most; then the confirmed
        // ones go and the rest waits for the next sweep.
        if confirmed.count < utxos.count {
            let since = waiting?.waitingSince ?? tip
            if tip.saturatingSub(since) < Self.sweepRecheckBlocks {
                record.leftoverSweep = SparkExitRecord.LeftoverSweep(
                    replacedTxids: waiting?.replacedTxids,
                    waitingSince: since,
                    checkedAtHeight: tip,
                    refusedFeeRate: waiting?.refusedFeeRate,
                    retryAtHeight: tip + 1
                )
                try save(record)
                return
            }
        }
        let fees = try? await chain.networkFees()
        // A rate a node refused stays refused: the least it asked for lifts the economy rate, up to the next block's or
        // the exit's rate. A node asking more refuses again, and the sweep waits a block for fees to drop.
        let refusedFloor = SparkExitMath.refusedSweepFloor(
            waiting?.refusedFeeRate ?? 0,
            nextBlock: fees?.fastest,
            exitRate: record.feeRateSatPerVbyte
        )
        let rate = max(SparkExitMath.sweepFeeRate(economy: fees?.economy, exitRate: record.feeRateSatPerVbyte), refusedFloor)
        let built = try await SparkExitLeftoverSweep.build(
            utxos: SparkExitMath.economicalUtxos(confirmed, rate: rate),
            fundingAddress: address,
            destination: record.destination,
            feeRateSatPerVbyte: rate,
            signer: makeSigner(record.fundingIndex)
        )
        if let built {
            // The wait's start carries over, so a sweep refused again still ends at `sweepWaitBlocks`.
            record.leftoverSweep = SparkExitRecord.LeftoverSweep(
                txid: built.txid,
                txHex: built.txHex,
                valueSats: built.valueSats,
                feeRateSatPerVbyte: rate,
                replacedTxids: waiting?.replacedTxids,
                waitingSince: waiting?.waitingSince,
                builtAtHeight: tip
            )
        } else {
            let since = waiting?.waitingSince ?? tip
            Logger.info("Spark exit waits for lower fees to send its fee change (\(rate) sat/vB)", context: "SparkExitDriver")
            record.leftoverSweep = SparkExitRecord.LeftoverSweep(
                feeRateSatPerVbyte: rate,
                replacedTxids: waiting?.replacedTxids,
                waitingSince: since,
                checkedAtHeight: tip,
                refusedFeeRate: waiting?.refusedFeeRate
            )
        }
        try save(record)
    }

    // MARK: Broadcast

    /// A unilateral step the SDK could not read is never sent: a rebuild settles it. A cooperative one is, since nodes
    /// refuse it if its funds already moved.
    private func broadcastReady(_ record: inout SparkExitRecord, tip: UInt32? = nil) async throws {
        guard let recovery = record.recovery?.response else { return }
        let confirmed = Set(recovery.transactions.filter(\.isConfirmed).map(\.txid))
        var tip = tip
        for tx in recovery.transactions where tx.status == .ready || (tx.status == .unverified && tx.kind == .cooperative) {
            guard !Task.isCancelled else { return }
            guard isDue(tx.txid, in: record) else { continue }
            if tip == nil {
                tip = try? await chain.tipHeight()
            }
            let hasConfirmedParents = tx.status == .ready && tx.dependsOn.allSatisfy(confirmed.contains)
            await broadcast(tx, into: &record, hasConfirmedParents: hasConfirmedParents, tip: tip)
            try save(record)
        }
    }

    /// Without the SDK: each unconfirmed transaction whose parents are confirmed on the chain host and whose relative
    /// timelocks matured, counted from the confirmation height of the parent each input spends. A step whose input
    /// someone else spent, the operators' version of it, is not sent again; the next SDK check rebuilds. A stale one
    /// is refused by nodes as a conflict, and only the current generation is stored.
    private func broadcastWithoutSdk(_ record: inout SparkExitRecord) async throws {
        guard var recovery = record.recovery?.response else { return }
        let tip = try await chain.tipHeight()
        let listed = Set(recovery.transactions.map(\.txid))
        var confirmed = Set(recovery.transactions.filter(\.isConfirmed).map(\.txid))
        var heights: [String: UInt32] = [:]
        for tx in recovery.transactions {
            if case let .confirmed(height?) = tx.status {
                heights[tx.txid] = height
            }
        }
        let unknown = recovery.transactions.filter { !$0.isConfirmed }.map(\.txid)
            + Set(recovery.transactions.flatMap(\.dependsOn)).subtracting(listed).subtracting(confirmed)
        let statuses = await statuses(unknown)
        for (txid, status) in statuses where status.confirmed {
            confirmed.insert(txid)
            heights[txid] = status.blockHeight
        }
        for (i, tx) in recovery.transactions.enumerated() {
            guard !Task.isCancelled else { break }
            if tx.isConfirmed {
                continue
            }
            if let status = statuses[tx.txid], status.confirmed {
                recovery.transactions[i].status = .confirmed(blockHeight: status.blockHeight)
                continue
            }
            guard tx.dependsOn.allSatisfy(confirmed.contains), isDue(tx.txid, in: record, withoutSdk: true) else { continue }
            if case let .waitingForTimelock(height?) = tx.status, !SparkExitTimelock.isMature(height, tip: tip) {
                continue
            }
            let locks = SparkExitTimelock.locks(of: tx)
            for parent in Set(locks.map(\.parent)).subtracting(heights.keys) {
                if let status = try? await chain.txStatus(txid: parent), status.confirmed, let height = status.blockHeight {
                    heights[parent] = height
                }
            }
            switch SparkExitTimelock.maturity(of: tx, locks: locks, heights: heights) {
            case .unknown:
                continue
            case let .at(height) where !SparkExitTimelock.isMature(height, tip: tip):
                recovery.transactions[i].status = .waitingForTimelock(spendableAtHeight: height)
                continue
            case .none, .at:
                break
            }
            await broadcast(tx, into: &record, hasConfirmedParents: true, tip: tip)
            record.recovery = StoredRecovery(recovery)
            try save(record)
        }
        record.recovery = StoredRecovery(recovery)
    }

    /// Without the SDK, a step whose input someone else spent is never due: only a rebuild moves on from it.
    private func isDue(_ txid: String, in record: SparkExitRecord, withoutSdk: Bool = false) -> Bool {
        guard let last = record.broadcastLog.first(where: { $0.generation == record.generation && $0.txid == txid }) else { return true }
        if withoutSdk, last.isInputSpent == true {
            return false
        }
        return !last.isAccepted || now().timeIntervalSince(last.lastAttemptAt) >= Self.rebroadcastInterval
    }

    /// With every parent of the step confirmed, missing inputs mean another transaction spent one. A failed fee
    /// chain is no rejection: it counts on its own towards a rebuild.
    private func broadcast(_ tx: RecoveryTransaction, into record: inout SparkExitRecord, hasConfirmedParents: Bool, tip: UInt32?) async {
        let outcome = await chain.broadcast(tx)
        Logger.info("Spark exit broadcast \(tx.kind) \(tx.txid): \(outcome.summary)", context: "SparkExitDriver")
        let isAccepted = outcome == .accepted
        let isInputsMissing = if case .inputsMissing = outcome {
            true
        } else {
            false
        }
        let isInputSpent: Bool? = hasConfirmedParents && isInputsMissing ? true : nil
        let isUnpaid = SparkExitBroadcastClassifier.isUnpaid(outcome)
        let isFeeChainFailure = hasConfirmedParents && (isUnpaid || isInputsMissing)
        // Neither an unpaid child nor a rate under the mempool's is a refusal to rebuild over: the first is a broken fee
        // chain, the second needs lower fees, not a build at the same rate.
        let isFeeRateRefused = SparkExitBroadcastClassifier.isFeeRateTooLow(outcome)
        let isRejected = if case .rejected = outcome {
            !isUnpaid && !isFeeRateRefused
        } else {
            false
        }
        if let i = record.broadcastLog.firstIndex(where: { $0.generation == record.generation && $0.txid == tx.txid }) {
            record.broadcastLog[i].acceptedAtHeight = isAccepted ? record.broadcastLog[i].acceptedAtHeight ?? tip : nil
            record.broadcastLog[i].attempts += 1
            record.broadcastLog[i].rejections += isRejected ? 1 : 0
            record.broadcastLog[i].lastAttemptAt = now()
            record.broadcastLog[i].lastOutcome = outcome.summary
            record.broadcastLog[i].isAccepted = isAccepted
            record.broadcastLog[i].isInputSpent = isInputSpent
            record.broadcastLog[i].feeChainFailures = isFeeChainFailure ? (record.broadcastLog[i].feeChainFailures ?? 0) + 1 : nil
            record.broadcastLog[i].isFeeRateRefused = isFeeRateRefused ? true : nil
        } else {
            record.broadcastLog.append(.init(
                generation: record.generation,
                txid: tx.txid,
                attempts: 1,
                rejections: isRejected ? 1 : 0,
                lastAttemptAt: now(),
                lastOutcome: outcome.summary,
                isAccepted: isAccepted,
                isInputSpent: isInputSpent,
                feeChainFailures: isFeeChainFailure ? 1 : nil,
                acceptedAtHeight: isAccepted ? tip : nil,
                isFeeRateRefused: isFeeRateRefused ? true : nil
            ))
        }
    }
}

private extension RecoveryTransaction {
    var isConfirmed: Bool {
        if case .confirmed = status {
            return true
        }
        return false
    }
}

extension SparkExitRecord {
    /// What keeps the exit from moving, once rebuilding over its stuck steps stopped helping.
    var surfacedRejection: String? {
        isStalled ? stuckStep?.lastOutcome : nil
    }

    /// A prepare of `selection` at the exit's fee rate, or at `feeRate`, funded the way the exit was started.
    func prepareRequest(_ selection: ExitLeafSelection, feeRate: UInt64? = nil) -> PrepareRecoverFundsRequest {
        PrepareRecoverFundsRequest(
            feeRateSatPerVbyte: feeRate ?? feeRateSatPerVbyte,
            fundingKind: .p2wpkh,
            fundingStrategy: cpfpFundingStrategy,
            destination: destination,
            selection: selection
        )
    }
}

/// When a step's relative timelocks mature, as the SDK's `spendable_at_height` computes it: each input's BIP68 block
/// lock counts from the confirmation height of the transaction that input spends.
enum SparkExitTimelock {
    struct Lock: Equatable {
        let parent: String
        let blocks: UInt32
    }

    enum Maturity: Equatable {
        /// No relative timelock.
        case none
        /// Spendable from this height.
        case at(UInt32)
        /// A parent's confirmation height is not known yet.
        case unknown
    }

    /// The block locks of the step's inputs, from its hex; from `csvTimelockBlocks` over its parents when the hex
    /// does not decode. Empty when it has no timelock.
    static func locks(of tx: RecoveryTransaction) -> [Lock] {
        guard let csv = tx.csvTimelockBlocks else { return [] }
        return SparkExitTxid.relativeBlockLocks(hex: tx.txHex) ?? tx.dependsOn.map { Lock(parent: $0, blocks: csv) }
    }

    static func maturity(of tx: RecoveryTransaction, locks: [Lock], heights: [String: UInt32]) -> Maturity {
        guard tx.csvTimelockBlocks != nil else { return .none }
        // The SDK leaves a step with a timelock but no lock it can count as unknown, and so does this.
        guard !locks.isEmpty else { return .unknown }
        var spendable: UInt32 = 0
        for lock in locks {
            guard let height = heights[lock.parent] else { return .unknown }
            spendable = max(spendable, height.addingReportingOverflow(lock.blocks).partialValue)
        }
        return .at(spendable)
    }

    /// A transaction is accepted while it would be valid in the next block.
    static func isMature(_ spendableAtHeight: UInt32, tip: UInt32) -> Bool {
        UInt64(tip) + 1 >= UInt64(spendableAtHeight)
    }
}

/// Transaction ids from raw hex, for the CPFP children the SDK returns without one.
enum SparkExitTxid {
    static func cpfpChildTxids(_ recovery: RecoverFundsResponse) -> [String] {
        recovery.transactions.compactMap { $0.cpfpTxHex.flatMap(txid(hex:)) }
    }

    /// The exit's own transactions that pay the funding script: the CPFP children's change and the fan-out's split.
    static func chainedTxids(_ recovery: RecoverFundsResponse) -> [String] {
        cpfpChildTxids(recovery) + recovery.transactions.filter { $0.kind == .fanOut }.map(\.txid)
    }

    /// The outpoints a serialized transaction spends; nil when the hex does not decode.
    static func inputOutpoints(hex: String) -> [(txid: String, vout: UInt32)]? {
        let bytes = hex.hexaBytes
        guard hex.count == bytes.count * 2 else { return nil }
        var reader = Reader(bytes: bytes)
        return reader.inputs()?.inputs.map { ($0.txid, $0.vout) }
    }

    /// The txids a serialized transaction spends; nil when the hex does not decode.
    static func inputTxids(hex: String) -> [String]? {
        let bytes = hex.hexaBytes
        guard hex.count == bytes.count * 2 else { return nil }
        var reader = Reader(bytes: bytes)
        return reader.inputs()?.inputs.map(\.txid)
    }

    /// Each input's BIP68 block lock with the txid it spends; nil when the hex does not decode. Version 1
    /// transactions and inputs whose sequence disables the lock or counts time carry none.
    static func relativeBlockLocks(hex: String) -> [SparkExitTimelock.Lock]? {
        let bytes = hex.hexaBytes
        guard hex.count == bytes.count * 2 else { return nil }
        var reader = Reader(bytes: bytes)
        guard let parsed = reader.inputs() else { return nil }
        guard parsed.version >= 2 else { return [] }
        return parsed.inputs.compactMap { input in
            let sequence = input.sequence
            let isDisabled = sequence & (1 << 31) != 0
            let isTime = sequence & (1 << 22) != 0
            let blocks = sequence & 0xFFFF
            guard !isDisabled, !isTime, blocks > 0 else { return nil }
            return SparkExitTimelock.Lock(parent: input.txid, blocks: blocks)
        }
    }

    /// Each output's value and script; nil when the hex does not decode.
    static func outputs(hex: String) -> [(value: UInt64, script: Data)]? {
        let bytes = hex.hexaBytes
        guard hex.count == bytes.count * 2 else { return nil }
        var reader = Reader(bytes: bytes)
        return reader.outputs()
    }

    /// The txid of a serialized transaction: double SHA-256 of it without witness data, byte-reversed.
    static func txid(hex: String) -> String? {
        let bytes = hex.hexaBytes
        guard hex.count == bytes.count * 2 else { return nil }
        var reader = Reader(bytes: bytes)
        guard let stripped = reader.strippedOfWitness() else { return nil }
        let hash = Data(SHA256.hash(data: Data(SHA256.hash(data: stripped))))
        return Data(hash.reversed()).hex
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= bytes.count - position else { return nil }
            defer { position += count }
            return Array(bytes[position ..< position + count])
        }

        mutating func varInt() -> (value: Int, raw: [UInt8])? {
            guard let first = take(1)?.first else { return nil }
            let width = switch first {
            case 0xFD: 2
            case 0xFE: 4
            case 0xFF: 8
            default: 0
            }
            guard width > 0 else { return (Int(first), [first]) }
            guard let rest = take(width) else { return nil }
            let value = rest.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
            // A count no transaction can hold reads as malformed rather than trapping.
            guard value <= UInt64(bytes.count) else { return nil }
            return (Int(value), [first] + rest)
        }

        mutating func inputs() -> (version: Int32, inputs: [(txid: String, vout: UInt32, sequence: UInt32)])? {
            guard let versionBytes = take(4) else { return nil }
            let version = Int32(bitPattern: littleEndian(versionBytes))
            if bytes.count > 5, bytes[4] == 0, bytes[5] == 1 {
                position += 2
            }
            guard let count = varInt() else { return nil }
            var inputs: [(txid: String, vout: UInt32, sequence: UInt32)] = []
            for _ in 0 ..< count.value {
                guard let txid = take(32), let vout = take(4), let script = varInt(), take(script.value) != nil, let sequence = take(4) else {
                    return nil
                }
                inputs.append((Data(txid.reversed()).hex, littleEndian(vout), littleEndian(sequence)))
            }
            return (version, inputs)
        }

        mutating func outputs() -> [(value: UInt64, script: Data)]? {
            guard inputs() != nil, let count = varInt() else { return nil }
            var outputs: [(value: UInt64, script: Data)] = []
            for _ in 0 ..< count.value {
                guard let value = take(8), let script = varInt(), let scriptBytes = take(script.value) else { return nil }
                outputs.append((value.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }, Data(scriptBytes)))
            }
            return outputs
        }

        private func littleEndian(_ bytes: [UInt8]) -> UInt32 {
            bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }

        mutating func strippedOfWitness() -> Data? {
            guard let version = take(4) else { return nil }
            var out = version
            let isSegwit = bytes.count > 5 && bytes[4] == 0 && bytes[5] == 1
            if isSegwit {
                position += 2
            }
            guard let inputs = varInt() else { return nil }
            out += inputs.raw
            for _ in 0 ..< inputs.value {
                guard let outpoint = take(36), let script = varInt(), let scriptBytes = take(script.value), let sequence = take(4) else { return nil }
                out += outpoint + script.raw + scriptBytes + sequence
            }
            guard let outputs = varInt() else { return nil }
            out += outputs.raw
            for _ in 0 ..< outputs.value {
                guard let value = take(8), let script = varInt(), let scriptBytes = take(script.value) else { return nil }
                out += value + script.raw + scriptBytes
            }
            if isSegwit {
                for _ in 0 ..< inputs.value {
                    guard let items = varInt() else { return nil }
                    for _ in 0 ..< items.value {
                        guard let item = varInt(), take(item.value) != nil else { return nil }
                    }
                }
            }
            guard let lockTime = take(4) else { return nil }
            return Data(out + lockTime)
        }
    }
}
