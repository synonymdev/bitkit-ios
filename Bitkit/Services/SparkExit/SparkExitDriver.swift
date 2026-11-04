import BreezSdkSpark
import CryptoKit
import Foundation

/// The SDK calls an exit makes. `BreezSdk` in the app, a fake in tests.
protocol SparkExitRecovering: Sendable {
    func prepare(_ request: PrepareRecoverFundsRequest) async throws -> PrepareRecoverFundsResponse
    func recover(_ request: RecoverFundsRequest, signer: CpfpSigner?) async throws -> RecoverFundsResponse
    func check(_ recovery: RecoverFundsResponse) async throws -> CheckRecoverFundsResponse
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
    let makeSigner: () throws -> CpfpSigner
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

    @discardableResult
    func tick(_ record: SparkExitRecord) async throws -> SparkExitRecord {
        var record = record
        switch record.phase {
        case .done, .failed:
            return record
        case .awaitingFunding, .needsFunding:
            guard let recovering, !Task.isCancelled else { return record }
            // Nothing to fund when every leaf is recovered cooperatively.
            if let shortfall = record.fundingShortfallSats {
                guard try await adoptFunding(&record, requiredSats: shortfall) else { return record }
            }
            try await build(&record, recovering: recovering)
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
            }
        }
        record.claimableAtHeight = record.recovery.flatMap { SparkExitMath.claimableAtHeight($0.response) }
        try save(record)
        return record
    }

    // MARK: Funding

    /// Adds a confirmed UTXO of at least `requiredSats` at the funding address that is neither a funding input yet
    /// nor CPFP change the exit chained there.
    private func adoptFunding(_ record: inout SparkExitRecord, requiredSats: UInt64) async throws -> Bool {
        guard let address = record.funding.first?.address, let pubkey = record.funding.first?.pubkey else { return false }
        let known = Set(record.funding.compactMap { funding in funding.txid.map { "\($0):\(funding.vout ?? 0)" } })
        let chained = Set(record.recovery.map { SparkExitTxid.cpfpChildTxids($0.response) } ?? [])
        let candidates = try await chain.utxos(address: address).filter { !known.contains("\($0.txid):\($0.vout)") && !chained.contains($0.txid) }
        guard let utxo = SparkExitMath.fundingUtxo(candidates, requiredSats: requiredSats) else { return false }
        let funding = SparkExitRecord.Funding(index: 0, address: address, pubkey: pubkey, txid: utxo.txid, vout: utxo.vout, valueSats: utxo.value)
        if record.funding.count == 1, record.funding[0].txid == nil {
            record.funding[0] = funding
        } else {
            record.funding.append(funding)
        }
        return true
    }

    // MARK: Build

    private func build(_ record: inout SparkExitRecord, recovering: SparkExitRecovering) async throws {
        let prepared = try await recovering.prepare(PrepareRecoverFundsRequest(
            feeRateSatPerVbyte: record.feeRateSatPerVbyte,
            fundingKind: .p2wpkh,
            destination: record.destination,
            selection: .specific(leafIds: record.leafIds)
        ))
        guard !prepared.leaves.isEmpty else {
            // A leaf the chain could not be read for comes back on a later tick; finished leaves are not listed.
            if prepared.skipped.contains(where: { $0.reason == .unverified }) {
                return
            }
            record.skippedLeafCount = max(record.skippedLeafCount, prepared.skipped.count)
            record.phase = record.recovery == nil ? .failed(reason: "Nothing left to recover") : .done
            return
        }
        let built: RecoverFundsResponse
        do {
            built = try await recovering.recover(
                RecoverFundsRequest(prepared: prepared, fundingInputs: prepared.funding == nil ? [] : record.fundingInputs),
                signer: prepared.funding == nil ? nil : makeSigner()
            )
        } catch let SdkError.InsufficientCpfpFunds(requiredSats, _) {
            // The SDK names what the inputs must cover, and the earlier inputs are partly spent by now, so a new
            // UTXO of the whole amount is asked for. What the exit does not spend comes back with the sweep.
            record.phase = .needsFunding(requiredSats: record.fundedSats + requiredSats)
            return
        }
        guard !built.transactions.isEmpty else {
            // Cooperative leaves the operators could not co-sign now are tried again on the next tick.
            if !built.failed.isEmpty {
                record.failedLeafCount = built.failed.count
                return
            }
            record.phase = .failed(reason: "Nothing to recover")
            return
        }
        record.adopt(built, at: now())
        // Saved before any of it is broadcast, so a crash never leaves broadcast transactions without their record.
        try save(record)
        try await broadcastReady(&record)
    }

    // MARK: Check

    private func check(_ record: inout SparkExitRecord, recovering: SparkExitRecovering) async throws {
        guard let stored = record.recovery?.response else {
            record.phase = .awaitingFunding(requiredSats: 0)
            return
        }
        let checked = try await recovering.check(withConfirmations(stored))
        record.recovery = StoredRecovery(checked.recovery)
        switch checked.verdict {
        case .valid:
            try await broadcastReady(&record)
        case .done:
            record.phase = .done
            record.leftover = await leftover(record)
        case .redo:
            Logger.warn("Spark exit diverged on-chain, rebuilding generation \(record.generation + 1)", context: "SparkExitDriver")
            record.isRebuilding = true
            try save(record)
            guard !Task.isCancelled, isRebuildDue(record) else { return }
            try await build(&record, recovering: recovering)
        }
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

    private func leftover(_ record: SparkExitRecord) async -> [SparkExitRecord.Leftover] {
        guard let address = record.funding.first?.address, let utxos = try? await chain.utxos(address: address) else { return [] }
        return utxos.map { SparkExitRecord.Leftover(txid: $0.txid, vout: $0.vout, valueSats: $0.value) }
    }

    // MARK: Broadcast

    private func broadcastReady(_ record: inout SparkExitRecord) async throws {
        guard let recovery = record.recovery?.response else { return }
        // Unverified: the SDK could not read its parent from the chain; nodes refuse it harmlessly if it is not final.
        for tx in recovery.transactions where tx.status == .ready || tx.status == .unverified {
            guard !Task.isCancelled else { return }
            guard isDue(tx.txid, in: record) else { continue }
            await broadcast(tx, into: &record)
            try save(record)
        }
    }

    /// Without the SDK: each unconfirmed transaction whose parents are confirmed on the chain host and whose timelock
    /// has matured. A stale one is refused by nodes as a conflict, and only the current generation is stored.
    private func broadcastWithoutSdk(_ record: inout SparkExitRecord) async throws {
        guard var recovery = record.recovery?.response else { return }
        let tip = try await chain.tipHeight()
        let listed = Set(recovery.transactions.map(\.txid))
        var confirmed = Set(recovery.transactions.filter(\.isConfirmed).map(\.txid))
        let unknown = recovery.transactions.filter { !$0.isConfirmed }.map(\.txid)
            + Set(recovery.transactions.flatMap(\.dependsOn)).subtracting(listed).subtracting(confirmed)
        let statuses = await statuses(unknown)
        confirmed.formUnion(statuses.filter(\.value.confirmed).keys)
        for (i, tx) in recovery.transactions.enumerated() {
            guard !Task.isCancelled else { break }
            if tx.isConfirmed {
                continue
            }
            if let status = statuses[tx.txid], status.confirmed {
                recovery.transactions[i].status = .confirmed(blockHeight: status.blockHeight)
                continue
            }
            if case let .waitingForTimelock(height?) = tx.status, height > tip {
                continue
            }
            guard tx.dependsOn.allSatisfy(confirmed.contains), isDue(tx.txid, in: record) else { continue }
            await broadcast(tx, into: &record)
            record.recovery = StoredRecovery(recovery)
            try save(record)
        }
        record.recovery = StoredRecovery(recovery)
    }

    private func isDue(_ txid: String, in record: SparkExitRecord) -> Bool {
        guard let last = record.broadcastLog.first(where: { $0.generation == record.generation && $0.txid == txid }) else { return true }
        return !last.isAccepted || now().timeIntervalSince(last.lastAttemptAt) >= Self.rebroadcastInterval
    }

    private func broadcast(_ tx: RecoveryTransaction, into record: inout SparkExitRecord) async {
        let outcome = await chain.broadcast(tx)
        Logger.info("Spark exit broadcast \(tx.kind) \(tx.txid): \(outcome.summary)", context: "SparkExitDriver")
        let isAccepted = outcome == .accepted
        let isRejected = if case .rejected = outcome {
            true
        } else {
            false
        }
        if let i = record.broadcastLog.firstIndex(where: { $0.generation == record.generation && $0.txid == tx.txid }) {
            record.broadcastLog[i].attempts += 1
            record.broadcastLog[i].rejections += isRejected ? 1 : 0
            record.broadcastLog[i].lastAttemptAt = now()
            record.broadcastLog[i].lastOutcome = outcome.summary
            record.broadcastLog[i].isAccepted = isAccepted
        } else {
            record.broadcastLog.append(.init(
                generation: record.generation,
                txid: tx.txid,
                attempts: 1,
                rejections: isRejected ? 1 : 0,
                lastAttemptAt: now(),
                lastOutcome: outcome.summary,
                isAccepted: isAccepted
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
    /// The rejection to show on the progress screen once a transaction was refused several times.
    var surfacedRejection: String? {
        broadcastLog.first { $0.generation == generation && $0.rejections >= SparkExitDriver.rejectionsToSurface && !$0.isAccepted }?.lastOutcome
    }
}

/// Transaction ids from raw hex, for the CPFP children the SDK returns without one.
enum SparkExitTxid {
    static func cpfpChildTxids(_ recovery: RecoverFundsResponse) -> [String] {
        recovery.transactions.compactMap { $0.cpfpTxHex.flatMap(txid(hex:)) }
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
            guard count >= 0, position + count <= bytes.count else { return nil }
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
            let value = rest.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            return (value, [first] + rest)
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
