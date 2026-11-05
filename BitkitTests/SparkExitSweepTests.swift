@testable import Bitkit
import BreezSdkSpark
import CryptoKit
import secp256k1
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
    func testASweepRefusedForItsFeeIsRebuiltAtTheCurrentRate() async throws {
        chain.utxosByAddress[key.address] = [SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 5035)]
        chain.outcome = .rejected("min relay fee not met, 300 < 330")
        chain.fastestFee = 5

        var record = try await driver().tick(endedRecord())
        let refused = try XCTUnwrap(record.leftoverSweep)
        XCTAssertTrue(refused.isFeeRejection)
        XCTAssertTrue(record.needsDriving, "a fee refusal is not final")

        chain.outcome = .accepted
        record = try await driver().tick(record)

        let rebuilt = try XCTUnwrap(record.leftoverSweep)
        XCTAssertNotEqual(rebuilt.txid, refused.txid)
        XCTAssertEqual(rebuilt.feeRateSatPerVbyte, 5)
        XCTAssertEqual(rebuilt.valueSats, 5035 - SparkExitLeftoverSweep.feeSats(inputs: 1, outputScriptLength: 22, feeRateSatPerVbyte: 5))
        XCTAssertTrue(rebuilt.isAccepted)
        XCTAssertNil(rebuilt.rejection)
        XCTAssertEqual(rebuilt.sentAtHeight, 1000)
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
}

private extension Data {
    init(hex: String) {
        self.init(hex.hexaBytes)
    }
}
