@testable import Bitkit
import BreezSdkSpark
import XCTest

/// Findings of the independent review of the exit: cancel, heights without a tip, funding waits, reminders, sweep
/// bounds and salvage.
final class SparkExitReviewTests: XCTestCase {
    private var chain: FakeSparkExitChain!
    private var sdk: FakeSparkExitRecovering!
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        chain = FakeSparkExitChain()
        sdk = FakeSparkExitRecovering()
    }

    private func driver(withSdk: Bool = true) -> SparkExitDriver {
        SparkExitDriver(chain: chain, recovering: withSdk ? sdk : nil, makeSigner: { _ in StubCpfpSigner() }, save: { _ in })
    }

    // MARK: H1 cancel

    func testCancelIsOffAfterAPaymentFromSavings() {
        var record = SparkExitFixtures.record()
        XCTAssertTrue(SparkExitManager.canCancel(record, fundingSeenSats: 0))
        XCTAssertFalse(SparkExitManager.canCancel(record, fundingSeenSats: 1000), "a payment was seen")
        record.fundingPaymentTxid = "paid"
        XCTAssertFalse(SparkExitManager.canCancel(record, fundingSeenSats: 0), "paid from savings, not seen yet")
    }

    /// Cancel reads the address first: funding that arrived since the last tick goes back to savings, and an address
    /// that cannot be read keeps the exit.
    func testCancelNeverOrphansFundingAtTheAddress() {
        XCTAssertEqual(SparkExitManager.cancelOutcome(utxos: []), .forget)
        XCTAssertEqual(SparkExitManager.cancelOutcome(utxos: nil), .keep)
        XCTAssertEqual(
            SparkExitManager.cancelOutcome(utxos: [SparkExitFixtures.utxo("late", value: 5000, confirmed: false)]),
            .sweepFunding([.init(txid: "late", vout: 0, valueSats: 5000)])
        )
    }

    /// A cancelled exit with funding sweeps it like any ended exit's leftover, and posts no "stopped" notification.
    func testACancelledExitSweepsItsFundingAndPostsNoFailure() {
        var record = SparkExitFixtures.record()
        record.phase = .failed(reason: SparkExitRecord.cancelledReason)
        record.isCancelled = true
        record.isResultSeen = true
        record.leftover = [.init(txid: "late", vout: 0, valueSats: 5000)]

        XCTAssertTrue(record.isLeftoverSweepPending)
        XCTAssertTrue(record.showsResult)
        XCTAssertTrue(SparkExitMath.reminders(record, tip: 1000, now: clock, network: .regtest).isEmpty)
    }

    // MARK: H2 no height without a tip

    /// A tip read that fails while the sweep would wait writes no height, so the next tick does not read a 0 as four
    /// weeks gone and keep the change.
    func testASweepWithoutATipWritesNoHeightAndKeepsNothing() async throws {
        var record = SparkExitFixtures.record(phase: .done)
        record.feeRateSatPerVbyte = 20
        record.leftover = [.init(txid: "c1", vout: 0, valueSats: 300)]
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("c1", value: 300)]
        chain.isTipUnreadable = true

        record = try await driver().tick(record)
        XCTAssertNil(record.leftoverSweep, "nothing changes without the tip")

        chain.isTipUnreadable = false
        chain.economyFee = 20
        record = try await driver().tick(record)
        XCTAssertEqual(record.leftoverSweep?.waitingSince, 1000)

        chain.isTipUnreadable = true
        chain.tip = 900_000
        record = try await driver().tick(record)
        XCTAssertNotEqual(record.leftoverSweep?.isDustKept, true)
        XCTAssertTrue(record.isLeftoverSweepPending)
    }

    // MARK: H3 driving while a top-up is awaited

    private func bumpedRecord() -> SparkExitRecord {
        var record = SparkExitFixtures.record(phase: .running)
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 990)),
            SparkExitFixtures.tx("n2", cpfp: "03c2", dependsOn: ["n1"]),
        ]), at: .distantPast)
        record.applyFeeBump(rate: 10, extraSats: 5680, paymentTxid: "bump")
        return record
    }

    func testTheLiveGenerationKeepsGoingWhileAHigherFeesTopUpIsAwaited() async throws {
        var record = bumpedRecord()
        chain.mempoolTxids = ["bump"]
        sdk.checks = try [CheckRecoverFundsResponse(recovery: XCTUnwrap(record.recovery?.response), verdict: .valid)]

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .needsFunding(requiredSats: 25680))
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n2"], "the ready step still goes out")
        XCTAssertTrue(sdk.recoverRequests.isEmpty, "no rebuild before the top-up confirms")
        let reminders = SparkExitMath.reminders(record, tip: 1000, now: clock, network: .regtest)
        XCTAssertFalse(reminders.contains { $0.isFunding }, "the payment is on its way")
        XCTAssertTrue(reminders.contains { $0.id.hasPrefix("1-") }, "the live steps keep their reminders")
    }

    /// A payment no host knows for a block is forgotten: the ask and the funding reminder come back.
    func testADroppedSavingsPaymentBringsTheAskBack() async throws {
        var record = bumpedRecord()
        sdk.checks = try Array(repeating: CheckRecoverFundsResponse(recovery: XCTUnwrap(record.recovery?.response), verdict: .valid), count: 3)

        record = try await driver().tick(record)
        XCTAssertEqual(record.fundingPaymentMissingSince, 1000)
        XCTAssertEqual(record.fundingPaymentTxid, "bump", "one read is not enough")

        chain.tip = 1001
        record = try await driver().tick(record)
        XCTAssertNil(record.fundingPaymentTxid)
        XCTAssertFalse(record.isAwaitingOwnPayment)
        XCTAssertTrue(SparkExitMath.reminders(record, tip: 1001, now: clock, network: .regtest).contains { $0.isFunding })
    }

    /// One still unadopted after a day is forgotten too, known or not.
    func testASavingsPaymentNotAdoptedInADayIsForgotten() async throws {
        var record = bumpedRecord()
        chain.mempoolTxids = ["bump"]
        sdk.checks = try Array(repeating: CheckRecoverFundsResponse(recovery: XCTUnwrap(record.recovery?.response), verdict: .valid), count: 2)
        record = try await driver().tick(record)
        XCTAssertEqual(record.fundingPaymentSeenAtHeight, 1000)

        chain.tip = 1000 + SparkExitDriver.ownPaymentTimeoutBlocks
        record = try await driver().tick(record)
        XCTAssertNil(record.fundingPaymentTxid)
    }

    /// A short rebuild after a Redo stays parked: its generation diverged and is never sent again.
    func testADivergedRebuildsTopUpSendsNothing() async throws {
        var record = bumpedRecord()
        record.isRebuilding = true
        chain.mempoolTxids = ["bump"]

        record = try await driver().tick(record)

        XCTAssertTrue(chain.broadcasts.isEmpty)
        XCTAssertTrue(sdk.checkedRecoveries.isEmpty)
    }

    // MARK: M2 snapshot before pricing and the failed-leaf retry

    func testFeeBumpPricingImportsTheExitDataSnapshotFirst() async throws {
        var record = bumpedRecord()
        record.phase = .running
        record.exitStateSnapshot = "snapshot-1"
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n2b")])]

        _ = try await driver().feeBumpShortfall(record, rate: 12)

        XCTAssertEqual(sdk.imports, ["snapshot-1"])
    }

    // MARK: M4 a started exit never funded

    func testAnExitNeverFundedReminds() {
        let record = SparkExitFixtures.record()
        let reminders = SparkExitMath.reminders(record, tip: 1000, now: record.createdAt, network: .regtest)
        XCTAssertEqual(reminders.map(\.id), ["await-funding-20000"])
        XCTAssertEqual(reminders.first?.isFunding, true)
        XCTAssertEqual(reminders.first?.fireAt, record.createdAt.addingTimeInterval(SparkExitMath.reminderSeconds(network: .regtest)))

        var paid = record
        paid.fundingPaymentTxid = "paid"
        XCTAssertTrue(SparkExitMath.reminders(paid, tip: 1000, now: record.createdAt, network: .regtest).isEmpty)
    }

    // MARK: M3 fired reminders

    func testAFiredReminderStaysRememberedWhenItLeavesThePlanForARun() {
        let now = clock
        let remembered = ["spark-exit-1-slow-n1": now.addingTimeInterval(-60).timeIntervalSince1970]
        let kept = SparkExitManager.keepingFired([:], remembered: remembered, now: now)
        XCTAssertEqual(kept, remembered)

        let old = ["spark-exit-1-slow-n1": now.addingTimeInterval(-SparkExitManager.firedReminderMemory - 1).timeIntervalSince1970]
        XCTAssertTrue(SparkExitManager.keepingFired([:], remembered: old, now: now).isEmpty, "forgotten after 30 days")
        let ahead = ["spark-exit-x": now.addingTimeInterval(600).timeIntervalSince1970]
        XCTAssertTrue(SparkExitManager.keepingFired([:], remembered: ahead, now: now).isEmpty, "one not fired yet follows the plan")
    }

    // MARK: M6 sweep bounds

    /// One unconfirmed output holds the sweep for one recheck at most; then the confirmed ones go.
    func testAnUnconfirmedOutputHoldsTheSweepBackForOneRecheckAtMost() async throws {
        var record = SparkExitFixtures.record(phase: .done)
        record.leftover = [.init(txid: "c1", vout: 0, valueSats: 5000)]
        chain.economyFee = 1
        chain.utxosByAddress["bcrt1qfunding"] = [
            SparkExitFixtures.utxo("c1", value: 5000),
            SparkExitFixtures.utxo("stuck", value: 400, confirmed: false),
        ]
        var signed = 0
        let driver = SparkExitDriver(chain: chain, recovering: nil, makeSigner: { _ in
            signed += 1
            return StubCpfpSigner()
        }, save: { _ in })

        record = try await driver.tick(record)
        XCTAssertEqual(record.leftoverSweep?.waitingSince, 1000)
        XCTAssertEqual(signed, 0)

        chain.tip = 1000 + SparkExitDriver.sweepRecheckBlocks
        _ = try? await driver.tick(record)
        XCTAssertEqual(signed, 1, "the confirmed output is swept")
    }

    /// A built sweep a node answers with missing inputs is built again from the address from the next block.
    func testABuiltSweepWithMissingInputsIsBuiltAgain() async throws {
        var record = SparkExitFixtures.record(phase: .done)
        record.leftover = [.init(txid: "c1", vout: 0, valueSats: 5000)]
        record.leftoverSweep = .init(txid: "s", txHex: "02", valueSats: 4700, feeRateSatPerVbyte: 2, builtAtHeight: 1000)
        chain.outcome = .inputsMissing("bad-txns-inputs-missingorspent")

        record = try await driver(withSdk: false).tick(record)

        XCTAssertNil(record.leftoverSweep?.txid)
        XCTAssertEqual(record.leftoverSweep?.retryAtHeight, 1001)
        XCTAssertTrue(record.isLeftoverSweepPending)
    }

    /// A replacement refused for another reason while the sweep it replaced is still held is not final.
    func testARefusedReplacementKeepsFollowingTheSweepItReplaced() async throws {
        var record = SparkExitFixtures.record(phase: .done)
        record.leftover = [.init(txid: "c1", vout: 0, valueSats: 5000)]
        record.leftoverSweep = .init(txid: "s2", txHex: "02", valueSats: 4700, feeRateSatPerVbyte: 3, replacedTxids: ["s1"], builtAtHeight: 1000)
        chain.mempoolTxids = ["s1"]
        chain.outcome = .rejected("non-mandatory-script-verify-flag")

        record = try await driver(withSdk: false).tick(record)

        XCTAssertNil(record.leftoverSweep?.rejection)
        XCTAssertEqual(record.leftoverSweep?.replacedTxids, ["s1"])
        XCTAssertTrue(record.isLeftoverSweepPending)
    }

    // MARK: M7 salvage

    func testASalvagedRecordKeepsTheChainedTxidsAndReplacesTheOriginalInOneWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SparkExitStore(url: dir.appendingPathComponent("spark-exit.json"))
        let lost = SparkExitLostLeafStore(url: dir.appendingPathComponent("lost.json"))
        var record = SparkExitFixtures.record(phase: .running)
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        record.earlierCpfpTxids = ["child-1"]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SparkExitRecordCoder.encode(record)) as? [String: Any])
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)

        let loaded = try XCTUnwrap(SparkExitManager.loadRecord(store: store, lostLeafStore: lost))

        XCTAssertEqual(loaded.earlierCpfpTxids, ["child-1"])
        XCTAssertEqual(try store.load()?.isRebuiltFromChain, true, "the salvaged record is in place")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.contains("unreadable") }, "the original is kept aside")
    }
}
