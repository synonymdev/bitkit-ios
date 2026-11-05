import BreezSdkSpark
import Foundation

/// Everything a Spark emergency exit needs to continue after a restart. The SDK keeps none of it: the signed
/// recovery, the request it came from, how its fees were funded and what this device already broadcast.
struct SparkExitRecord: Codable, Equatable {
    static let currentVersion = 1

    enum Phase: Codable, Equatable {
        /// Waiting for confirmed fee funding of `requiredSats` in all at the funding address before the first build.
        case awaitingFunding(requiredSats: UInt64)
        /// Built and being driven to the chain.
        case running
        /// A rebuild needs fee funding of `requiredSats` in all, more than the funding address received so far.
        case needsFunding(requiredSats: UInt64)
        case done
        case failed(reason: String)

        var requiredFundingSats: UInt64? {
            switch self {
            case let .awaitingFunding(requiredSats), let .needsFunding(requiredSats): requiredSats
            default: nil
            }
        }
    }

    struct Funding: Codable, Equatable {
        /// The last path component under `SparkExitFundingKey.basePath`.
        let index: UInt32
        let address: String
        let pubkey: String
        var txid: String?
        var vout: UInt32?
        var valueSats: UInt64?

        var input: CpfpInput? {
            guard let txid, let vout, let valueSats else { return nil }
            return .p2wpkh(txid: txid, vout: vout, valueSats: valueSats, pubkey: pubkey)
        }
    }

    struct BroadcastAttempt: Codable, Equatable {
        let generation: Int
        let txid: String
        var attempts: Int
        var rejections: Int
        var lastAttemptAt: Date
        var lastOutcome: String
        var isAccepted: Bool
        /// Its input was spent by another transaction, the operators' version of the step: the keyless pass stops
        /// sending it and the next SDK check rebuilds.
        var isInputSpent: Bool?
        /// Attempts in a row, with the step's parents confirmed, that its fee chain failed: its CPFP child did not
        /// pay for it (`min relay fee not met, 0 < N`) or its inputs were missing. Reset by any other outcome.
        var feeChainFailures: Int?
        /// The tip when a node first accepted it, kept while it stays accepted, so a step the network holds but does
        /// not confirm shows as underpriced.
        var acceptedAtHeight: UInt32?
        /// Its last answer was a fee under the mempool's minimum: the network is busier than the exit's rate.
        var isFeeRateRefused: Bool?
    }

    /// A leaf an older state of the wallet claimed on-chain first, which this exit cannot recover.
    struct LostLeaf: Codable, Equatable {
        let leafId: String
        let valueSats: UInt64
    }

    /// A leaf the SDK cannot exit at the exit's fee rate, such as a fee-ladder leaf whose refund cannot pay its fee.
    struct LeftBehindLeaf: Codable, Equatable {
        let leafId: String
        let valueSats: UInt64
        let reason: String
    }

    /// A cooperative leaf the operators' watchtower moved on-chain that they could not co-sign a recovery for.
    struct FailedLeaf: Codable, Equatable {
        let leafId: String
        var valueSats: UInt64
    }

    struct Leftover: Codable, Equatable {
        let txid: String
        let vout: UInt32
        let valueSats: UInt64
    }

    /// The transaction that sends the leftover fee funding to savings once the exit ended.
    struct LeftoverSweep: Codable, Equatable {
        /// nil when what is left is under the dust limit after the sweep's fee, so nothing is swept.
        var txid: String?
        var txHex: String?
        /// What reaches savings.
        var valueSats: UInt64 = 0
        var isAccepted = false
        /// The node's refusal; the sweep is not sent again.
        var rejection: String?
        /// Set once the chain host shows the accepted sweep in a block.
        var isConfirmed: Bool?
        /// The rate it was built at; nil for the exit's own rate.
        var feeRateSatPerVbyte: UInt64?
        /// The tip when a node first accepted it, so one that does not confirm is replaced at a higher rate.
        var sentAtHeight: UInt32?
        /// The sweeps this one replaced: any of them confirming also ends the sweep.
        var replacedTxids: [String]?
        /// With no `txid`: the tip when nothing at the address was worth sending at the network's economy rate. The
        /// sweep checks again every `sweepRecheckBlocks` and keeps the change after `sweepWaitBlocks`.
        var waitingSince: UInt32?
        /// The tip of the last such check.
        var checkedAtHeight: UInt32?
        /// The wait ran out: what is left stays at the funding address, with the path that spends it.
        var isDustKept: Bool?

        /// Waiting for fees to drop before sending the fee change.
        var isWaitingForFees: Bool {
            txid == nil && waitingSince != nil && isDustKept != true
        }

        /// A refusal for its fee is not final: the sweep is built again at the network's current rate.
        var isFeeRejection: Bool {
            rejection.map { $0.range(of: "fee", options: .caseInsensitive) != nil } ?? false
        }
    }

