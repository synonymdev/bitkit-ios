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

    /// The on-chain payment that funds the CPFP fees, or 0 when every leaf is recovered cooperatively.
    var fundingSats: UInt64 {
        prepared.funding?.singleUtxoSats ?? 0
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

/// A local notification that brings the user back to an exit; `id` is stable across runs for the same step.
struct SparkExitReminder: Equatable {
    let id: String
    let fireAt: Date
    var isFunding = false
    var isLostLeaves = false
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
    /// The countdown target: the latest block at which a timelocked step of the exit can confirm.
    static func claimableAtHeight(_ recovery: RecoverFundsResponse) -> UInt32? {
        recovery.transactions.compactMap { tx -> UInt32? in
            if case let .waitingForTimelock(height) = tx.status {
                return height
            }
            return nil
        }.max()
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
    /// reminds at once. A step published or confirmed needs none, so a background run that publishes a step drops
    /// its reminder before it fires.
    static func reminders(_ record: SparkExitRecord, tip: UInt32?, now: Date, network: LDKNode.Network) -> [SparkExitReminder] {
        let lost = record.lostLeaves ?? []
        let lostReminder = lost.isEmpty ? [] : [SparkExitReminder(id: "lost-\(lost.count)", fireAt: now, isLostLeaves: true)]
        if case let .needsFunding(requiredSats) = record.phase {
            return lostReminder + [SparkExitReminder(id: "funding-\(requiredSats)", fireAt: now, isFunding: true)]
        }
        guard case .running = record.phase, let recovery = record.recovery?.response else { return lostReminder }
        var reminders = lostReminder
        let generation = record.generation
        if let rejected = record.broadcastLog.first(where: {
            $0.generation == generation && $0.rejections >= SparkExitDriver.rejectionsToSurface && !$0.isAccepted
        }) {
            reminders.append(SparkExitReminder(id: "rejected-\(generation)-\(rejected.txid)", fireAt: now))
        }
        let accepted = Set(record.broadcastLog.filter { $0.generation == generation && $0.isAccepted }.map(\.txid))
        let blockSeconds = secondsUntil(height: 1, tip: 0, network: network)
        let grace = TimeInterval(reminderGraceBlocks) * blockSeconds
        var heights = Set<UInt32>()
        var readyTxid: String?
        for tx in recovery.transactions where !accepted.contains(tx.txid) {
            switch tx.status {
            case let .waitingForTimelock(height?):
                heights.insert(height)
            case .ready, .unverified:
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

    /// UTXOs at the funding address that are new fee funding: neither a funding input yet nor CPFP change any
    /// generation of the exit chained there.
    static func newFunding(_ utxos: [EsploraUtxo], record: SparkExitRecord) -> [EsploraUtxo] {
        let known = Set(record.funding.compactMap { funding in funding.txid.map { "\($0):\(funding.vout ?? 0)" } })
        let chained = Set((record.recovery.map { SparkExitTxid.cpfpChildTxids($0.response) } ?? []) + (record.earlierCpfpTxids ?? []))
        return utxos.filter { !known.contains("\($0.txid):\($0.vout)") && !chained.contains($0.txid) }
    }

    /// The confirmed new funding, all of it, once it covers `requiredSats` together: the SDK spends every input it is
    /// given, so several small payments fund the exit as well as one.
    static func fundingTopUp(_ newFunding: [EsploraUtxo], requiredSats: UInt64) -> [EsploraUtxo]? {
        let confirmed = newFunding.filter(\.status.confirmed)
        let total = confirmed.reduce(0) { $0 + $1.value }
        return !confirmed.isEmpty && total >= requiredSats ? confirmed : nil
    }

    /// The funding total a rebuild asks for once the SDK refused it with `InsufficientCpfpFunds(requiredSats)`.
    /// `requiredSats` is what all the given inputs must hold together now, and what they hold now is the confirmed
    /// value at the funding address apart from new funding (spent inputs live on as chained CPFP change there).
    /// The phase counts against `fundedSats`, so the shortfall it shows is `requiredSats` less what the inputs hold.
    static func neededFunding(requiredSats: UInt64, record: SparkExitRecord, utxos: [EsploraUtxo]?) -> UInt64 {
        guard let utxos else { return max(requiredSats, record.fundedSats) }
        let fresh = Set(newFunding(utxos, record: record).map { "\($0.txid):\($0.vout)" })
        let held = utxos.filter { $0.status.confirmed && !fresh.contains("\($0.txid):\($0.vout)") }.reduce(0) { $0 + $1.value }
        return record.fundedSats + max(requiredSats.saturatingSub(held), 1)
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
        // Covered by confirmed funding alone, the next tick builds.
        if seenSats >= shortfall, let pending = fresh.first(where: { !$0.status.confirmed }) ?? fresh.first {
            return .seen(txid: pending.txid)
        }
        return .ask(sats: shortfall.saturatingSub(seenSats), receivedSats: seenSats)
    }

    /// What a partial payment leaves to send: nil before any new funding arrives and once it covers `requiredSats`.
    static func partialFundingSats(receivedSats: UInt64, requiredSats: UInt64) -> UInt64? {
        receivedSats > 0 && receivedSats < requiredSats ? requiredSats - receivedSats : nil
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
        let unexitable = quote.leftBehindSats + sparkBalanceSats.saturatingSub(listed)
        return unexitable > 0 ? unexitable : nil
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
        guard record.isActive, let leafTotal = record.leafTotalSats, sparkBalanceSats > leafTotal else { return nil }
        return sparkBalanceSats - leafTotal
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
