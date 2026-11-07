@testable import Bitkit
import BreezSdkSpark
import CryptoKit
import libsecp256k1
import XCTest

final class SparkExitSweepTests: XCTestCase {
    private static let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    private var key: SparkExitFundingKey.Derived!
    private var destination: String!
    private var chain: FakeSparkExitChain!
    private var saved: [SparkExitRecord] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        key = try SparkExitFundingKey.derive(index: 0, mnemonic: Self.mnemonic, passphrase: nil, network: .regtest)
        destination = try SparkExitFundingKey.derive(index: 1, mnemonic: Self.mnemonic, passphrase: nil, network: .regtest).address
        chain = FakeSparkExitChain()
        saved = []
    }

    private func signer() throws -> CpfpSigner {
        try singleKeyCpfpSigner(secretKeyBytes: key.secretKey)
    }

    private func driver() -> SparkExitDriver {
        SparkExitDriver(
            chain: chain,
            recovering: nil,
            makeSigner: { [unowned self] _ in try signer() },
            save: { [unowned self] in saved.append($0) }
        )
    }

    private func endedRecord(phase: SparkExitRecord.Phase = .done) -> SparkExitRecord {
        SparkExitRecord(
            network: "regtest",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            phase: phase,
            feeRateSatPerVbyte: 2,
            destination: destination,
            leafIds: ["leaf-1"],
            funding: [.init(index: 0, address: key.address, pubkey: key.pubkey, txid: "f0", vout: 1, valueSats: 9000)],
            expectedSats: 90000,
            leftover: [.init(txid: String(repeating: "a", count: 64), vout: 0, valueSats: 5035)]
        )
    }

    // MARK: Building

    func testSignsEveryLeftoverInputForTheFundingKeyAndPaysSavingsLessTheFee() async throws {
        let utxos = [
            SparkExitFixtures.utxo(String(repeating: "a", count: 64), vout: 0, value: 5035),
            SparkExitFixtures.utxo(String(repeating: "b", count: 64), vout: 3, value: 1200),
        ]

        let sweep = try await SparkExitLeftoverSweep.build(
            utxos: utxos,
            fundingAddress: key.address,
            destination: destination,
            feeRateSatPerVbyte: 2,
            signer: signer()
        )
        let built = try XCTUnwrap(sweep)

        let fee = SparkExitLeftoverSweep.feeSats(inputs: 2, outputScriptLength: 22, feeRateSatPerVbyte: 2)
        XCTAssertEqual(fee, 2 * 178)
        XCTAssertEqual(built.valueSats, 6235 - fee)
        XCTAssertEqual(SparkExitTxid.txid(hex: built.txHex), built.txid)
        try assertValidP2wpkhSpend(built, utxos: utxos)
    }

    func testSkipsALeftoverThatIsDustAfterTheFee() async throws {
        let fee = SparkExitLeftoverSweep.feeSats(inputs: 1, outputScriptLength: 22, feeRateSatPerVbyte: 2)

        let dust = try await SparkExitLeftoverSweep.build(
            utxos: [SparkExitFixtures.utxo("aa", value: fee + 293)],
            fundingAddress: key.address,
            destination: destination,
            feeRateSatPerVbyte: 2,
            signer: signer()
        )
        let enough = try await SparkExitLeftoverSweep.build(
            utxos: [SparkExitFixtures.utxo(String(repeating: "c", count: 64), value: fee + 294)],
            fundingAddress: key.address,
            destination: destination,
            feeRateSatPerVbyte: 2,
            signer: signer()
        )

        XCTAssertNil(dust)
        XCTAssertEqual(enough?.valueSats, 294)
    }

    func testReadsTheOutputScriptOfEachAddressKind() throws {
        let cases = [
            "BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4": "0014751e76e8199196d454941c45d1b3a323f1433bd6",
            "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0":
                "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2": "76a91477bff20c60e522dfaa3350c39b030a5d004e839a88ac",
            "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy": "a914b472a266d0bd89c13706a4132ccfb16f7c3b9fcb87",
        ]
        for (address, script) in cases {
            XCTAssertEqual(try SparkExitAddress.scriptPubKey(address).hex, script, address)
        }
        XCTAssertEqual(SparkExitLeftoverSweep.dustLimit(Data(hex: "0014751e76e8199196d454941c45d1b3a323f1433bd6")), 294)
        XCTAssertEqual(SparkExitLeftoverSweep.dustLimit(Data(hex: "a914b472a266d0bd89c13706a4132ccfb16f7c3b9fcb87")), 540)
        // Bad checksum, and a version 0 program sent as bech32m.
        XCTAssertThrowsError(try SparkExitAddress.scriptPubKey("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5"))
        XCTAssertThrowsError(try SparkExitAddress.scriptPubKey("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kemeawh"))
    }

    // MARK: Driving

    func testAnEndedExitSweepsItsLeftoverToSavingsOnceANodeAcceptsIt() async throws {
        chain.utxosByAddress[key.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 5035)]
        chain.outcome = .retryLater("HTTP 503")

        var record = try await driver().tick(endedRecord())
        let sweepTxid = try XCTUnwrap(record.leftoverSweep?.txid)
        XCTAssertTrue(record.isLeftoverSweepPending)
        XCTAssertTrue(record.needsDriving)
        XCTAssertEqual(saved.first?.leftoverSweep?.txid, sweepTxid, "saved before it is sent")

        chain.outcome = .accepted
        record = try await driver().tick(record)
        XCTAssertEqual(record.leftoverSweep?.isAccepted, true)
        XCTAssertTrue(record.needsDriving, "driven until the sweep confirms")
        XCTAssertTrue(record.showsResult)

        chain.confirmedTxids = [sweepTxid]
        record = try await driver().tick(record)

        XCTAssertEqual(chain.broadcasts.map(\.txid), [sweepTxid, sweepTxid])
        XCTAssertEqual(record.leftoverSweep?.isConfirmed, true)
        XCTAssertFalse(record.needsDriving)
        XCTAssertFalse(record.showsResult, "a new exit may start")
        XCTAssertEqual(record.phase, .done)
    }

    /// qa-03: Done keeps the result reachable while the sweep is unconfirmed or refused, and sends an accepted sweep
    /// again until it confirms, in case a node dropped it.
    func testTheResultStaysReachableUntilTheSweepConfirms() async throws {
        chain.utxosByAddress[key.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 5035)]
        var record = try await driver().tick(endedRecord())
        XCTAssertEqual(record.leftoverSweep?.isAccepted, true)

        record = try await driver().tick(record)
        record = try await driver().tick(record)
        XCTAssertEqual(chain.broadcasts.count, 3)
        XCTAssertTrue(record.showsResult)

        var refused = endedRecord()
        refused.leftoverSweep = .init(txid: "t", txHex: "02", valueSats: 4000, rejection: "non-mandatory-script-verify-flag")
        XCTAssertFalse(refused.needsDriving)
        XCTAssertTrue(refused.showsResult, "the leftover waits at the funding address")

        var dust = endedRecord()
        dust.leftoverSweep = .init()
        XCTAssertFalse(dust.showsResult)
    }

    /// qa-03: after a Redo that needed no funding, 3,514 sats of generation 1's change in five UTXOs stayed at the
    /// funding address. Done sweeps them all in one transaction.
    func testDoneAfterARedoWithoutFundingSweepsEveryLeftoverOfTheFirstGeneration() async throws {
        var record = endedRecord(phase: .running)
        record.leftover = []
        let first = SparkExitFixtures.recovery([SparkExitFixtures.tx("n1", cpfp: "03c1")])
        record.adopt(first, at: .distantPast)
        let second = SparkExitFixtures.recovery([SparkExitFixtures.tx("s", kind: .sweep)])
        let sdk = FakeSparkExitRecovering()
        sdk.preparedResponse = SparkExitFixtures.prepared(funding: nil)
        sdk.builds = [second]
        sdk.checks = [
            CheckRecoverFundsResponse(recovery: first, verdict: .redo(reason: .onChainStateDiverged)),
            CheckRecoverFundsResponse(
                recovery: SparkExitFixtures.recovery([SparkExitFixtures.tx("s", kind: .sweep, status: .confirmed(blockHeight: 50))]),
                verdict: .done
            ),
        ]
        let utxos = [1200, 900, 700, 414, 300].enumerated().map { i, value in
            SparkExitFixtures.utxo(String(repeating: "\(i + 1)", count: 64), vout: UInt32(i), value: UInt64(value))
        }
        chain.utxosByAddress[key.address] = utxos
        let driver = SparkExitDriver(chain: chain, recovering: sdk, makeSigner: { [unowned self] _ in try signer() }, save: { _ in })

        record = try await driver.tick(record)
        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(sdk.recoverRequests.first?.fundingInputs, [])

        record = try await driver.tick(record)

        XCTAssertEqual(record.phase, .done)
        XCTAssertEqual(record.leftover.count, 5)
        let sweep = try XCTUnwrap(record.leftoverSweep)
        let fee = SparkExitLeftoverSweep.feeSats(inputs: 5, outputScriptLength: 22, feeRateSatPerVbyte: 2)
        XCTAssertEqual(sweep.valueSats, 3514 - fee)
        XCTAssertEqual(sweep.isAccepted, true)
        try assertValidP2wpkhSpend(.init(txid: XCTUnwrap(sweep.txid), txHex: XCTUnwrap(sweep.txHex), valueSats: sweep.valueSats), utxos: utxos)
        XCTAssertTrue(record.showsResult)
    }

    /// R7: a sweep refused for its fee is built again at the network's current rate; any other refusal is final.
    func testASweepRefusedForItsFeeIsRebuiltAtTheRateTheNodeTakes() async throws {
        chain.utxosByAddress[key.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 5035)]
        chain.outcome = .rejected("min relay fee not met, 300 < 330")
        chain.fastestFee = 5

        var record = try await driver().tick(endedRecord())
        let refused = try XCTUnwrap(record.leftoverSweep)
        XCTAssertTrue(refused.isWaitingForFees, "a fee refusal is not final")
        XCTAssertEqual(refused.refusedFeeRate, 3, "330 over the 300 paid at 2 sat/vB, and at least one more")
        XCTAssertTrue(record.needsDriving)

        chain.outcome = .accepted
        chain.tip = 1001
        record = try await driver().tick(record)

        let rebuilt = try XCTUnwrap(record.leftoverSweep)
        XCTAssertNotNil(rebuilt.txid)
        XCTAssertEqual(rebuilt.feeRateSatPerVbyte, 3)
        XCTAssertEqual(rebuilt.valueSats, 5035 - SparkExitLeftoverSweep.feeSats(inputs: 1, outputScriptLength: 22, feeRateSatPerVbyte: 3))
        XCTAssertTrue(rebuilt.isAccepted)
        XCTAssertNil(rebuilt.rejection)
        XCTAssertEqual(rebuilt.sentAtHeight, 1001)
    }

    /// R7: an accepted sweep still unconfirmed 144 blocks later is replaced (RBF) at a higher rate, at least one
    /// sat/vB over its own.
    func testAnUnconfirmedSweepIsReplacedAfter144Blocks() async throws {
        chain.utxosByAddress[key.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 5035)]
        chain.fastestFee = 1
        var record = try await driver().tick(endedRecord())
        let first = try XCTUnwrap(record.leftoverSweep)
        XCTAssertEqual(first.sentAtHeight, 1000)
        XCTAssertEqual(first.feeRateSatPerVbyte, 1, "the network's economy rate of 1, under the exit's 2")

        chain.tip = 1143
        record = try await driver().tick(record)
        XCTAssertEqual(record.leftoverSweep?.txid, first.txid)

        chain.tip = 1144
        record = try await driver().tick(record)
        let replacement = try XCTUnwrap(record.leftoverSweep)
        XCTAssertNotEqual(replacement.txid, first.txid)
        XCTAssertEqual(replacement.feeRateSatPerVbyte, 2, "the old rate of 1 plus one, over the network's 1")
        XCTAssertEqual(replacement.sentAtHeight, 1144)
        try assertValidP2wpkhSpend(
            .init(txid: XCTUnwrap(replacement.txid), txHex: XCTUnwrap(replacement.txHex), valueSats: replacement.valueSats),
            utxos: chain.utxosByAddress[key.address] ?? []
        )
    }

    /// R7: a replacement never loses the sweep it replaces. One that would be dust keeps the accepted sweep; the
    /// replaced sweep confirming ends it; a sweep the hosts no longer know counts as unconfirmed.
    func testAReplacementKeepsTrackOfTheSweepItReplaces() async throws {
        let utxo = SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 5035)
        chain.utxosByAddress[key.address] = [utxo]
        var record = try await driver().tick(endedRecord())
        let first = try XCTUnwrap(record.leftoverSweep?.txid)

        // The hosts dropped it: replaced, and the replacement remembers it.
        chain.droppedTxids = [first]
        chain.tip = 1144
        record = try await driver().tick(record)
        let second = try XCTUnwrap(record.leftoverSweep?.txid)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(record.leftoverSweep?.replacedTxids, [first])

        // The first one confirms after all: the sweep is done.
        chain.droppedTxids = []
        chain.confirmedTxids = [first]
        record = try await driver().tick(record)
        XCTAssertEqual(record.leftoverSweep?.isConfirmed, true)
        XCTAssertFalse(record.needsDriving)

        // A rate that would leave dust keeps the accepted sweep instead.
        var accepted = endedRecord()
        accepted.leftover = [.init(txid: utxo.txid, vout: 0, valueSats: 5035)]
        accepted.leftoverSweep = .init(txid: "s", txHex: "02", valueSats: 4800, isAccepted: true, feeRateSatPerVbyte: 2, sentAtHeight: 1000)
        chain.confirmedTxids = []
        chain.fastestFee = 50
        accepted = try await driver().tick(accepted)
        XCTAssertEqual(accepted.leftoverSweep?.txid, "s")
        XCTAssertTrue(accepted.needsDriving)
    }

    /// R11: the Done screen reads what the sweep paid to savings, and its txid.
    func testDoneShowsWhatReachedSavingsAndTheSweepTxid() throws {
        let script = try SparkExitAddress.scriptPubKey(destination)
        let hex = "02000000" + "01" + String(repeating: "11", count: 32) + "00000000" + "00" + "ffffffff"
            + "02" + "a086010000000000" + String(format: "%02x", script.count) + script.hex
            + "e803000000000000" + "16" + "0014" + String(repeating: "22", count: 20) + "00000000"
        var record = endedRecord()
        record.recovery = StoredRecovery(SparkExitFixtures.recovery([RecoveryTransaction(
            kind: .sweep,
            nodeId: nil,
            txid: "sweep-txid",
            txHex: hex,
            cpfpTxHex: nil,
            csvTimelockBlocks: nil,
            dependsOn: [],
            status: .confirmed(blockHeight: 50)
        )]))

        let received = try XCTUnwrap(SparkExitMath.received(record))
        XCTAssertEqual(received.sats, 100_000)
        XCTAssertEqual(received.sweepTxid, "sweep-txid")
        record.phase = .running
        XCTAssertNil(SparkExitMath.received(record))
    }

    /// A cooperative recovery that landed before a Redo still counts in what reached savings.
    func testDoneCountsWhatLandedBeforeARedo() throws {
        let script = try SparkExitAddress.scriptPubKey(destination)
        func paying(_ sats: String) -> String {
            "02000000" + "01" + String(repeating: "11", count: 32) + "00000000" + "00" + "ffffffff"
                + "01" + sats + String(format: "%02x", script.count) + script.hex + "00000000"
        }
        func tx(_ txid: String, _ kind: RecoveryTxKind, _ hex: String) -> RecoveryTransaction {
            RecoveryTransaction(kind: kind, nodeId: nil, txid: txid, txHex: hex, cpfpTxHex: nil, csvTimelockBlocks: nil, dependsOn: [],
                                status: .confirmed(blockHeight: 50))
        }
        var record = endedRecord(phase: .running)
        // 50,000 and 100,000 sats, little-endian.
        record.adopt(SparkExitFixtures.recovery([tx("coop", .cooperative, paying("50c3000000000000"))]))
        record.adopt(SparkExitFixtures.recovery([tx("sweep", .sweep, paying("a086010000000000"))]))
        record.phase = .done

        let received = try XCTUnwrap(SparkExitMath.received(record))
        XCTAssertEqual(received.sats, 150_000)
        XCTAssertEqual(received.sweepTxid, "sweep")
    }

    /// Each exit signs with the key at its own funding index, so a later exit never spends an earlier one's address.
    func testSignsWithTheKeyAtTheRecordsFundingIndex() async throws {
        let second = try SparkExitFundingKey.derive(index: 4, mnemonic: Self.mnemonic, passphrase: nil, network: .regtest)
        XCTAssertNotEqual(second.address, key.address)
        var record = endedRecord()
        record.funding = [.init(index: 4, address: second.address, pubkey: second.pubkey, txid: "f0", vout: 1, valueSats: 9000)]
        chain.utxosByAddress[second.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 5035)]
        var indexes: [UInt32] = []
        let driver = SparkExitDriver(chain: chain, recovering: nil, makeSigner: { index in
            indexes.append(index)
            return try singleKeyCpfpSigner(secretKeyBytes: second.secretKey)
        }, save: { _ in })

        record = try await driver.tick(record)

        XCTAssertEqual(indexes, [4])
        XCTAssertEqual(record.leftoverSweep?.isAccepted, true)
    }

    func testWaitsForTheLeftoverToConfirmAndLeavesDustAlone() async throws {
        chain.utxosByAddress[key.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 5035, confirmed: false)]

        var record = try await driver().tick(endedRecord())
        XCTAssertNil(record.leftoverSweep)
        XCTAssertTrue(chain.broadcasts.isEmpty)

        chain.utxosByAddress[key.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 400)]
        record = try await driver().tick(record)

        // Too small to send now: it waits for fees to drop instead of being kept at once.
        XCTAssertEqual(record.leftoverSweep?.waitingSince, 1000)
        XCTAssertTrue(record.leftoverSweep?.isWaitingForFees == true)
        XCTAssertTrue(record.needsDriving)
        XCTAssertTrue(chain.broadcasts.isEmpty)

        // A record from before the wait, with nothing sent and no wait, stays kept as dust.
        var legacy = endedRecord()
        legacy.leftoverSweep = SparkExitRecord.LeftoverSweep()
        XCTAssertFalse(legacy.needsDriving)
        XCTAssertFalse(legacy.showsResult, "dust is kept, and a new exit may start")
    }

    // MARK: Fee change at the economy rate

    func testTheSweepPaysTheEconomyRateNeverAboveTheExitsOrUnderTheRelayFloor() {
        XCTAssertEqual(SparkExitMath.sweepFeeRate(economy: 1, exitRate: 5), 1)
        XCTAssertEqual(SparkExitMath.sweepFeeRate(economy: 9, exitRate: 5), 5)
        XCTAssertEqual(SparkExitMath.sweepFeeRate(economy: 0, exitRate: 5), 1)
        XCTAssertEqual(SparkExitMath.sweepFeeRate(economy: nil, exitRate: 5), 5)
    }

    func testOnlyInputsWorthMoreThanTheirOwnFeeAreSwept() {
        let utxos = [
            SparkExitFixtures.utxo("a", value: 294),
            SparkExitFixtures.utxo("b", value: 341),
            SparkExitFixtures.utxo("c", value: 5000),
        ]
        // 68 vB at 5 sat/vB is 340.
        XCTAssertEqual(SparkExitMath.economicalUtxos(utxos, rate: 5).map(\.txid), ["b", "c"])
        XCTAssertEqual(SparkExitMath.economicalUtxos(utxos, rate: 1).count, 3)
    }

    /// Per-node change at 20 sat/vB: every 600-sat output costs more to spend than it holds. The sweep waits, checks
    /// the rate again after 144 blocks, and sends the change once the economy rate makes it worth it.
    func testChangeWaitsForFeesToDropThenSweepsAtTheEconomyRate() async throws {
        var record = endedRecord()
        record.feeRateSatPerVbyte = 20
        chain.economyFee = 20
        chain.utxosByAddress[key.address] = (0 ..< 3).map { SparkExitFixtures.utxo(String(repeating: "\($0 + 1)", count: 64), value: 600) }

        record = try await driver().tick(record)
        XCTAssertTrue(record.leftoverSweep?.isWaitingForFees == true)
        XCTAssertEqual(record.leftoverSweep?.checkedAtHeight, 1000)

        chain.economyFee = 1
        chain.tip = 1143
        record = try await driver().tick(record)
        XCTAssertTrue(record.leftoverSweep?.isWaitingForFees == true, "not checked again before 144 blocks")

        chain.tip = 1144
        record = try await driver().tick(record)
        let sweep = try XCTUnwrap(record.leftoverSweep)
        XCTAssertNotNil(sweep.txid)
        XCTAssertEqual(sweep.feeRateSatPerVbyte, 1)
        XCTAssertEqual(sweep.isAccepted, true)
        try assertValidP2wpkhSpend(
            .init(txid: XCTUnwrap(sweep.txid), txHex: XCTUnwrap(sweep.txHex), valueSats: sweep.valueSats),
            utxos: chain.utxosByAddress[key.address] ?? []
        )
    }

    /// Run E (case 6): six 294-sat change outputs, swept at 1 sat/vB, refused "min relay fee not met, 450 < 674". The
    /// sweep is not given up: it waits for the next block, then goes again at the rate the refusal asks for.
    func testAFeeChangeSweepRefusedForItsFeeIsRetriedAtTheRateTheNodeAsksFor() async throws {
        var record = endedRecord()
        record.leftover = (1 ... 6).map { SparkExitRecord.Leftover(txid: String(repeating: "\($0)", count: 64), vout: 0, valueSats: 294) }
        chain.economyFee = 1
        chain.utxosByAddress[key.address] = (1 ... 6).map { SparkExitFixtures.utxo(String(repeating: "\($0)", count: 64), value: 294) }
        chain.outcome = .rejected("min relay fee not met, 450 < 674")

        record = try await driver().tick(record)

        let waiting = try XCTUnwrap(record.leftoverSweep)
        XCTAssertNil(waiting.txid)
        XCTAssertNil(waiting.rejection, "a fee refusal is never final")
        XCTAssertTrue(waiting.isWaitingForFees)
        XCTAssertEqual(waiting.refusedFeeRate, 2, "674 sats over the 450 vB paid at 1 sat/vB")
        XCTAssertEqual(waiting.retryAtHeight, 1001)
        XCTAssertTrue(record.needsDriving, "launch and background runs keep trying")
        XCTAssertEqual(record.leftoverLine, .waiting(sats: 1764))
        XCTAssertEqual(chain.broadcasts.count, 1)

        record = try await driver().tick(record)
        XCTAssertEqual(chain.broadcasts.count, 1, "not again before the next block")

        chain.tip = 1001
        chain.outcome = .accepted
        record = try await driver().tick(record)

        let sweep = try XCTUnwrap(record.leftoverSweep)
        XCTAssertEqual(sweep.feeRateSatPerVbyte, 2)
        XCTAssertEqual(sweep.isAccepted, true)
        XCTAssertEqual(sweep.valueSats, 1764 - 900)
        XCTAssertEqual(sweep.waitingSince, 1000, "the 4-week bound still counts from the first wait")
        try assertValidP2wpkhSpend(
            .init(txid: XCTUnwrap(sweep.txid), txHex: XCTUnwrap(sweep.txHex), valueSats: sweep.valueSats),
            utxos: chain.utxosByAddress[key.address] ?? []
        )
    }

    /// A record from Run E's build, with the fee refusal stored as final, waits and retries on the next run too.
    func testAStoredFeeRefusalWaitsAndRetries() async throws {
        var record = endedRecord()
        record.leftover = (1 ... 6).map { SparkExitRecord.Leftover(txid: String(repeating: "\($0)", count: 64), vout: 0, valueSats: 294) }
        record.leftoverSweep = .init(
            txid: "d770cd89",
            txHex: "02",
            valueSats: 1314,
            rejection: "min relay fee not met, 450 < 674",
            feeRateSatPerVbyte: 1
        )
        chain.utxosByAddress[key.address] = (1 ... 6).map { SparkExitFixtures.utxo(String(repeating: "\($0)", count: 64), value: 294) }
        chain.economyFee = 1
        XCTAssertEqual(record.leftoverLine, .waiting(sats: 1764), "one line with the total, never one per output")

        record = try await driver().tick(record)
        XCTAssertEqual(record.leftoverSweep?.refusedFeeRate, 2)
        XCTAssertTrue(chain.broadcasts.isEmpty)

        chain.tip = 1001
        record = try await driver().tick(record)
        XCTAssertEqual(record.leftoverSweep?.feeRateSatPerVbyte, 2)
        XCTAssertEqual(record.leftoverSweep?.isAccepted, true)
    }

    /// Run F (case 6): the fee-change sweep went out at 2 sat/vB and was accepted, then the relay floor rose to 3 and
    /// evicted it. Its rebroadcast is refused "492 < 738": it waits, goes again at 3 from the next block (RBF), and the
    /// result never says it reached savings before it confirms.
    func testASweepEvictedFromTheMempoolIsRetriedAtTheNewFloor() async throws {
        var record = endedRecord()
        let utxos = (1 ... 3).map { SparkExitFixtures.utxo(String(repeating: "\($0)", count: 64), value: 600) }
        record.leftover = utxos.map { SparkExitRecord.Leftover(txid: $0.txid, vout: 0, valueSats: 600) }
        chain.utxosByAddress[key.address] = utxos
        chain.economyFee = 2

        record = try await driver().tick(record)
        let first = try XCTUnwrap(record.leftoverSweep)
        let firstTxid = try XCTUnwrap(first.txid)
        XCTAssertEqual(first.feeRateSatPerVbyte, 2)
        XCTAssertEqual(first.valueSats, 1800 - 492)
        XCTAssertTrue(first.isAccepted)
        XCTAssertEqual(record.leftoverLine, .sending(sats: 1308, txid: firstTxid), "accepted is not yet in savings")

        // Still in the mempool: a fee refusal from another node changes nothing.
        chain.mempoolTxids = [firstTxid]
        chain.outcome = .rejected("min relay fee not met, 492 < 738")
        record = try await driver().tick(record)
        XCTAssertEqual(record.leftoverSweep?.txid, firstTxid)

        // Evicted: no host holds it, and the rebroadcast is refused for its fee.
        chain.mempoolTxids = []
        record = try await driver().tick(record)
        let waiting = try XCTUnwrap(record.leftoverSweep)
        XCTAssertTrue(waiting.isWaitingForFees)
        XCTAssertEqual(waiting.refusedFeeRate, 3, "738 over the 492 paid at 2 sat/vB")
        XCTAssertEqual(waiting.retryAtHeight, 1001)
        XCTAssertEqual(waiting.replacedTxids, [firstTxid], "the evicted sweep confirming would still end it")
        XCTAssertEqual(record.leftoverLine, .waiting(sats: 1800))

        chain.tip = 1001
        chain.outcome = .accepted
        record = try await driver().tick(record)
        let retried = try XCTUnwrap(record.leftoverSweep)
        let retriedTxid = try XCTUnwrap(retried.txid)
        XCTAssertNotEqual(retriedTxid, firstTxid)
        XCTAssertEqual(retried.feeRateSatPerVbyte, 3)
        XCTAssertEqual(retried.valueSats, 1800 - 738)
        XCTAssertEqual(record.leftoverLine, .sending(sats: 1062, txid: retriedTxid))

        chain.confirmedTxids = [retriedTxid]
        record = try await driver().tick(record)
        XCTAssertEqual(record.leftoverLine, .swept(sats: 1062, txid: retriedTxid))
        XCTAssertFalse(record.needsDriving)
    }

    func testTheRefusedRateFollowsTheNodesMinimum() {
        XCTAssertEqual(SparkExitMath.refusedSweepRate("min relay fee not met, 450 < 674", paidRate: 1), 2)
        XCTAssertEqual(SparkExitMath.refusedSweepRate("mempool min fee not met, 900 < 2700", paidRate: 2), 6)
        XCTAssertEqual(SparkExitMath.refusedSweepRate("insufficient fee", paidRate: 3), 4, "no numbers: one sat/vB more")
    }

    /// The result names the leftover once, with its total, whatever state it is in.
    func testTheLeftoverIsOneLineWithTheTotal() {
        var record = endedRecord()
        record.leftover = (1 ... 6).map { SparkExitRecord.Leftover(txid: "u\($0)", vout: 0, valueSats: 294) }
        XCTAssertEqual(record.leftoverLine, .stillAt(sats: 1764))
        record.leftoverSweep = .init(waitingSince: 1000, checkedAtHeight: 1000)
        XCTAssertEqual(record.leftoverLine, .waiting(sats: 1764))
        record.leftoverSweep?.isDustKept = true
        XCTAssertEqual(record.leftoverLine, .kept(sats: 1764))
        record.leftoverSweep = .init(txid: "t", txHex: "02", valueSats: 4000, rejection: "non-mandatory-script-verify-flag")
        XCTAssertEqual(record.leftoverLine, .rejected(sats: 1764))
    }

    /// The local regtest mempool answers `{}`: every rate falls back, never failing the step.
    func testFeeEstimatesFallBackToTheNextTargetThenTheRelayFloor() {
        XCTAssertEqual(SparkExitFeeEstimates.rate([:], target: 1), 1)
        XCTAssertEqual(SparkExitFeeEstimates.economy([:]), 1)
        let sparse = ["2": 7.2, "6": 3.0, "144": 1.4]
        XCTAssertEqual(SparkExitFeeEstimates.rate(sparse, target: 1), 8, "the next target up, rounded up")
        XCTAssertEqual(SparkExitFeeEstimates.rate(sparse, target: 3), 3)
        XCTAssertEqual(SparkExitFeeEstimates.rate(sparse, target: 1008), 2, "none longer: the longest there is")
        XCTAssertEqual(SparkExitFeeEstimates.economy(sparse), 2)
        XCTAssertEqual(SparkExitFeeEstimates.rate(["1": 0.2], target: 1), 1)
    }

    func testAnEmptyEstimateMapStillPricesEveryStep() async throws {
        let http = SparkExitBroadcasterTests.FakeHTTP()
        http.responses = [("a.example/api/fee-estimates", 200, "{}"), ("a.example/api/fee-estimates", 200, "{}")]
        let chain = try EsploraSparkExitChain(hosts: [XCTUnwrap(URL(string: "https://a.example/api"))], http: http)

        let fees = try await chain.networkFees()
        let fastest = try await chain.fastestFeeRate()

        XCTAssertEqual(fees, SparkExitNetworkFees(fastest: 1, halfHour: 1, economy: 1))
        XCTAssertEqual(fastest, 1)
        XCTAssertEqual(SparkExitFeeBumpOption.options(exitRate: 2, fees: fees).map(\.rate), [3], "a bump still offers a higher rate")
    }

    /// After about four weeks (4,032 blocks) the change stays at the funding address and the exit is let go.
    func testChangeTooSmallForFourWeeksIsKept() async throws {
        var record = endedRecord()
        record.feeRateSatPerVbyte = 20
        chain.economyFee = 20
        chain.utxosByAddress[key.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 600)]
        record = try await driver().tick(record)
        XCTAssertTrue(record.needsDriving)
        XCTAssertTrue(record.showsResult)

        chain.tip = 1000 + SparkExitDriver.sweepWaitBlocks
        record = try await driver().tick(record)

        XCTAssertEqual(record.leftoverSweep?.isDustKept, true)
        XCTAssertFalse(record.isLeftoverSweepPending)
        XCTAssertFalse(record.needsDriving)
        XCTAssertTrue(chain.broadcasts.isEmpty)
        XCTAssertTrue(t("lightning__spark_exit__leftover_waiting", variables: ["amount": "₿ 600"]).contains("when network fees drop"))
        XCTAssertTrue(t("lightning__spark_exit__leftover_dust", variables: ["amount": "₿ 600", "address": "a", "path": "m/84'"])
            .contains("derivation path m/84'"))
    }

    func testFinishingAnExitSweepsTheLeftoverInTheSameTick() async throws {
        var record = endedRecord(phase: .running)
        record.leftover = []
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("s", kind: .sweep)]))
        let done = SparkExitFixtures.recovery([SparkExitFixtures.tx("s", kind: .sweep, status: .confirmed(blockHeight: 50))])
        let sdk = FakeSparkExitRecovering()
        sdk.checks = [CheckRecoverFundsResponse(recovery: done, verdict: .done)]
        chain.utxosByAddress[key.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 5035)]
        let driver = SparkExitDriver(chain: chain, recovering: sdk, makeSigner: { [unowned self] _ in try signer() }, save: { _ in })

        record = try await driver.tick(record)

        XCTAssertEqual(record.phase, .done)
        XCTAssertEqual(record.leftoverSweep?.isAccepted, true)
        XCTAssertEqual(chain.broadcasts.map(\.txid), [record.leftoverSweep?.txid])
    }

    func testABackgroundRunSweepsAnEndedExitWithoutStartingSpark() async throws {
        let store = SparkExitStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("spark-exit-\(UUID().uuidString)/spark-exit.json"))
        defer { try? store.delete() }
        try store.save(endedRecord())
        chain.utxosByAddress[key.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 5035)]
        var connects = 0
        let run = SparkExitBackgroundRun(
            load: { try store.load() },
            makeDriver: { [unowned self] chain, recovering in
                SparkExitDriver(chain: chain, recovering: recovering, makeSigner: { _ in try self.signer() }, save: { try store.save($0) })
            },
            chain: chain,
            connected: nil,
            connect: { _ in
                connects += 1
                return nil
            },
            deadline: Date(timeIntervalSinceNow: 25)
        )

        let outcome = await run.run()

        XCTAssertEqual(connects, 0)
        XCTAssertEqual(outcome.record?.leftoverSweep?.isAccepted, true)
        XCTAssertEqual(try store.load()?.leftoverSweep?.isAccepted, true)
    }

    // MARK: Signature check

    /// Checks each input's witness is a valid BIP143 signature by the funding key over the sweep.
    private func assertValidP2wpkhSpend(_ built: SparkExitLeftoverSweep.Built, utxos: [EsploraUtxo]) throws {
        let tx = [UInt8](Data(hex: built.txHex))
        let outputScript = try [UInt8](SparkExitAddress.scriptPubKey(destination))
        let pubkeyHash = try [UInt8](SparkExitAddress.scriptPubKey(key.address))[2...]
        let outpoints = utxos.map { [UInt8]($0.txid.hexaBytes.reversed()) + le32($0.vout) }
        let sequence = le32(0xFFFF_FFFD)
        let outputs = le64(built.valueSats) + [UInt8(outputScript.count)] + outputScript
        var offset = 4 + 2 + 1 + 41 * utxos.count + 1 + outputs.count
        XCTAssertEqual(Array(tx[(offset - outputs.count) ..< offset]), outputs)

        let context = try XCTUnwrap(secp256k1_context_create(UInt32(SECP256K1_CONTEXT_VERIFY)))
        defer { secp256k1_context_destroy(context) }
        var pubkey = secp256k1_pubkey()
        let pubkeyBytes = key.pubkey.hexaBytes
        XCTAssertEqual(secp256k1_ec_pubkey_parse(context, &pubkey, pubkeyBytes, pubkeyBytes.count), 1)

        for (i, utxo) in utxos.enumerated() {
            XCTAssertEqual(tx[offset], 2)
            let signatureLength = Int(tx[offset + 1])
            let signature = Array(tx[(offset + 2) ..< (offset + 2 + signatureLength)])
            offset += 2 + signatureLength
            XCTAssertEqual(Array(tx[(offset + 1) ..< (offset + 34)]), pubkeyBytes)
            offset += 34
            XCTAssertEqual(signature.last, 0x01, "SIGHASH_ALL")

            let preimage = le32(2) + dsha(outpoints.flatMap { $0 }) + dsha(Array(repeating: sequence, count: utxos.count).flatMap { $0 })
                + outpoints[i] + [0x19, 0x76, 0xA9, 0x14] + pubkeyHash + [0x88, 0xAC] + le64(utxo.value) + sequence
                + dsha(outputs) + le32(0) + le32(1)
            let digest = dsha(preimage)
            var parsed = secp256k1_ecdsa_signature()
            let der = Array(signature.dropLast())
            XCTAssertEqual(secp256k1_ecdsa_signature_parse_der(context, &parsed, der, der.count), 1)
            XCTAssertEqual(secp256k1_ecdsa_verify(context, &parsed, digest, &pubkey), 1, "input \(i)")
        }
        XCTAssertEqual(Array(tx[offset...]), le32(0))
    }

    private func dsha(_ bytes: [UInt8]) -> [UInt8] {
        [UInt8](Data(SHA256.hash(data: Data(SHA256.hash(data: Data(bytes))))))
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { [UInt8]($0) }
    }

    private func le64(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { [UInt8]($0) }
    }

    // MARK: Home balances

    /// The exit's own transfer counts what is still to come: a planned sweep counts only once it confirmed.
    func testInTransferCountsOnlyWhatConfirmedToSavings() throws {
        let script = try SparkExitAddress.scriptPubKey(destination)
        // Pays 50,000 sats to savings, little-endian.
        let hex = "02000000" + "01" + String(repeating: "11", count: 32) + "00000000" + "00" + "ffffffff"
            + "01" + "50c3000000000000" + String(format: "%02x", script.count) + script.hex + "00000000"
        func sweep(_ status: ExitTransactionStatus) -> RecoveryTransaction {
            RecoveryTransaction(kind: .sweep, nodeId: nil, txid: "sweep", txHex: hex, cpfpTxHex: nil, csvTimelockBlocks: nil,
                                dependsOn: [], status: status)
        }
        var record = endedRecord(phase: .running)
        record.recovery = StoredRecovery(SparkExitFixtures.recovery([sweep(.waitingForTimelock(spendableAtHeight: 900))]))
        XCTAssertEqual(SparkExitMath.inTransferSats(record, fundingSeenSats: 0), 90000)

        record.recovery = StoredRecovery(SparkExitFixtures.recovery([sweep(.confirmed(blockHeight: 50))]))
        XCTAssertEqual(SparkExitMath.inTransferSats(record, fundingSeenSats: 0), 40000)
        record.earlierReceivedSats = ["coop": 30000]
        XCTAssertEqual(SparkExitMath.inTransferSats(record, fundingSeenSats: 0), 10000)
    }

    /// The first fee funding nobody paid yet is not in transfer; once paid, or once the exit pays it, it is.
    func testInTransferLeavesOutUnpaidFirstFunding() {
        var record = endedRecord(phase: .awaitingFunding(requiredSats: 20000))
        record.funding = [.init(index: 0, address: key.address, pubkey: key.pubkey)]
        XCTAssertEqual(SparkExitMath.inTransferSats(record, fundingSeenSats: 0), 70000)
        XCTAssertEqual(SparkExitMath.inTransferSats(record, fundingSeenSats: 5000), 75000)
        XCTAssertEqual(SparkExitMath.inTransferSats(record, fundingSeenSats: 20000), 90000)

        record.fundingPaymentTxid = "paid"
        XCTAssertEqual(SparkExitMath.inTransferSats(record, fundingSeenSats: 0), 90000)
        record.fundingPaymentTxid = nil
        record.phase = .running
        XCTAssertEqual(SparkExitMath.inTransferSats(record, fundingSeenSats: 0), 90000)
    }

    /// Only the running exit's own transfer swaps its amount; any other exit transfer keeps it.
    func testOnlyTheExitsOwnTransferCountsItsInTransferAmount() {
        let own = Bitkit.Transfer(id: "own", type: .sparkExit, amountSats: 90000, createdAt: 0)
        let other = Bitkit.Transfer(id: "other", type: .sparkExit, amountSats: 12000, createdAt: 0)

        XCTAssertEqual(BalanceManager.sparkExitInTransferSats(own, exitInTransfer: ("own", 40000)), 40000)
        XCTAssertEqual(BalanceManager.sparkExitInTransferSats(other, exitInTransfer: ("own", 40000)), 12000)
        XCTAssertEqual(BalanceManager.sparkExitInTransferSats(own, exitInTransfer: nil), 90000)
    }

    /// While an exit runs, Spending keeps what Spark holds beyond the exit's leaves.
    func testSpendingKeepsSparkValueOutsideTheExit() {
        XCTAssertEqual(WalletViewModel.spendingSparkSats(isExiting: false, balanceSats: 50000, outsideExitSats: nil), 50000)
        XCTAssertEqual(WalletViewModel.spendingSparkSats(isExiting: true, balanceSats: 50000, outsideExitSats: 32768), 32768)
        XCTAssertEqual(WalletViewModel.spendingSparkSats(isExiting: true, balanceSats: 50000, outsideExitSats: nil), 0)
    }

    /// A start goes on only with its own exit still stored and active: one cancelled while it waited stops it.
    func testStartGoesOnOnlyWithItsExitStillRunning() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        let record = SparkExitRecord(
            network: "regtest",
            createdAt: createdAt,
            phase: .awaitingFunding(requiredSats: 20000),
            feeRateSatPerVbyte: 2,
            destination: destination,
            leafIds: ["leaf-1"],
            funding: [.init(index: 0, address: key.address, pubkey: key.pubkey)],
            expectedSats: 90000
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spark-exit-start-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SparkExitStore(url: url)
        try store.save(record)
        let stored = try XCTUnwrap(store.load())

        XCTAssertNotNil(SparkExitManager.startedExit(stored: stored, createdAt: createdAt))
        XCTAssertNil(SparkExitManager.startedExit(stored: nil, createdAt: createdAt))
        XCTAssertNil(SparkExitManager.startedExit(stored: stored, createdAt: createdAt.addingTimeInterval(1)))
        var cancelled = stored
        cancelled.phase = .done
        XCTAssertNil(SparkExitManager.startedExit(stored: cancelled, createdAt: createdAt))
    }
}

private extension Data {
    init(hex: String) {
        self.init(hex.hexaBytes)
    }
}