    var version: Int = Self.currentVersion
    let network: String
    let createdAt: Date
    var phase: Phase
    var feeRateSatPerVbyte: UInt64
    let destination: String
    /// The leaves of the quote the user confirmed; every rebuild selects exactly these.
    let leafIds: [String]
    /// What the quote's leaves hold together, for telling how much of the Spark balance is outside the exit.
    var leafTotalSats: UInt64?
    var funding: [Funding]
    /// Bumped on every rebuild. Broadcasts are logged per generation and a rebuilt recovery replaces the old one
    /// entirely, so older hex is never sent again.
    var generation: Int = 0
    var recovery: StoredRecovery?
    var broadcastLog: [BroadcastAttempt] = []
    var transferId: String?
    /// The fee funding payment Bitkit broadcast from savings, so the exit shows it as paid instead of asking again.
    var fundingPaymentTxid: String?
    /// What reaches savings: the exited value less the fees paid out of it.
    let expectedSats: UInt64
    var claimableAtHeight: UInt32?
    var leftover: [Leftover] = []
    var leftoverSweep: LeftoverSweep?
    /// The CPFP children and fan-outs of earlier generations, whose outputs at the funding address are not new funding.
    var earlierCpfpTxids: [String]?
    /// How the funding pays the CPFP children, the one every prepare and rebuild of the exit uses: `perNode` for exits
    /// started on SDK 0.28, absent for those started earlier, which keep resuming per branch.
    var fundingStrategy: String?
    /// Cooperative leaves a finished recovery listed as failed, tried again as their own recovery for about a week.
    var failedLeaves: [FailedLeaf]?
    /// The tip when the exit first finished with failed leaves, and of their last try.
    var failedLeafRetrySince: UInt32?
    var failedLeafRetriedAt: UInt32?
    /// The failed leaves were let go after about a week: the exit ended without them.
    var isFailedLeavesReleased: Bool?
    /// The confirmed sweep of a generation the failed-leaf retry replaced, which Done still shows.
    var landedSweepTxid: String?
    var skippedLeafCount: Int = 0
    /// Cooperative leaves the last build could not recover.
    var failedLeafCount: Int = 0
    /// Per step txid, how many rebuilds in a row reproduced it after another transaction spent its input.
    var spentStepStrikes: [String: Int]?
    var lostLeaves: [LostLeaf]?
    /// Rebuilds in a row for steps that keep being refused or a fee chain that lost a race, with no step confirming
    /// in between. At `SparkExitDriver.stallRebuildsToSurface` the exit stops rebuilding and says it is not moving.
    var stallRebuilds: Int?
    /// How many steps were confirmed when the last of those rebuilds started; more since then resets the count.
    var stallConfirmedCount: Int?
    /// The pending rebuild answers a divergence the SDK reported (`Redo`). Only such a rebuild adds lost-leaf strikes,
    /// so rebuilds over a stalled chain or an unverified step never make a leaf lost.
    var isRedoRebuild: Bool?
    /// The tip of the last rebuild over a step the SDK could not read, so it rebuilds at most once a block.
    var unverifiedRebuiltAtHeight: UInt32?
    /// The tip at which each of the exit's leaves was first seen stopped (`exitChainState.stoppedLeafIds`).
    var stoppedLeafSince: [String: UInt32]?
    /// The tip at which a build first found nothing to build while a leaf may still move, and of its last try.
    var retrySince: UInt32?
    var retriedAt: UInt32?
    /// The SDK's exit data from just before the first build, imported again before every rebuild.
    var exitStateSnapshot: String?
    /// The stored record could not be read, so the exit is rebuilt from the chain with the funding it kept.
    var isRebuiltFromChain: Bool?
    /// What confirmed sweeps and cooperative recoveries of replaced generations paid to savings, by txid.
    var earlierReceivedSats: [String: UInt64]?
    var leftBehindLeaves: [LeftBehindLeaf]?
    /// Set once the user opened the result of an exit that failed or lost leaves.
    var isResultSeen: Bool?
    /// Set and saved before a rebuild, so nothing of the diverged generation is broadcast while it is replaced.
    var isRebuilding = false
    var lastBuildAt: Date?

    var isActive: Bool {
        switch phase {
        case .awaitingFunding, .running, .needsFunding: true
        case .done, .failed: false
        }
    }

    /// An ended exit whose leftover fee funding still has to reach savings: not swept yet, or sent but not
    /// confirmed.
    var isLeftoverSweepPending: Bool {
        guard !isActive, !leftover.isEmpty else { return false }
        guard let leftoverSweep else { return true }
        if leftoverSweep.isWaitingForFees {
            return true
        }
        return leftoverSweep.txid != nil && (leftoverSweep.rejection == nil || leftoverSweep.isFeeRejection) && leftoverSweep.isConfirmed != true
    }

