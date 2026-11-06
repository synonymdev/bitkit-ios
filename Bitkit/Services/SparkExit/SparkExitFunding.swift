import BitkitCore
import BreezSdkSpark
import CryptoKit
import Foundation
import LDKNode

/// The key that pays a Spark exit's CPFP fees. It derives from the wallet seed on an account no wallet of Bitkit's
/// derives, so ldk-node never spends the funding UTXO or the CPFP change chained back to it.
enum SparkExitFundingKey {
    static let account: UInt32 = 7797

    struct Derived {
        let address: String
        /// Compressed public key, hex, as `CpfpInput.p2wpkh` takes it.
        let pubkey: String
        let secretKey: Data
    }

    enum KeyError: Error, Equatable {
        case invalidWif
    }

    static func path(index: UInt32, network: BitkitCore.Network) -> String {
        let coin = network == .bitcoin ? 0 : 1
        return "m/84'/\(coin)'/\(account)'/0/\(index)"
    }

    static func derive(index: UInt32, mnemonic: String, passphrase: String?, network: BitkitCore.Network) throws -> Derived {
        let path = path(index: index, network: network)
        let address = try deriveBitcoinAddress(mnemonicPhrase: mnemonic, derivationPathStr: path, network: network, bip39Passphrase: passphrase)
        let wif = try derivePrivateKey(mnemonicPhrase: mnemonic, derivationPathStr: path, network: network, bip39Passphrase: passphrase)
        return try Derived(address: address.address, pubkey: address.publicKey, secretKey: secretKey(fromWif: wif))
    }

    /// The 32-byte secret of a compressed-key WIF: base58check, version byte first, `0x01` compression flag last.
    static func secretKey(fromWif wif: String) throws -> Data {
        guard let decoded = Base58.decode(wif), decoded.count == 38 else { throw KeyError.invalidWif }
        let payload = decoded.prefix(34)
        let checksum = Data(SHA256.hash(data: Data(SHA256.hash(data: payload)))).prefix(4)
        guard Data(decoded.suffix(4)) == checksum, decoded[decoded.startIndex + 33] == 0x01 else { throw KeyError.invalidWif }
        return Data(payload.dropFirst().prefix(32))
    }
}

enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    static func decode(_ string: String) -> Data? {
        var bytes: [UInt8] = []
        for character in string {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            var carry = digit
            for i in bytes.indices.reversed() {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        let leadingZeros = string.prefix { $0 == "1" }.count
        return Data(repeating: 0, count: leadingZeros) + Data(bytes)
    }
}

/// What an exit costs and returns, from a `prepareRecoverFunds` quote.
struct SparkExitQuote: Equatable {
    let prepared: PrepareRecoverFundsResponse
    /// The values of the leaves an older state claimed that the operators still list, which the quote leaves out.
    var lostLeafSats: [UInt64] = []

    /// Prepares every leaf less those an older state claimed in an earlier exit, which the operators still list. The
    /// rest is prepared again on its own, so the amount, fees and funding leave the lost leaves out. With none left
    /// the quote has no leaf, as when no leaf can be exited.
    static func prepare(
        _ recovering: SparkExitRecovering,
        feeRateSatPerVbyte: UInt64,
        destination: String,
        lostLeafIds: Set<String>,
        fundingStrategy: CpfpFundingStrategy = .perNode
    ) async throws -> SparkExitQuote {
        func request(_ selection: ExitLeafSelection) -> PrepareRecoverFundsRequest {
            PrepareRecoverFundsRequest(
                feeRateSatPerVbyte: feeRateSatPerVbyte,
                fundingKind: .p2wpkh,
                fundingStrategy: fundingStrategy,
                destination: destination,
                selection: selection
            )
        }
        let all = try await recovering.prepare(request(.all))
        let lostLeafSats = all.leaves.filter { lostLeafIds.contains($0.leafId) }.map(\.valueSats)
            + all.skipped.filter { lostLeafIds.contains($0.leafId) }.map(\.valueSats)
        guard all.leaves.contains(where: { lostLeafIds.contains($0.leafId) }) else {
            return SparkExitQuote(prepared: all, lostLeafSats: lostLeafSats)
        }
        let remaining = all.leaves.map(\.leafId).filter { !lostLeafIds.contains($0) }
        var prepared = all
        if remaining.isEmpty {
            prepared.leaves = []
            prepared.recoverableValueSats = 0
            prepared.totalFeeSats = 0
            prepared.cooperativeFeeSats = 0
            prepared.cpfpFeeSats = 0
            prepared.fanoutFeeSats = 0
            prepared.refundFeeSats = 0
            prepared.sweepFeeSats = 0
            prepared.funding = nil
        } else {
            prepared = try await recovering.prepare(request(.specific(leafIds: remaining)))
        }
        // `Specific` lists only its own leaves as skipped; the leaves `All` could not exit stay left behind.
        let listed = Set(prepared.skipped.map(\.leafId))
        prepared.skipped += all.skipped.filter { !lostLeafIds.contains($0.leafId) && !listed.contains($0.leafId) }
        return SparkExitQuote(prepared: prepared, lostLeafSats: lostLeafSats)
    }

    /// The value of the leaves the exit takes on-chain.
    var exitSats: UInt64 {
        prepared.recoverableValueSats
    }

    var networkFeeSats: UInt64 {
        prepared.totalFeeSats
    }

    /// What savings gains overall: the exited value less every fee, those paid from the fee funding included.
    var receiveSats: UInt64 {
        exitSats.saturatingSub(networkFeeSats)
    }

    /// The on-chain payment that funds the CPFP fees, or 0 when every leaf is recovered cooperatively. One payment,
    /// from savings or another wallet: the SDK splits it into one output per fee-bumped transaction (`fundedSteps`).
    var fundingSats: UInt64 {
        prepared.funding?.singleUtxoSats ?? 0
    }

    /// The transactions the funding pays a fee for, each from its own share.
    var fundedSteps: Int {
        prepared.funding?.perBranch.count ?? 0
    }

    /// What the sweep and the cooperative recoveries pay to savings: `receiveSats` plus the fee funding the exit
    /// did not spend, which the sweep returns.
    var incomingSats: UInt64 {
        receiveSats + fundingSats
    }

    var leftBehindSats: UInt64 {
        prepared.skipped.reduce(0) { $0 + $1.valueSats }
    }

    var leafIds: [String] {
        prepared.leaves.map(\.leafId)
    }

    var leafTotalSats: UInt64 {
        prepared.leaves.reduce(0) { $0 + $1.valueSats }
    }

    /// Breez's rule: only exit when the value is more than its fees.
    var isWorthExiting: Bool {
        !prepared.leaves.isEmpty && exitSats > networkFeeSats
    }
}

/// The network's fee rates now, in sat/vB: for the next block, and for about half an hour.
struct SparkExitNetworkFees: Equatable {
    let fastest: UInt64
    let halfHour: UInt64
    /// The slowest tier: what the leftover sweep pays, since the change can wait.
    var economy: UInt64 = 1
}

/// A higher fee rate an exit can move to, and what moving costs: the funding the exit lacks at that rate (`extraSats`,
/// nil while it is priced or when it could not be) and, when savings pays it, that payment's own fee.
struct SparkExitFeeBumpOption: Equatable, Identifiable {
    let speed: TransactionSpeed
    let rate: UInt64
    var extraSats: UInt64?
    var paymentFeeSats: UInt64?

    var id: UInt64 {
        rate
    }

    /// What leaves savings: the extra funding and its payment's fee. Nothing when the funding already covers the rate.
    var totalSats: UInt64? {
        guard let extraSats else { return nil }
        guard extraSats > 0 else { return 0 }
        return paymentFeeSats.map { extraSats + $0 }
    }

    /// The rates a fee bump offers, each strictly above the exit's: replacements must pay a higher rate. Fast is the
    /// next-block rate, or one above the exit's when the network's estimate is no higher; Normal the half-hour rate,
    /// when it lies between the two.
    static func options(exitRate: UInt64, fees: SparkExitNetworkFees) -> [SparkExitFeeBumpOption] {
        let fast = max(fees.fastest, exitRate + 1)
        var options = [SparkExitFeeBumpOption(speed: .fast, rate: fast)]
        if fees.halfHour > exitRate, fees.halfHour < fast {
            options.append(SparkExitFeeBumpOption(speed: .normal, rate: fees.halfHour))
        }
        return options
    }
}

/// A local notification that brings the user back to an exit; `id` is stable across runs for the same step.
struct SparkExitReminder: Equatable {
    let id: String
    let fireAt: Date
    var isFunding = false
    var isLostLeaves = false
    var isFailed = false
    var isNotMoving = false
}

/// What the exit shows about its fee funding while it lacks some.
enum SparkExitFundingState: Equatable {
    /// Ask for `sats` more at the funding address, with its QR. `receivedSats` is the new funding already there.
    case ask(sats: UInt64, receivedSats: UInt64 = 0)
    /// Bitkit paid it from savings in `txid`, which has not confirmed yet.
    case paid(txid: String)
    /// A payment covering the shortfall reached the address, and the exit waits for it to confirm or to build.
    case seen(txid: String)
}

enum SparkExitMath {
    /// The countdown target: the tip plus the blocks the longest path of steps left still needs, so the countdown
    /// does not jump when a step's parent confirms and its own timelock starts. Without the tip, the latest block at
    /// which a timelocked step can confirm.
    static func claimableAtHeight(_ recovery: RecoverFundsResponse, tip: UInt32? = nil) -> UInt32? {
        if let tip {
            return blocksToFinish(recovery.transactions, tip: tip).map { tip.addingReportingOverflow($0).partialValue }
        }
        return recovery.transactions.compactMap { tx -> UInt32? in
            if case let .waitingForTimelock(height) = tx.status {
                return height
            }
            return nil
        }.max()
    }

    /// Blocks until the last step could confirm: the longest path through the steps left, each costing its remaining
    /// timelock plus a block to confirm in (Glow's `blocksToFinish`). Nil once every step confirmed. The SDK lists
    /// steps in broadcast order, so a parent always comes before what depends on it.
    static func blocksToFinish(_ transactions: [RecoveryTransaction], tip: UInt32) -> UInt32? {
        var after: [String: UInt32] = [:]
        var longest: UInt32?
        for tx in transactions {
            let timelock: UInt32
            switch tx.status {
            case .confirmed:
                after[tx.txid] = 0
                continue
            case .ready:
                timelock = 0
            case let .waitingForTimelock(height?):
                timelock = height > tip ? height - tip : 0
            default:
                timelock = tx.csvTimelockBlocks ?? 0
            }
            let blocks = (tx.dependsOn.compactMap { after[$0] }.max() ?? 0) + timelock + 1
            after[tx.txid] = blocks
            longest = max(longest ?? 0, blocks)
        }
        // Everything confirmed: nothing left to wait for.
        return longest
    }

    /// Blocks after a step matures before the operators' watchtower may publish their own version.
    static let operatorWindowBlocks: UInt32 = 50
    /// Blocks after a refund matures before an older state of the wallet, with a refund 100 blocks shorter, can
    /// claim the leaf while the operators are down.
    static let olderStateLeadBlocks: UInt32 = 100
    /// Blocks after a step matures before its reminder fires: well inside the smaller of the two windows above, and
    /// time for a background run to publish it first.
    static let reminderGraceBlocks: UInt32 = 12
    /// Below the OS's 64 pending notifications per app.
    static let maxTimelockReminders = 20

    /// The reminders an exit needs now. Each timelocked step not yet published gets one at its maturity plus a
    /// grace; a step ready to publish gets one after the grace; needing fee funding or a step rejected repeatedly
    /// reminds at once. While a rebuild is pending, one reminder past its due time replaces the steps' own. A step
    /// published or confirmed needs none, so a background run that publishes a step drops its reminder before it fires.
    static func reminders(_ record: SparkExitRecord, tip: UInt32?, now: Date, network: LDKNode.Network) -> [SparkExitReminder] {
        let lost = record.lostLeaves ?? []
        var lostReminder = lost.isEmpty ? [] : [SparkExitReminder(id: "lost-\(lost.count)", fireAt: now, isLostLeaves: true)]
        // An exit stopped because every leaf was lost is told by the lost reminder alone.
        if case .failed = record.phase, !record.isEveryLeafLost {
            lostReminder.append(SparkExitReminder(id: "failed", fireAt: now, isFailed: true))
        }
        if case let .needsFunding(requiredSats) = record.phase {
            // A payment Bitkit already sent from savings, such as a higher fee's, needs no reminder to fund.
            guard !record.isAwaitingOwnPayment else { return lostReminder }
            return lostReminder + [SparkExitReminder(id: "funding-\(requiredSats)", fireAt: now, isFunding: true)]
        }
        guard case .running = record.phase, let recovery = record.recovery?.response else { return lostReminder }
        var reminders = lostReminder
        // Waiting for a leaf that may still move is the background runs' job, for up to a week.
        if record.isWaitingForLeaves || record.isWaitingForOperators {
            return reminders
        }
        let generation = record.generation
        let blockSeconds = secondsUntil(height: 1, tip: 0, network: network)
        let grace = TimeInterval(reminderGraceBlocks) * blockSeconds
        // A diverged generation is never sent again, so its steps need no reminder: only a rebuild that does not come.
        if record.isRebuilding {
            let due = (record.lastBuildAt ?? now).addingTimeInterval(SparkExitDriver.rebuildInterval)
            reminders.append(SparkExitReminder(id: "\(generation)-rebuild", fireAt: max(due, now).addingTimeInterval(grace)))
            return reminders
        }
        if record.isStalled, let stuck = record.stuckStep {
            reminders.append(SparkExitReminder(id: "rejected-\(generation)-\(stuck.txid)", fireAt: now, isNotMoving: true))
        }
        // Accepted but not confirming: rebuilding would not help, so its reminder is planned once and never moved.
        if let slow = record.underpricedStep(tip: tip) {
            reminders.append(SparkExitReminder(id: "\(generation)-slow-\(slow.txid)", fireAt: now.addingTimeInterval(grace)))
        }
        let accepted = Set(record.broadcastLog.filter { $0.generation == generation && $0.isAccepted }.map(\.txid))
        var heights = Set<UInt32>()
        var readyTxid: String?
        for tx in recovery.transactions where !accepted.contains(tx.txid) {
            switch tx.status {
            case let .waitingForTimelock(height?):
                heights.insert(height)
            case .ready:
                readyTxid = readyTxid ?? tx.txid
            default:
                break
            }
        }
        for height in heights.sorted().prefix(maxTimelockReminders) {
            let wait = tip.map { secondsUntil(height: height, tip: $0, network: network) } ?? reminderSeconds(network: network)
            reminders.append(SparkExitReminder(id: "\(generation)-h\(height)", fireAt: now.addingTimeInterval(wait + grace)))
        }
        if let readyTxid {
            reminders.append(SparkExitReminder(id: "\(generation)-ready-\(readyTxid)", fireAt: now.addingTimeInterval(grace)))
        }
        // Steps waiting for parents have no height yet, which only a run learns: remind once progress stalls. Any
        // confirmation or accepted broadcast changes the id, which starts the wait again.
        let confirmed = confirmedCount(recovery)
        let isAhead = heights.contains { height in tip.map { height > $0 } ?? true }
        if !isAhead, confirmed < recovery.transactions.count {
            let id = "\(generation)-idle-\(confirmed)-\(accepted.count)"
            reminders.append(SparkExitReminder(id: id, fireAt: now.addingTimeInterval(reminderSeconds(network: network))))
        }
        return reminders
    }

    /// What the exit's sweep and cooperative recoveries paid to its savings address, and the sweep's txid, once it
    /// ended done. Nil before, or when no output to savings can be read.
    /// Generations a Redo replaced count too, so a cooperative recovery that landed before it is included.
    static func received(_ record: SparkExitRecord) -> (sats: UInt64, sweepTxid: String?)? {
        guard record.phase == .done, let transactions = record.recovery?.response.transactions else { return nil }
        let paid = (record.earlierReceivedSats ?? [:]).merging(paidToDestination(transactions, destination: record.destination)) { $1 }
        let sats = paid.values.reduce(0, +)
        guard sats > 0 else { return nil }
        return (sats, transactions.first { $0.kind == .sweep }?.txid ?? record.landedSweepTxid)
    }

    /// What each sweep or cooperative recovery among `transactions` pays to `destination`, by txid.
    static func paidToDestination(_ transactions: [RecoveryTransaction], destination: String) -> [String: UInt64] {
        guard let script = try? SparkExitAddress.scriptPubKey(destination) else { return [:] }
        var paid: [String: UInt64] = [:]
        for tx in transactions where tx.kind == .sweep || tx.kind == .cooperative {
            let sats = (SparkExitTxid.outputs(hex: tx.txHex) ?? []).filter { $0.script == script }.reduce(0) { $0 + $1.value }
            if sats > 0 {
                paid[tx.txid] = sats
            }
        }
        return paid
    }

    /// Whether every refund's timelock is behind it: none still waits for its parents or its height.
    static func areTimelocksMatured(_ transactions: [RecoveryTransaction]) -> Bool {
        let refunds = transactions.filter { $0.kind == .refund }
        return !refunds.isEmpty && !refunds.contains {
            switch $0.status {
            case .waitingForDependencies, .waitingForTimelock: true
            default: false
            }
        }
    }

    /// The active exit transfers no running exit owns: a record set aside as unreadable, or one written without its
    /// transfer id before a crash, would otherwise count its amount as in transfer to savings for good.
    static func orphanedTransferIds(_ activeTransfers: [Transfer], record: SparkExitRecord?) -> [String] {
        let owned = record?.isActive == true ? record?.transferId : nil
        return activeTransfers.filter { $0.type == .sparkExit && $0.id != owned }.map(\.id)
    }

    /// The steps already in a block, for progress.
    static func confirmedCount(_ recovery: RecoverFundsResponse) -> Int {
        recovery.transactions.filter {
            if case .confirmed = $0.status {
                return true
            }
            return false
        }.count
    }

    /// UTXOs at the funding address that are new fee funding: neither a funding input yet nor an output any
    /// generation of the exit made there, a CPFP child's change or a fan-out's split of the funding.
    static func newFunding(_ utxos: [EsploraUtxo], record: SparkExitRecord) -> [EsploraUtxo] {
        let known = Set(record.funding.compactMap { funding in funding.txid.map { "\($0):\(funding.vout ?? 0)" } })
        let chained = Set((record.recovery.map { SparkExitTxid.chainedTxids($0.response) } ?? []) + (record.earlierCpfpTxids ?? []))
        return utxos.filter { !known.contains("\($0.txid):\($0.vout)") && !chained.contains($0.txid) }
    }

    /// The confirmed new funding, all of it, once it covers `requiredSats` together: the SDK spends every input it is
    /// given, so several small payments fund the exit as well as one. `requiredSats` assumes one payment; each
    /// further one adds its own input fee, `inputFeeSats`.
    static func fundingTopUp(_ newFunding: [EsploraUtxo], requiredSats: UInt64, inputFeeSats: UInt64 = 0) -> [EsploraUtxo]? {
        let confirmed = newFunding.filter(\.status.confirmed)
        let total = confirmed.reduce(0) { $0 + $1.value }
        let needed = requiredSats + inputFeeSats * UInt64(max(0, confirmed.count - 1))
        return !confirmed.isEmpty && total >= needed ? confirmed : nil
    }

    /// A signed P2WPKH input: each payment to the funding address is one more input for the build to pay for.
    static let inputVbytes: UInt64 = 68

    /// The fee one more funding input adds at the exit's rate (Glow `exitFee.ts`).
    static func inputFeeSats(_ record: SparkExitRecord) -> UInt64 {
        inputVbytes * record.feeRateSatPerVbyte
    }

    /// The funding total a rebuild asks for once the SDK refused it with `InsufficientCpfpFunds(requiredSats)`.
    /// `requiredSats` is what all the given inputs must hold together now, and what they hold now is the confirmed
    /// value at the funding address apart from new funding (spent inputs live on as chained CPFP change there).
    /// The phase counts against `fundedSats`, so the shortfall it shows is `requiredSats` less what the inputs hold.
    /// The SDK priced the inputs it had, so the payment still to come adds its own input fee.
    static func neededFunding(requiredSats: UInt64, record: SparkExitRecord, utxos: [EsploraUtxo]?) -> UInt64 {
        guard let utxos else { return max(requiredSats, record.fundedSats) + inputFeeSats(record) }
        let fresh = Set(newFunding(utxos, record: record).map { "\($0.txid):\($0.vout)" })
        let held = utxos.filter { $0.status.confirmed && !fresh.contains("\($0.txid):\($0.vout)") }.reduce(0) { $0 + $1.value }
        return record.fundedSats + max(requiredSats.saturatingSub(held), 1) + inputFeeSats(record)
    }

    /// The funding state while the exit lacks fee funding, nil once it lacks none. A payment Bitkit made from savings
    /// or one seen unconfirmed is waited for rather than asked for again; only what they leave short is asked for.
    static func fundingState(_ record: SparkExitRecord, utxos: [EsploraUtxo]?) -> SparkExitFundingState? {
        guard let shortfall = record.fundingShortfallSats else { return nil }
        // Paid until it confirms or the exit adopted it; adopted, a later rebuild may have spent it already.
        if let paid = record.fundingPaymentTxid, !record.funding.contains(where: { $0.txid == paid }),
           !(utxos ?? []).contains(where: { $0.txid == paid && $0.status.confirmed })
        {
            return .paid(txid: paid)
        }
        let fresh = utxos.map { newFunding($0, record: record) } ?? []
        let seenSats = fresh.reduce(0) { $0 + $1.value }
        let total = fundingTotal(shortfall: shortfall, payments: fresh.count, receivedSats: seenSats, inputFeeSats: inputFeeSats(record))
        // Covered by confirmed funding alone, the next tick builds.
        if seenSats >= total.covered, let pending = fresh.first(where: { !$0.status.confirmed }) ?? fresh.first {
            return .seen(txid: pending.txid)
        }
        return .ask(sats: max(total.toSend.saturatingSub(seenSats), fundingDustSats), receivedSats: seenSats)
    }

    /// The one rule both funding screens state: the funding is priced for one payment, and every payment beyond it,
    /// the one still to send included, adds its own input fee (68 vB at the exit's rate). `covered` is what the
    /// payments seen must hold to build; `toSend` the full total to ask for while they hold less, which the
    /// partial-payment hint names as its target. What is left to send is never asked under the 294-sat dust limit.
    static func fundingTotal(shortfall: UInt64, payments: Int, receivedSats: UInt64, inputFeeSats: UInt64) -> (covered: UInt64, toSend: UInt64) {
        let covered = shortfall + inputFeeSats * UInt64(max(0, payments - 1))
        return (covered, receivedSats >= covered || payments == 0 ? covered : covered + inputFeeSats)
    }

    /// The total the Progress top-up's partial hint names: `fundingTotal`'s `toSend` for what reached the address.
    static func fundingAskTotal(_ record: SparkExitRecord, utxos: [EsploraUtxo]?) -> UInt64? {
        guard let shortfall = record.fundingShortfallSats, let utxos else { return nil }
        let fresh = newFunding(utxos, record: record)
        return fundingTotal(
            shortfall: shortfall,
            payments: fresh.count,
            receivedSats: fresh.reduce(0) { $0 + $1.value },
            inputFeeSats: inputFeeSats(record)
        ).toSend
    }

    /// The least a P2WPKH funding output can hold: nodes refuse a payment below it.
    static let fundingDustSats: UInt64 = 294

    /// The lowest rate nodes relay.
    static let minRelayFeeRate: UInt64 = 1

    /// The leftover sweep's rate: the network's economy rate, never above the exit's own and never under the relay
    /// floor. Per-node funding leaves each step's change of at least 294 at the funding address; at the exit's rate
    /// the sweep can cost more per input than the input holds.
    static func sweepFeeRate(economy: UInt64?, exitRate: UInt64) -> UInt64 {
        max(minRelayFeeRate, min(economy ?? exitRate, exitRate))
    }

    /// The rate a sweep refused for its fee is built at next: what the node's minimum asks for (`min relay fee not
    /// met, 450 < 674` is the fee paid and the least it takes, at `paidRate`), and at least one sat/vB more.
    static func refusedSweepRate(_ refusal: String, paidRate: UInt64) -> UInt64 {
        let bumped = max(paidRate, minRelayFeeRate - 1) + 1
        guard let match = refusal.firstMatch(of: #/(?:min relay fee|mempool min fee) not met[^0-9]*(\d+)\s*<\s*(\d+)/#),
              let paid = UInt64(match.1), let least = UInt64(match.2), paid > 0
        else { return bumped }
        let leastRate = (least * max(paidRate, 1) + paid - 1) / paid
        return max(leastRate, bumped)
    }

    /// The UTXOs worth sending at `rate`: each holds more than the fee of its own input.
    static func economicalUtxos(_ utxos: [EsploraUtxo], rate: UInt64) -> [EsploraUtxo] {
        utxos.filter { $0.value > inputVbytes * rate }
    }

    /// What the exit says it still needs: the ask, or, while a payment is awaited or before the funding address was
    /// read, the shortfall. Never under the dust limit.
    static func neededSats(_ record: SparkExitRecord, state: SparkExitFundingState?) -> UInt64? {
        if case let .ask(sats, _) = state {
            return sats
        }
        return record.fundingShortfallSats.map { max($0, fundingDustSats) }
    }

    /// The fee funding the pre-start screen counts towards once `payments` reached the funding address: the quote's
    /// funding, priced for one payment, plus the input fee of each further one. `toSend` adds the input of the
    /// payment still to come while what arrived falls short, as the Progress top-up does.
    static func prestartFunding(fundingSats: UInt64, payments: Int, receivedSats: UInt64, feeRate: UInt64) -> (covered: UInt64, toSend: UInt64) {
        fundingTotal(shortfall: fundingSats, payments: payments, receivedSats: receivedSats, inputFeeSats: inputVbytes * feeRate)
    }

    /// What a partial payment leaves to send, at least the dust limit: nil before any new funding arrives and once
    /// it covers `requiredSats`.
    static func partialFundingSats(receivedSats: UInt64, requiredSats: UInt64) -> UInt64? {
        receivedSats > 0 && receivedSats < requiredSats ? max(requiredSats - receivedSats, fundingDustSats) : nil
    }

    /// The funding key index of a new exit: past the counter the last start left and every index the stored record
    /// used. Records from before per-exit indexes used 0.
    static func nextFundingIndex(counter: Int, record: SparkExitRecord?) -> UInt32 {
        let afterRecord = record?.funding.map(\.index).max().map { $0 + 1 } ?? 0
        return max(UInt32(clamping: max(0, counter)), afterRecord)
    }

    /// The Spark balance a quote cannot exit: the leaves it skips, and what the balance holds beyond every leaf the
    /// SDK lists, such as a counter-swap still unclaimed. Nil when there is none.
    static func unexitableSats(sparkBalanceSats: UInt64, quote: SparkExitQuote) -> UInt64? {
        let listed = quote.leafTotalSats + quote.leftBehindSats
        let beyond = beyondLostLeaves(sparkBalanceSats.saturatingSub(listed), lostLeafSats: quote.lostLeafSats)
        let unexitable = quote.leftBehindSats + beyond
        return unexitable > 0 ? unexitable : nil
    }

    /// `sats` less the lost leaves it still holds. Spark's balance keeps a leaf an older state claimed until a later
    /// sync drops it, so each lost leaf, largest first, is taken out only while what is left still covers it.
    static func beyondLostLeaves(_ sats: UInt64, lostLeafSats: [UInt64]) -> UInt64 {
        lostLeafSats.sorted(by: >).reduce(sats) { left, lost in left >= lost ? left - lost : left }
    }

    /// Whether the SDK refused a `Specific` selection because a leaf in it cannot be exited.
    static func isUnexitableLeafError(_ message: String) -> Bool {
        message.contains("cannot be exited")
    }

    /// The leaf an untyped "Leaf X cannot be exited: …" error names, if it names one.
    static func unexitableLeafId(_ message: String) -> String? {
        guard let match = message.firstMatch(of: #/Leaf ([^\s:]+) cannot be exited/#) else { return nil }
        return String(match.1)
    }

    /// What the Spark balance holds beyond the exit's leaves: value that reached Spark after the quote, such as a
    /// counter-swap claimed late, which this exit leaves on Spark. Nil when nothing is beyond them.
    static func outsideExitSats(sparkBalanceSats: UInt64, record: SparkExitRecord) -> UInt64? {
        guard record.isActive else { return nil }
        return staysOnSparkSats(sparkBalanceSats: sparkBalanceSats, record: record)
    }

    /// What the Spark balance holds beyond the exit's leaves, in any phase: what a failed exit leaves on Spark. Lost
    /// leaves count only while the balance still holds them (`beyondLostLeaves`).
    static func staysOnSparkSats(sparkBalanceSats: UInt64, record: SparkExitRecord) -> UInt64? {
        guard let leafTotal = record.leafTotalSats else { return nil }
        let liveLeafTotal = leafTotal.saturatingSub(record.lostSats)
        guard sparkBalanceSats > liveLeafTotal else { return nil }
        let stays = beyondLostLeaves(sparkBalanceSats - liveLeafTotal, lostLeafSats: (record.lostLeaves ?? []).map(\.valueSats))
        return stays > 0 ? stays : nil
    }

    /// About how long until `height`: 10-minute blocks, and Spark's regtest mines one every ~30 seconds.
    static func secondsUntil(height: UInt32, tip: UInt32, network: LDKNode.Network) -> TimeInterval {
        let blockSeconds: TimeInterval = network == .regtest ? 30 : 600
        return TimeInterval(BlockTimeHelpers.blocksRemaining(until: height, currentHeight: tip)) * blockSeconds
    }

    /// How far out to remind about a timelocked step when the tip could not be read, and about an exit whose steps
    /// wait for parents with no progress.
    static func reminderSeconds(network: LDKNode.Network) -> TimeInterval {
        network == .regtest ? 10 * 60 : 4 * 60 * 60
    }

    /// Savings can pay the fee funding when its spendable balance covers the funding and the payment's own fee.
    static func canFundFromSavings(spendableSats: UInt64, fundingSats: UInt64, paymentFeeSats: UInt64) -> Bool {
        fundingSats > 0 && spendableSats >= fundingSats.saturatingAdd(paymentFeeSats)
    }
}