    static let lostReason = "Claimed by an older state"

    var isFailed: Bool {
        if case .failed = phase {
            return true
        }
        return false
    }

    /// An ended exit that failed or lost leaves, whose result the user has not opened yet.
    var hasUnseenResult: Bool {
        !isActive && (isFailed || lostSats > 0) && isResultSeen != true
    }

    /// Whether Emergency exit opens this exit rather than a new one: it runs, its leftover is still on its way to
    /// savings, the leftover sweep was refused and the leftover waits at the funding address, or it failed or lost
    /// leaves and the user has not seen that yet.
    var showsResult: Bool {
        needsDriving || (!leftover.isEmpty && leftoverSweep?.rejection != nil) || hasUnseenResult
    }

    /// The leaves builds select: the quote's, less those an older state claimed and those left behind.
    var exitLeafIds: [String] {
        let dropped = Set((lostLeaves ?? []).map(\.leafId) + (leftBehindLeaves ?? []).map(\.leafId))
        return leafIds.filter { !dropped.contains($0) }
    }

    var leftBehindSats: UInt64 {
        (leftBehindLeaves ?? []).reduce(0) { $0 + $1.valueSats }
    }

    /// Every leaf of the exit was claimed by an older state, none left behind.
    var isEveryLeafLost: Bool {
        let lost = Set((lostLeaves ?? []).map(\.leafId))
        return !lost.isEmpty && leafIds.allSatisfy(lost.contains)
    }

    var lostSats: UInt64 {
        (lostLeaves ?? []).reduce(0) { $0 + $1.valueSats }
    }

    /// The strikes of the steps a rebuild into `built` reproduces after their input was spent in this generation.
    func strikes(rebuiltInto built: RecoverFundsResponse) -> [String: Int] {
        let spent = Set(broadcastLog.filter { $0.generation == generation && $0.isInputSpent == true }.map(\.txid))
        var strikes: [String: Int] = [:]
        for tx in built.transactions where spent.contains(tx.txid) {
            strikes[tx.txid] = (spentStepStrikes?[tx.txid] ?? 0) + 1
        }
        return strikes
    }

    /// The funding key's index, which every funding entry of one exit shares.
    var fundingIndex: UInt32 {
        funding.first?.index ?? 0
    }

    /// Whether the driver still has work: the exit runs, or its leftover fee funding is on its way to savings.
    var needsDriving: Bool {
        isActive || isLeftoverSweepPending
    }

    var fundingInputs: [CpfpInput] {
        funding.compactMap(\.input)
    }

    var fundedSats: UInt64 {
        funding.reduce(0) { $0 + ($1.valueSats ?? 0) }
    }

    /// What the funding address still has to receive before the exit can build, or nil when nothing is missing.
    var fundingShortfallSats: UInt64? {
        guard let required = phase.requiredFundingSats else { return nil }
        let shortfall = required.saturatingSub(fundedSats)
        return shortfall > 0 ? shortfall : nil
    }

    /// Starts a new generation from a fresh build, forgetting what was broadcast for the previous one.
    mutating func adopt(_ built: RecoverFundsResponse, at date: Date = Date()) {
        if let recovery {
            let txids = SparkExitTxid.chainedTxids(recovery.response)
            if !txids.isEmpty {
                earlierCpfpTxids = (earlierCpfpTxids ?? []) + txids
            }
            let landed = SparkExitMath.paidToDestination(recovery.response.transactions.filter {
                if case .confirmed = $0.status {
                    return true
                }
                return false
            }, destination: destination)
            if !landed.isEmpty {
                earlierReceivedSats = (earlierReceivedSats ?? [:]).merging(landed) { $1 }
            }
            if let sweep = recovery.response.transactions.first(where: { $0.kind == .sweep }), case .confirmed = sweep.status {
                landedSweepTxid = sweep.txid
            }
        }
        generation += 1
        recovery = StoredRecovery(built)
        broadcastLog = []
        phase = .running
        isRebuilding = false
        lastBuildAt = date
        failedLeafCount = built.failed.count
        isRebuiltFromChain = nil
        isRedoRebuild = nil
    }

    /// Whether a build that found nothing to build is waiting for a leaf that may still move.
    var isWaitingForLeaves: Bool {
        retrySince != nil
    }

    /// The SDK strategy for `fundingStrategy`.
    var cpfpFundingStrategy: CpfpFundingStrategy {
        fundingStrategy == Self.perNodeStrategy ? .perNode : .perBranch
    }

    static let perNodeStrategy = "perNode"

    /// The exit's own steps all landed and it waits for the operators to co-sign leaves they moved on-chain.
    var isRetryingFailedLeaves: Bool {
        isActive && failedLeafRetrySince != nil
    }

    /// Waiting for the operators to co-sign leaves they moved on-chain: nothing of the exit's own is left to send.
    var isWaitingForOperators: Bool {
        isRetryingFailedLeaves && !(recovery?.response.failed.isEmpty ?? true)
    }

    var failedLeavesSats: UInt64 {
        (failedLeaves ?? []).reduce(0) { $0 + $1.valueSats }
    }

    /// Takes a higher fee rate for the steps still to confirm. With `extraSats` to come at the funding address the
    /// exit waits for it as for a top-up; with none it rebuilds at once at the new rate, replacing what is unconfirmed.
    mutating func applyFeeBump(rate: UInt64, extraSats: UInt64, paymentTxid: String?) {
        feeRateSatPerVbyte = rate
        isRedoRebuild = nil
        if extraSats > 0 {
            phase = .needsFunding(requiredSats: fundedSats + extraSats)
            fundingPaymentTxid = paymentTxid
        } else {
            isRebuilding = true
            lastBuildAt = nil
        }
    }

    /// A step of this generation that keeps being refused, or whose fee chain keeps failing. One the chain shows
    /// confirmed since, such as by the operators' copy of it, is not stuck.
    var stuckStep: BroadcastAttempt? {
        let confirmed = confirmedTxids
        return broadcastLog.first {
            $0.generation == generation && !$0.isAccepted && !confirmed.contains($0.txid)
                && ($0.rejections >= SparkExitDriver.rejectionsToSurface || ($0.feeChainFailures ?? 0) >= SparkExitDriver.feeChainFailuresToRebuild)
        }
    }

    private var confirmedTxids: Set<String> {
        Set((recovery?.response.transactions ?? []).filter {
            if case .confirmed = $0.status {
                return true
            }
            return false
        }.map(\.txid))
    }

    /// Whether rebuilding over a stuck step already failed to move the exit often enough to stop and say so.
    var isStalled: Bool {
        (stallRebuilds ?? 0) >= SparkExitDriver.stallRebuildsToSurface
    }

    /// A savings payment Bitkit made to the funding address, such as a higher fee's, that the exit has not adopted yet:
    /// nothing to ask the user for while it confirms.
    var isAwaitingOwnPayment: Bool {
        guard let paid = fundingPaymentTxid, fundingShortfallSats != nil else { return false }
        return !funding.contains { $0.txid == paid }
    }

    /// Progress says the exit is underpriced: it runs at its rate, nothing rebuilds it and no higher fee is on its way.
    func showsFeeLow(tip: UInt32?) -> Bool {
        phase == .running && !isRebuilding && underpricedStep(tip: tip) != nil
    }

    /// A step the network is busier than the exit's rate for: refused for a fee under the mempool's minimum, or
    /// accepted but unconfirmed for more blocks than a fair rate needs. Rebuilding at the same rate would not help.
    func underpricedStep(tip: UInt32?) -> BroadcastAttempt? {
        guard recovery != nil else { return nil }
        let confirmed = confirmedTxids
        return broadcastLog.first {
            guard $0.generation == generation, !confirmed.contains($0.txid) else { return false }
            if !$0.isAccepted {
                return $0.isFeeRateRefused == true
            }
            guard let tip, let height = $0.acceptedAtHeight else { return false }
            return tip > height && tip - height > SparkExitDriver.unconfirmedBlocksToSurface
        }
    }
}

// MARK: - Persistence

/// Reads and writes the exit record of one wallet. Writes are atomic and readable after the first unlock, so the
/// background task can drive the exit while the device is locked.
struct SparkExitStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(walletIndex: Int) {
        url = Env.sparkExitRecord(walletIndex: walletIndex)
    }

    /// The file exists but cannot be read now, such as before the first unlock after a restart: the record is left
    /// as it is and read again later.
    struct Unavailable: Error {
        let underlying: Error
    }

    func load() throws -> SparkExitRecord? {
        guard let data = try loadData() else { return nil }
        return try SparkExitRecordCoder.decode(data)
    }

    func loadData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Unavailable(underlying: error)
        }
    }

    /// Moves an unreadable record out of the way, keeping it for support.
    func setAside() throws {
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try FileManager.default.moveItem(at: url, to: aside)
    }

    func save(_ record: SparkExitRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SparkExitRecordCoder.encode(record).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// The ids of the leaves an older state of the wallet claimed on-chain, across exits. The operators keep listing such
/// a leaf under the wallet, so without this a later exit would quote it and lose it again. Not backed up: a restored
/// wallet finds the loss again in one rebuild cycle.
struct SparkExitLostLeafStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(walletIndex: Int) {
        url = Env.sparkExitLostLeaves(walletIndex: walletIndex)
    }

    func load() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Set(JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }

    /// Adds the record's lost leaves, writing only when one is new.
    func add(lostIn record: SparkExitRecord) throws {
        let ids = (record.lostLeaves ?? []).map(\.leafId)
        guard !ids.isEmpty else { return }
        // An unreadable list is written anew: a leaf missing from it is found lost again in one rebuild cycle.
        let stored = (try? load()) ?? []
        guard !stored.isSuperset(of: ids) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored.union(ids).sorted())
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

enum SparkExitRecordCoder {
    struct UnsupportedVersion: Error, Equatable {
        let version: Int
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    static func encode(_ record: SparkExitRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(record)
    }

    static func decode(_ data: Data) throws -> SparkExitRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let version = try decoder.decode(VersionProbe.self, from: data).version
        var data = data
        if version != SparkExitRecord.currentVersion {
            guard let convert = SparkExitRecordMigration.converters[version] else { throw UnsupportedVersion(version: version) }
            data = try convert(data)
        }
        return try decoder.decode(SparkExitRecord.self, from: data)
    }

    /// What a record that cannot be decoded still tells about its exit: enough to build it again from the chain with
    /// the funding it kept. Nil when it names no active exit, or lacks what a build needs.
    static func salvage(_ data: Data) -> SparkExitRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let kept = try? decoder.decode(Salvaged.self, from: data), !kept.leafIds.isEmpty, !kept.funding.isEmpty else { return nil }
        let phase = kept.phase
        var record = SparkExitRecord(
            network: kept.network,
            createdAt: kept.createdAt,
            phase: .running,
            feeRateSatPerVbyte: kept.feeRateSatPerVbyte,
            destination: kept.destination,
            leafIds: kept.leafIds,
            leafTotalSats: kept.leafTotalSats,
            funding: kept.funding,
            transferId: kept.transferId,
            expectedSats: kept.expectedSats
        )
        switch phase {
        case .done, .failed:
            return nil
        case .awaitingFunding, .needsFunding:
            record.phase = phase ?? .running
        case .running, nil:
            record.isRebuilding = true
        }
        record.lostLeaves = kept.lostLeaves
        record.leftBehindLeaves = kept.leftBehindLeaves
        record.exitStateSnapshot = kept.exitStateSnapshot
        record.isRebuiltFromChain = true
        return record
    }

    private struct Salvaged: Decodable {
        let network: String
        let createdAt: Date
        let phase: SparkExitRecord.Phase?
        let feeRateSatPerVbyte: UInt64
        let destination: String
        let leafIds: [String]
        let leafTotalSats: UInt64?
        let funding: [SparkExitRecord.Funding]
        let transferId: String?
        let expectedSats: UInt64
        let lostLeaves: [SparkExitRecord.LostLeaf]?
        let leftBehindLeaves: [SparkExitRecord.LeftBehindLeaf]?
        let exitStateSnapshot: String?

        private enum CodingKeys: String, CodingKey {
            case network, createdAt, phase, feeRateSatPerVbyte, destination, leafIds, leafTotalSats, funding, transferId, expectedSats
            case lostLeaves, leftBehindLeaves, exitStateSnapshot
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            network = try c.decode(String.self, forKey: .network)
            createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
            phase = try? c.decodeIfPresent(SparkExitRecord.Phase.self, forKey: .phase)
            feeRateSatPerVbyte = try c.decode(UInt64.self, forKey: .feeRateSatPerVbyte)
            destination = try c.decode(String.self, forKey: .destination)
            leafIds = try c.decode([String].self, forKey: .leafIds)
            leafTotalSats = try? c.decodeIfPresent(UInt64.self, forKey: .leafTotalSats)
            funding = try c.decode([SparkExitRecord.Funding].self, forKey: .funding)
            transferId = try? c.decodeIfPresent(String.self, forKey: .transferId)
            expectedSats = (try? c.decode(UInt64.self, forKey: .expectedSats)) ?? 0
            lostLeaves = try? c.decodeIfPresent([SparkExitRecord.LostLeaf].self, forKey: .lostLeaves)
            leftBehindLeaves = try? c.decodeIfPresent([SparkExitRecord.LeftBehindLeaf].self, forKey: .leftBehindLeaves)
            exitStateSnapshot = try? c.decodeIfPresent(String.self, forKey: .exitStateSnapshot)
        }
    }
}

/// Converts a record written with another `version` to the current one before it is decoded. Add a converter here
/// before changing `SparkExitRecord.currentVersion`, so an exit written by the earlier version keeps running as it was.
enum SparkExitRecordMigration {
    static let converters: [Int: (Data) throws -> Data] = [:]
}

// MARK: - RecoverFundsResponse in spark-sdk's serde shape

/// `RecoverFundsResponse` as spark-sdk 0.27.2 serializes it with serde: snake_case fields and externally tagged
/// enums (`"Ready"`, `{"Confirmed":{"block_height":120}}`). A stored recovery is then readable by the Breez CLI's
/// `check-recover-funds` and shared with Android as one format. The SDK's Swift types are not `Codable`.
struct StoredRecovery: Codable, Equatable {
    let response: RecoverFundsResponse

    init(_ response: RecoverFundsResponse) {
        self.response = response
    }

    private enum CodingKeys: String, CodingKey {
        case recoverableValueSats = "recoverable_value_sats"
        case totalFeeSats = "total_fee_sats"
        case cooperativeFeeSats = "cooperative_fee_sats"
        case cpfpFeeSats = "cpfp_fee_sats"
        case fanoutFeeSats = "fanout_fee_sats"
        case refundFeeSats = "refund_fee_sats"
        case sweepFeeSats = "sweep_fee_sats"
        case leaves
        case failed
        case transactions
        case fundingInputs = "funding_inputs"
        case feeRateSatPerVbyte = "fee_rate_sat_per_vbyte"
        case destination
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        response = try RecoverFundsResponse(
            recoverableValueSats: c.decode(UInt64.self, forKey: .recoverableValueSats),
            totalFeeSats: c.decode(UInt64.self, forKey: .totalFeeSats),
            cooperativeFeeSats: c.decode(UInt64.self, forKey: .cooperativeFeeSats),
            cpfpFeeSats: c.decode(UInt64.self, forKey: .cpfpFeeSats),
            fanoutFeeSats: c.decode(UInt64.self, forKey: .fanoutFeeSats),
            refundFeeSats: c.decode(UInt64.self, forKey: .refundFeeSats),
            sweepFeeSats: c.decode(UInt64.self, forKey: .sweepFeeSats),
            leaves: c.decode([StoredLeaf].self, forKey: .leaves).map(\.value),
            failed: c.decode([StoredFailure].self, forKey: .failed).map(\.value),
            transactions: c.decode([StoredTransaction].self, forKey: .transactions).map(\.value),
            fundingInputs: c.decode([StoredCpfpInput].self, forKey: .fundingInputs).map(\.value),
            feeRateSatPerVbyte: c.decode(UInt64.self, forKey: .feeRateSatPerVbyte),
            destination: c.decode(String.self, forKey: .destination)
        )
    }

    func encode(to encoder: Encoder) throws {
        let r = response
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(r.recoverableValueSats, forKey: .recoverableValueSats)
        try c.encode(r.totalFeeSats, forKey: .totalFeeSats)
        try c.encode(r.cooperativeFeeSats, forKey: .cooperativeFeeSats)
        try c.encode(r.cpfpFeeSats, forKey: .cpfpFeeSats)
        try c.encode(r.fanoutFeeSats, forKey: .fanoutFeeSats)
        try c.encode(r.refundFeeSats, forKey: .refundFeeSats)
        try c.encode(r.sweepFeeSats, forKey: .sweepFeeSats)
        try c.encode(r.leaves.map(StoredLeaf.init), forKey: .leaves)
        try c.encode(r.failed.map(StoredFailure.init), forKey: .failed)
        try c.encode(r.transactions.map(StoredTransaction.init), forKey: .transactions)
        try c.encode(r.fundingInputs.map(StoredCpfpInput.init), forKey: .fundingInputs)
        try c.encode(r.feeRateSatPerVbyte, forKey: .feeRateSatPerVbyte)
        try c.encode(r.destination, forKey: .destination)
    }
}

private struct StoredLeaf: Codable {
    let value: RecoverFundsLeaf

    init(_ value: RecoverFundsLeaf) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case leafId = "leaf_id"
        case valueSats = "value_sats"
        case method
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let method: RecoveryMethod = switch try c.decode(String.self, forKey: .method) {
        case "Cooperative": .cooperative
        case "Unilateral": .unilateral
        case let other: throw DecodingError.dataCorruptedError(forKey: .method, in: c, debugDescription: "Unknown method \(other)")
        }
        value = try RecoverFundsLeaf(
            leafId: c.decode(String.self, forKey: .leafId),
            valueSats: c.decode(UInt64.self, forKey: .valueSats),
            method: method
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value.leafId, forKey: .leafId)
        try c.encode(value.valueSats, forKey: .valueSats)
        try c.encode(value.method == .cooperative ? "Cooperative" : "Unilateral", forKey: .method)
    }
}

private struct StoredFailure: Codable {
    let value: CooperativeRecoveryFailure

    init(_ value: CooperativeRecoveryFailure) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case leafId = "leaf_id"
        case outputTxid = "output_txid"
        case outputVout = "output_vout"
        case error
    }

    private enum ErrorKeys: String, CodingKey {
        case requiredFeeSats = "required_fee_sats"
        case requiredFeeRateSatPerVbyte = "required_fee_rate_sat_per_vbyte"
        case message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let error = try ExternallyTagged.decode(from: c.superDecoder(forKey: .error)) { tag, fields -> CooperativeRecoveryError in
            let f = try fields?.container(keyedBy: ErrorKeys.self)
            switch tag {
            case "ReplacementFeeTooLow":
                return try .replacementFeeTooLow(
                    requiredFeeSats: ExternallyTagged.require(f).decode(UInt64.self, forKey: .requiredFeeSats),
                    requiredFeeRateSatPerVbyte: ExternallyTagged.require(f).decode(UInt64.self, forKey: .requiredFeeRateSatPerVbyte)
                )
            case "OperatorsUnavailable":
                return try .operatorsUnavailable(message: ExternallyTagged.require(f).decode(String.self, forKey: .message))
            case "Generic":
                return try .generic(message: ExternallyTagged.require(f).decode(String.self, forKey: .message))
            default:
                throw ExternallyTagged.unknown(tag)
            }
        }
        value = try CooperativeRecoveryFailure(
            leafId: c.decode(String.self, forKey: .leafId),
            outputTxid: c.decode(String.self, forKey: .outputTxid),
            outputVout: c.decode(UInt32.self, forKey: .outputVout),
            error: error
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value.leafId, forKey: .leafId)
        try c.encode(value.outputTxid, forKey: .outputTxid)
        try c.encode(value.outputVout, forKey: .outputVout)
        let errorEncoder = c.superEncoder(forKey: .error)
        switch value.error {
        case let .replacementFeeTooLow(requiredFeeSats, requiredFeeRateSatPerVbyte):
            var f = ExternallyTagged.fields(errorEncoder, tag: "ReplacementFeeTooLow", keyedBy: ErrorKeys.self)
            try f.encode(requiredFeeSats, forKey: .requiredFeeSats)
            try f.encode(requiredFeeRateSatPerVbyte, forKey: .requiredFeeRateSatPerVbyte)
        case let .operatorsUnavailable(message):
            var f = ExternallyTagged.fields(errorEncoder, tag: "OperatorsUnavailable", keyedBy: ErrorKeys.self)
            try f.encode(message, forKey: .message)
        case let .generic(message):
            var f = ExternallyTagged.fields(errorEncoder, tag: "Generic", keyedBy: ErrorKeys.self)
            try f.encode(message, forKey: .message)
        }
    }
}

private struct StoredTransaction: Codable {
    let value: RecoveryTransaction

    init(_ value: RecoveryTransaction) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case nodeId = "node_id"
        case txid
        case txHex = "tx_hex"
        case cpfpTxHex = "cpfp_tx_hex"
        case csvTimelockBlocks = "csv_timelock_blocks"
        case dependsOn = "depends_on"
        case status
    }

    private enum StatusKeys: String, CodingKey {
        case blockHeight = "block_height"
        case spendableAtHeight = "spendable_at_height"
    }

    private static let kinds: [(RecoveryTxKind, String)] = [
        (.cooperative, "Cooperative"), (.fanOut, "FanOut"), (.node, "Node"), (.refund, "Refund"), (.sweep, "Sweep"),
    ]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kindName = try c.decode(String.self, forKey: .kind)
        guard let kind = Self.kinds.first(where: { $0.1 == kindName })?.0 else { throw ExternallyTagged.unknown(kindName) }
        let status = try ExternallyTagged.decode(from: c.superDecoder(forKey: .status)) { tag, fields -> ExitTransactionStatus in
            let f = try fields?.container(keyedBy: StatusKeys.self)
            switch tag {
            case "Confirmed": return try .confirmed(blockHeight: ExternallyTagged.require(f).decodeIfPresent(UInt32.self, forKey: .blockHeight))
            case "Ready": return .ready
            case "WaitingForDependencies": return .waitingForDependencies
            case "WaitingForTimelock":
                return try .waitingForTimelock(spendableAtHeight: ExternallyTagged.require(f).decodeIfPresent(
                    UInt32.self,
                    forKey: .spendableAtHeight
                ))
            case "Unverified": return .unverified
            default: throw ExternallyTagged.unknown(tag)
            }
        }
        value = try RecoveryTransaction(
            kind: kind,
            nodeId: c.decodeIfPresent(String.self, forKey: .nodeId),
            txid: c.decode(String.self, forKey: .txid),
            txHex: c.decode(String.self, forKey: .txHex),
            cpfpTxHex: c.decodeIfPresent(String.self, forKey: .cpfpTxHex),
            csvTimelockBlocks: c.decodeIfPresent(UInt32.self, forKey: .csvTimelockBlocks),
            dependsOn: c.decode([String].self, forKey: .dependsOn),
            status: status
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.kinds.first { $0.0 == value.kind }?.1, forKey: .kind)
        try c.encode(value.nodeId, forKey: .nodeId)
        try c.encode(value.txid, forKey: .txid)
        try c.encode(value.txHex, forKey: .txHex)
        try c.encode(value.cpfpTxHex, forKey: .cpfpTxHex)
        try c.encode(value.csvTimelockBlocks, forKey: .csvTimelockBlocks)
        try c.encode(value.dependsOn, forKey: .dependsOn)
        let statusEncoder = c.superEncoder(forKey: .status)
        switch value.status {
        case let .confirmed(blockHeight):
            var f = ExternallyTagged.fields(statusEncoder, tag: "Confirmed", keyedBy: StatusKeys.self)
            try f.encode(blockHeight, forKey: .blockHeight)
        case .ready:
            try ExternallyTagged.unit(statusEncoder, tag: "Ready")
        case .waitingForDependencies:
            try ExternallyTagged.unit(statusEncoder, tag: "WaitingForDependencies")
        case let .waitingForTimelock(spendableAtHeight):
            var f = ExternallyTagged.fields(statusEncoder, tag: "WaitingForTimelock", keyedBy: StatusKeys.self)
            try f.encode(spendableAtHeight, forKey: .spendableAtHeight)
        case .unverified:
            try ExternallyTagged.unit(statusEncoder, tag: "Unverified")
        }
    }
}

private struct StoredCpfpInput: Codable {
    let value: CpfpInput

    init(_ value: CpfpInput) {
        self.value = value
    }

    private enum Keys: String, CodingKey {
        case txid
        case vout
        case valueSats = "value_sats"
        case pubkey
        case scriptPubkeyHex = "script_pubkey_hex"
        case signedInputWeight = "signed_input_weight"
    }

    init(from decoder: Decoder) throws {
        value = try ExternallyTagged.decode(from: decoder) { tag, fields -> CpfpInput in
            let f = try ExternallyTagged.require(fields?.container(keyedBy: Keys.self))
            let txid = try f.decode(String.self, forKey: .txid)
            let vout = try f.decode(UInt32.self, forKey: .vout)
            let valueSats = try f.decode(UInt64.self, forKey: .valueSats)
            switch tag {
            case "P2wpkh": return try .p2wpkh(txid: txid, vout: vout, valueSats: valueSats, pubkey: f.decode(String.self, forKey: .pubkey))
            case "P2tr": return try .p2tr(txid: txid, vout: vout, valueSats: valueSats, pubkey: f.decode(String.self, forKey: .pubkey))
            case "Custom":
                return try .custom(
                    txid: txid,
                    vout: vout,
                    valueSats: valueSats,
                    scriptPubkeyHex: f.decode(String.self, forKey: .scriptPubkeyHex),
                    signedInputWeight: f.decode(UInt64.self, forKey: .signedInputWeight)
                )
            default: throw ExternallyTagged.unknown(tag)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        switch value {
        case let .p2wpkh(txid, vout, valueSats, pubkey), let .p2tr(txid, vout, valueSats, pubkey):
            var f = ExternallyTagged.fields(encoder, tag: {
                if case .p2wpkh = value {
                    "P2wpkh"
                } else {
                    "P2tr"
                }
            }(), keyedBy: Keys.self)
            try f.encode(txid, forKey: .txid)
            try f.encode(vout, forKey: .vout)
            try f.encode(valueSats, forKey: .valueSats)
            try f.encode(pubkey, forKey: .pubkey)
        case let .custom(txid, vout, valueSats, scriptPubkeyHex, signedInputWeight):
            var f = ExternallyTagged.fields(encoder, tag: "Custom", keyedBy: Keys.self)
            try f.encode(txid, forKey: .txid)
            try f.encode(vout, forKey: .vout)
            try f.encode(valueSats, forKey: .valueSats)
            try f.encode(scriptPubkeyHex, forKey: .scriptPubkeyHex)
            try f.encode(signedInputWeight, forKey: .signedInputWeight)
        }
    }
}

/// serde's default enum representation: a unit variant is its name as a string, a variant with fields is an object
/// with the name as its only key.
private enum ExternallyTagged {
    struct TagKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }

    static func decode<T>(from decoder: Decoder, variant: (String, Decoder?) throws -> T) throws -> T {
        if let tag = try? decoder.singleValueContainer().decode(String.self) {
            return try variant(tag, nil)
        }
        let c = try decoder.container(keyedBy: TagKey.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one variant key"))
        }
        return try variant(key.stringValue, c.superDecoder(forKey: key))
    }

    static func fields<Keys: CodingKey>(_ encoder: Encoder, tag: String, keyedBy _: Keys.Type) -> KeyedEncodingContainer<Keys> {
        var c = encoder.container(keyedBy: TagKey.self)
        return c.nestedContainer(keyedBy: Keys.self, forKey: TagKey(stringValue: tag))
    }

    static func unit(_ encoder: Encoder, tag: String) throws {
        var c = encoder.singleValueContainer()
        try c.encode(tag)
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Variant is missing its fields"))
        }
        return value
    }

    static func unknown(_ tag: String) -> Error {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown variant \(tag)"))
    }
}
