@testable import Bitkit
import BitkitCore
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

    // MARK: Review 518bf31e5

    /// Funding sent from another wallet before the user picked savings is not paid twice.
    func testSavingsPaysOnlyWhatTheFundingAddressDoesNotHoldYet() {
        let quote = SparkExitQuote(prepared: SparkExitFixtures.prepared(funding: 20000))
        XCTAssertEqual(SparkExitManager.savingsFundingSats(confirmed: quote, fresh: quote, seenSats: 25000, seenCount: 1, feeRate: 2), 0)
    }

    /// Savings completing a partial payment from another wallet is one more funding input: it pays that input's fee
    /// too, so both payments together are adopted. A 20,000 quote at 2 sat/vB with 8,000 received needs 20,136.
    func testSavingsCompletingPartialFundingPaysTheExtraInputsFee() {
        let quote = SparkExitQuote(prepared: SparkExitFixtures.prepared(funding: 20000))
        let sats = SparkExitManager.savingsFundingSats(confirmed: quote, fresh: quote, seenSats: 8000, seenCount: 1, feeRate: 2)

        XCTAssertEqual(sats, 12136, "savings left the exit short of the second input's fee")
        let paid = [
            SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 8000),
            SparkExitFixtures.utxo(String(repeating: "b", count: 64), value: sats),
        ]
        XCTAssertNotNil(SparkExitMath.fundingTopUp(paid, requiredSats: 20000, inputFeeSats: SparkExitMath.inputVbytes * 2))
        XCTAssertEqual(SparkExitManager.savingsFundingSats(confirmed: quote, fresh: quote, seenSats: 0, seenCount: 0, feeRate: 2), 20000)
    }

    /// A tapped notification for an exit whose result was seen already is let go once the record loaded, so a later
    /// exit's result never jumps to Progress.
    func testATappedNotificationIsLetGoOnceTheLoadedExitShowsNoResult() {
        XCTAssertEqual(SparkExitManager.notificationOpen(opensProgress: true, showsResult: false, hasLoadedRecord: false), .wait)
        XCTAssertEqual(SparkExitManager.notificationOpen(opensProgress: true, showsResult: true, hasLoadedRecord: true), .open)
        XCTAssertEqual(SparkExitManager.notificationOpen(opensProgress: true, showsResult: false, hasLoadedRecord: true), .drop)
    }

    /// A cancel of an exit that can no longer be cancelled says so, not that the address could not be read.
    @MainActor func testACancelOfAnExitNoLongerCancellableIsNotAFailedRead() async {
        let exit = SparkExitManager(walletIndex: 9999)
        let outcome = await exit.cancel()
        XCTAssertEqual(outcome, .notCancellable)
    }

    /// A forgotten exit gives its funding address back, so a payment that lands there late is seen by the next exit.
    func testAForgottenExitGivesItsFundingAddressBack() {
        XCTAssertEqual(SparkExitManager.fundingCounterAfterForget(4, index: 3), 3)
        XCTAssertEqual(SparkExitManager.fundingCounterAfterForget(6, index: 3), 6, "a later address is in use")
    }

    /// A wipe deletes the copies of an unreadable record kept aside, which hold the wiped wallet's addresses.
    func testAWipeDeletesTheRecordsCopiesKeptAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SparkExitStore(url: dir.appendingPathComponent("spark-exit.json"))
        try store.save(SparkExitFixtures.record())
        try store.keepCopyAside()

        try store.deleteWithCopies()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
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

    /// A Redo while a higher fee's top-up is awaited: the diverged generation is never sent again, and its rebuild
    /// waits for the top-up as a Redo rebuild.
    func testARedoWhileAHigherFeesTopUpIsAwaitedStopsDrivingTheDivergedGeneration() async throws {
        var record = bumpedRecord()
        chain.mempoolTxids = ["bump"]
        sdk.checks = try [CheckRecoverFundsResponse(recovery: XCTUnwrap(record.recovery?.response), verdict: .redo(reason: .onChainStateDiverged))]

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .needsFunding(requiredSats: 25680))
        XCTAssertTrue(record.isRebuilding)
        XCTAssertEqual(record.isRedoRebuild, true)
        XCTAssertFalse(record.isDrivingWhileFunding, "the diverged generation would be sent again")
    }

    /// A payment no host knows for three blocks is forgotten: the ask and the funding reminder come back.
    func testADroppedSavingsPaymentBringsTheAskBack() async throws {
        var record = bumpedRecord()
        sdk.checks = try Array(repeating: CheckRecoverFundsResponse(recovery: XCTUnwrap(record.recovery?.response), verdict: .valid), count: 3)

        record = try await driver().tick(record)
        XCTAssertEqual(record.fundingPaymentMissingSince, 1000)
        XCTAssertEqual(record.fundingPaymentTxid, "bump", "one read is not enough")

        chain.tip = 1003
        record = try await driver().tick(record)
        XCTAssertNil(record.fundingPaymentTxid)
        XCTAssertFalse(record.isAwaitingOwnPayment)
        XCTAssertTrue(SparkExitMath.reminders(record, tip: 1003, now: clock, network: .regtest).contains { $0.isFunding })
    }

    /// A payment one host misses just before a block and just after it, seconds apart, may still be indexing: it is
    /// kept. A read that finds it starts the count over; only a miss that lasts three blocks forgets it.
    func testASavingsPaymentMissedForABlockOrASingleReadIsKept() async throws {
        var record = bumpedRecord()
        sdk.checks = try Array(repeating: CheckRecoverFundsResponse(recovery: XCTUnwrap(record.recovery?.response), verdict: .valid), count: 6)

        record = try await driver().tick(record)
        chain.tip = 1001
        record = try await driver().tick(record)
        XCTAssertEqual(record.fundingPaymentTxid, "bump", "a one-block miss asked for the funding again")

        chain.mempoolTxids = ["bump"]
        chain.tip = 1002
        record = try await driver().tick(record)
        chain.mempoolTxids = []
        chain.tip = 1003
        record = try await driver().tick(record)
        chain.tip = 1005
        record = try await driver().tick(record)
        XCTAssertEqual(record.fundingPaymentTxid, "bump")
        chain.tip = 1006
        record = try await driver().tick(record)
        XCTAssertNil(record.fundingPaymentTxid)
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

    /// A savings payment that confirms short of a higher re-quoted funding is no longer waited for: the rest is asked
    /// for, and reminded about at once.
    func testASavingsPaymentConfirmedShortRemindsForTheRestAtOnce() async throws {
        var record = SparkExitFixtures.record(phase: .awaitingFunding(requiredSats: 35000))
        record.fundingPaymentTxid = "paid"
        chain.mempoolTxids = ["paid"]
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("paid", value: 20000, confirmed: false)]

        record = try await driver().tick(record)
        XCTAssertTrue(record.isAwaitingOwnPayment, "still confirming")
        XCTAssertTrue(SparkExitMath.reminders(record, tip: 1000, now: record.createdAt, network: .regtest).isEmpty)

        chain.confirmedTxids = ["paid"]
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("paid", value: 20000)]
        record = try await driver().tick(record)

        XCTAssertFalse(record.isAwaitingOwnPayment)
        let reminders = SparkExitMath.reminders(record, tip: 1000, now: record.createdAt, network: .regtest)
        XCTAssertEqual(reminders.map(\.isFunding), [true])
        XCTAssertEqual(reminders.first?.fireAt, record.createdAt, "at once, not 4 hours after the start")
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

    // MARK: Bot review threads

    /// The background connect's timeout returns on time, without waiting for the connect it gives up on.
    func testTheConnectTimeoutReturnsWithoutWaitingForTheConnect() async {
        let started = Date()
        let result: Bool? = await SparkManager.firstOf(timeout: 0.02) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            return true
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
        let quick: Bool? = await SparkManager.firstOf(timeout: 5) { true }
        XCTAssertEqual(quick, true)
    }

    /// A tick that built or published meanwhile leaves nothing cancel can act on: the reloaded record is revalidated.
    func testCancelRevalidatesARecordATickBuiltMeanwhile() {
        var record = SparkExitFixtures.record()
        XCTAssertTrue(SparkExitManager.canCancel(record, fundingSeenSats: 0))
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("n1")]))
        XCTAssertFalse(SparkExitManager.canCancel(record, fundingSeenSats: 0))
    }

    /// A sweep that confirms while it left outputs out (too small, or unconfirmed when built) keeps following them.
    func testAConfirmedPartialSweepKeepsFollowingWhatItLeftOut() async throws {
        var record = SparkExitFixtures.record(phase: .done)
        record.leftover = [.init(txid: "c1", vout: 0, valueSats: 5000), .init(txid: "c2", vout: 0, valueSats: 300)]
        record.leftoverSweep = .init(txid: "s1", txHex: "02", valueSats: 4700, isAccepted: true, feeRateSatPerVbyte: 2, sentAtHeight: 1000)
        chain.confirmedTxids = ["s1"]
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("c2", value: 300)]

        record = try await driver(withSdk: false).tick(record)

        XCTAssertEqual(record.sweptLeftover, [.init(txid: "s1", valueSats: 4700)])
        XCTAssertEqual(record.leftover, [.init(txid: "c2", vout: 0, valueSats: 300)])
        XCTAssertEqual(record.leftoverSweep?.isWaitingForFees, true)
        XCTAssertTrue(record.isLeftoverSweepPending)
        XCTAssertEqual(record.leftoverLine, .waiting(sats: 300))
    }

    /// A partial sweep that confirms while the funding address cannot be read stays driven, and follows what it left
    /// out once the address reads again.
    func testAConfirmedPartialSweepStaysDrivenUntilTheAddressReads() async throws {
        var record = SparkExitFixtures.record(phase: .done)
        record.leftover = [.init(txid: "c1", vout: 0, valueSats: 5000), .init(txid: "c2", vout: 0, valueSats: 300)]
        record.leftoverSweep = .init(txid: "s1", txHex: "02", valueSats: 4700, isAccepted: true, feeRateSatPerVbyte: 2, sentAtHeight: 1000)
        chain.confirmedTxids = ["s1"]
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("c2", value: 300)]

        chain.isTipUnreadable = true
        record = try await driver(withSdk: false).tick(record)
        XCTAssertTrue(record.needsDriving, "the tip could not be read")

        chain.isTipUnreadable = false
        chain.isUtxosUnreadable = true
        record = try await driver(withSdk: false).tick(record)
        XCTAssertTrue(record.needsDriving, "the funding address could not be read")
        XCTAssertNil(record.sweptLeftover)
        record = try JSONDecoder().decode(SparkExitRecord.self, from: JSONEncoder().encode(record))
        XCTAssertTrue(record.needsDriving, "after a restart")

        chain.isUtxosUnreadable = false
        record = try await driver(withSdk: false).tick(record)
        XCTAssertEqual(record.sweptLeftover, [.init(txid: "s1", valueSats: 4700)])
        XCTAssertEqual(record.leftover, [.init(txid: "c2", vout: 0, valueSats: 300)])
        XCTAssertEqual(record.leftoverSweep?.isWaitingForFees, true)
        XCTAssertTrue(record.needsDriving)
    }

    /// A first build holding only cooperative leaves the operators could not co-sign enters the bounded retry.
    func testAFirstBuildOfOnlyFailedCooperativeLeavesWaitsForTheOperators() async throws {
        let failure = CooperativeRecoveryFailure(leafId: "coop-1", outputTxid: "w", outputVout: 0, error: .operatorsUnavailable(message: "down"))
        var prepared = SparkExitFixtures.prepared(funding: nil, leaves: [])
        prepared.leaves = [RecoverFundsLeaf(leafId: "coop-1", valueSats: 5000, method: .cooperative)]
        sdk.preparedResponse = prepared
        sdk.builds = [SparkExitFixtures.recovery([], failed: [failure]), SparkExitFixtures.recovery([], failed: [failure])]
        var record = SparkExitFixtures.record(phase: .awaitingFunding(requiredSats: 0))

        record = try await driver().tick(record)
        XCTAssertEqual(record.phase, .running)
        XCTAssertEqual(record.recovery?.response.failed.count, 1)

        record = try await driver().tick(record)
        XCTAssertEqual(record.failedLeafRetrySince, 1000)
        XCTAssertTrue(record.isWaitingForOperators)
        XCTAssertTrue(sdk.checkedRecoveries.isEmpty, "nothing to check on-chain")

        chain.tip = 1000 + SparkExitDriver.releaseBlocks
        record = try await driver().tick(record)
        XCTAssertEqual(record.phase, .done)
        XCTAssertEqual(record.isFailedLeavesReleased, true)
    }

    /// A rate at which a leaf can no longer pay its own exit would leave it on Spark: it is not offered (Android review).
    func testFeeBumpPricingRefusesARateThatLeavesALeafBehind() async throws {
        var record = bumpedRecord()
        record = SparkExitRecord(
            network: record.network, createdAt: record.createdAt, phase: .running, feeRateSatPerVbyte: 2,
            destination: record.destination, leafIds: ["leaf-1", "small"], funding: record.funding,
            transferId: record.transferId, expectedSats: record.expectedSats
        )
        sdk.prepareErrors = [SdkError.SparkError("Leaf small cannot be exited: its refund cannot pay its own fee")]
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n2b")])]

        do {
            _ = try await driver().feeBumpShortfall(record, rate: 12)
            XCTFail("a rate that leaves a leaf behind is not priced")
        } catch let SparkExitFeeBumpError.leavesBehind(sats) {
            XCTAssertEqual(sats, 0, "the small leaf's value is unknown before the first build")
        }
        XCTAssertTrue(sdk.recoverRequests.isEmpty)

        // A build that refuses a leaf the prepare kept is not offered either.
        sdk = FakeSparkExitRecovering()
        sdk.recoverError = SdkError.SparkError("Leaf leaf-1 cannot be exited: its refund cannot pay its own fee")
        do {
            _ = try await driver().feeBumpShortfall(bumpedRecord(), rate: 12)
            XCTFail("expected leavesBehind")
        } catch let SparkExitFeeBumpError.leavesBehind(sats) {
            XCTAssertEqual(sats, 100_000)
        }
    }

    /// The keyless pass finding every step in a block ends the exit without waiting for the SDK (Android review).
    func testAKeylessPassThatSeesEveryStepConfirmedEndsTheExit() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 990)),
            SparkExitFixtures.tx("s", kind: .sweep, dependsOn: ["n1"]),
        ]))
        chain.confirmedTxids = ["n1", "s"]
        chain.utxosByAddress["bcrt1qfunding"] = []

        record = try await driver(withSdk: false).tick(record)

        XCTAssertEqual(record.phase, .done)
        XCTAssertTrue(chain.broadcasts.isEmpty)
    }

    /// A wipe closes the exit's writes: a tick still running can't write the deleted record back (Android review).
    func testAClosedWriteGateDropsTheSaveOfATickStillRunning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SparkExitStore(url: dir.appendingPathComponent("spark-exit.json"))
        let gate = SparkExitWriteGate()
        let save = SparkExitManager.gatedSave(
            store: store,
            lostLeafStore: SparkExitLostLeafStore(url: dir.appendingPathComponent("lost.json")),
            gate: gate
        )

        try save(SparkExitFixtures.record())
        XCTAssertNotNil(try store.load())
        try store.delete()

        gate.close()
        XCTAssertThrowsError(try save(SparkExitFixtures.record()))
        XCTAssertNil(try store.load())
    }

    /// Reminder ids are scoped per exit, so a later exit's `failed` is never taken for an earlier exit's.
    func testReminderIdsAreScopedPerExit() {
        let reminder = SparkExitReminder(id: "failed", fireAt: clock, isFailed: true)
        let first = SparkExitFixtures.record()
        let second = SparkExitRecord(
            network: "regtest", createdAt: first.createdAt.addingTimeInterval(86400), phase: .done, feeRateSatPerVbyte: 2,
            destination: "bcrt1qdestination", leafIds: ["leaf-2"], funding: first.funding, transferId: nil, expectedSats: 0
        )
        XCTAssertNotEqual(SparkExitManager.notificationId(reminder, record: first), SparkExitManager.notificationId(reminder, record: second))
        XCTAssertTrue(SparkExitManager.notificationId(reminder, record: first).hasPrefix("spark-exit-"))
    }

    /// Salvage keeps the funding strategy and what earlier generations paid to savings.
    func testSalvageKeepsTheFundingStrategyAndEarlierReceived() throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        record.fundingStrategy = SparkExitRecord.perNodeStrategy
        record.earlierReceivedSats = ["sweep-1": 40000]
        record.outsideSats = 14167
        let salvaged = try XCTUnwrap(SparkExitRecordCoder.salvage(SparkExitRecordCoder.encode(record)))
        XCTAssertEqual(salvaged.fundingStrategy, SparkExitRecord.perNodeStrategy)
        XCTAssertEqual(salvaged.earlierReceivedSats, ["sweep-1": 40000])
        XCTAssertEqual(salvaged.outsideSats, 14167)
    }

    /// A salvaged exit imports the exit data it kept before it is prepared again: the SDK may no longer hold a leaf
    /// being exited.
    func testASalvagedExitImportsItsSnapshotBeforeItsFirstRebuild() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 25000)
        record.exitStateSnapshot = "snapshot-1"
        let salvaged = try XCTUnwrap(SparkExitRecordCoder.salvage(SparkExitRecordCoder.encode(record)))
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("f0", vout: 1, value: 25000)]
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n1")])]
        var importsAtPrepare: [[String]] = []
        sdk.preparedByRequest = { [sdk] _ in
            importsAtPrepare.append(sdk?.imports ?? [])
            return SparkExitFixtures.prepared()
        }

        _ = try await driver().tick(salvaged)

        XCTAssertFalse(importsAtPrepare.isEmpty, "the salvaged exit is prepared again")
        XCTAssertEqual(importsAtPrepare.first, ["snapshot-1"], "its kept exit data is imported before it is prepared")
        XCTAssertEqual(sdk.exports, 0)
    }

    /// Background runs wrap the chain to time it: the wrapper forwards the economy tier, so their sweeps pay it.
    func testTheTimedBackgroundChainForwardsTheNetworkFees() async throws {
        chain.fastestFee = 9
        chain.economyFee = 1
        let timed = TimedSparkExitChain(base: chain, timings: SparkExitTimings())

        let fees = try await timed.networkFees()

        XCTAssertEqual(fees.economy, 1)
        XCTAssertEqual(SparkExitMath.sweepFeeRate(economy: fees.economy, exitRate: 5), 1)
    }

    // MARK: Unknown funding broadcast (review thread r4498875767)

    /// A savings broadcast with an unknown outcome is kept as paid (pending): it may still have gone out.
    func testAnUnknownFundingBroadcastIsKeptAsPaid() {
        XCTAssertEqual(SparkExitManager.fundingTxid(.unknown(txid: "unk")), "unk")
        XCTAssertEqual(SparkExitManager.fundingTxid(.accepted(txid: "ok")), "ok")
        XCTAssertNil(SparkExitManager.fundingTxid(.rejected(txid: "no", reason: "insufficient funds")))
    }

    /// With that payment pending, or any unresolved savings send to the exit's address, cancel is off: the record stays.
    func testAPendingFundingSendKeepsTheExit() {
        var record = SparkExitFixtures.record()
        XCTAssertFalse(SparkExitManager.canCancel(record, fundingSeenSats: 0, unresolvedSendAddress: "bcrt1qfunding"))
        XCTAssertTrue(SparkExitManager.canCancel(record, fundingSeenSats: 0, unresolvedSendAddress: "bcrt1qelsewhere"))
        record.fundingPaymentTxid = "unk"
        XCTAssertFalse(SparkExitManager.canCancel(record, fundingSeenSats: 0))
        XCTAssertTrue(record.isAwaitingOwnPayment)
    }

    /// The unknown payment confirming late is adopted like any funding, and the exit builds.
    func testALateConfirmationOfAnUnknownFundingSendIsAdopted() async throws {
        var record = SparkExitFixtures.record()
        record.fundingPaymentTxid = "unk"
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n1")])]

        record = try await driver().tick(record)
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: []), .paid(txid: "unk"))
        XCTAssertNil(record.recovery)

        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("unk", value: 20000)]
        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .running)
        XCTAssertEqual(record.funding.first?.txid, "unk")
        XCTAssertNotNil(record.recovery)
    }

    // MARK: Wipe (review thread 4511769434)

    /// A quote taken before a wipe names the wiped wallet's address: the next wallet's exit must never pay to it.
    @MainActor
    func testAWipeForgetsTheQuotesDestinationAndFunding() async {
        let exit = SparkExitManager(walletIndex: 9999)
        exit.useQuote(
            SparkExitQuote(prepared: SparkExitFixtures.prepared()),
            destination: "bcrt1qwalleta",
            feeRate: 4,
            fundingIndex: 3,
            fundingAddress: "bcrt1qfundinga"
        )
        exit.noteFundingSeen([SparkExitFixtures.utxo("seen", value: 5000)])
        exit.fundFromSavings = true
        exit.savingsFeeRate = 7
        exit.savingsFeeSats = 300

        await exit.wipe()

        XCTAssertNil(exit.quote)
        XCTAssertNil(exit.pendingDestination)
        XCTAssertNil(exit.quoteFeeRate)
        XCTAssertNil(exit.pendingFundingIndex)
        XCTAssertNil(exit.fundingAddress)
        XCTAssertFalse(exit.fundFromSavings)
        XCTAssertEqual(exit.savingsFeeRate, 0)
        XCTAssertEqual(exit.savingsFeeSats, 0)
        XCTAssertEqual(exit.fundingSeenSats, 0)
        XCTAssertEqual(exit.fundingSeenCount, 0)
    }

    // MARK: Wallet totals (pwltr, android#1782)

    /// Funding seen at the address changes what is in transfer to savings: the wallet recomputes its totals.
    @MainActor func testAFundingSeenOnlyChangeRefreshesTheWalletBalance() {
        var refreshes = 0
        let watch = SparkExitBalanceWatch { refreshes += 1 }
        var record = SparkExitFixtures.record(phase: .awaitingFunding(requiredSats: 20000))
        record.transferId = "transfer-1"
        watch.update(record: record, fundingSeenSats: 0, sparkBalanceSats: 0)
        let before = refreshes

        watch.update(record: record, fundingSeenSats: 5000, sparkBalanceSats: 0)

        XCTAssertEqual(refreshes, before + 1, "the wallet kept the in-transfer amount from before the funding was seen")
    }

    /// A record write that leaves the totals' amounts alone does not recompute them.
    @MainActor func testAnExitWriteThatLeavesTheTotalsAloneDoesNotRefreshTheWalletBalance() {
        var refreshes = 0
        let watch = SparkExitBalanceWatch { refreshes += 1 }
        var record = SparkExitFixtures.record(phase: .awaitingFunding(requiredSats: 20000))
        record.transferId = "transfer-1"
        watch.update(record: record, fundingSeenSats: 0, sparkBalanceSats: 0)
        let before = refreshes

        record.isResultSeen = true
        record.lastBuildAt = Date(timeIntervalSince1970: 1_800_000_000)
        watch.update(record: record, fundingSeenSats: 0, sparkBalanceSats: 0)

        XCTAssertEqual(refreshes, before)
    }

    // MARK: Round 3 (Corey 5859257501)

    /// A quote for a new funding address starts with nothing seen there: an earlier exit's funding never lowers what
    /// savings pays.
    @MainActor func testAQuoteForANewFundingAddressStartsWithNothingSeen() {
        let exit = SparkExitManager(walletIndex: 9999)
        let quote = SparkExitQuote(prepared: SparkExitFixtures.prepared())
        exit.useQuote(quote, destination: "bcrt1qdestination", feeRate: 2, fundingIndex: 3, fundingAddress: "bcrt1qearlier")
        exit.noteFundingSeen([SparkExitFixtures.utxo(String(repeating: "a", count: 64), value: 8000)])
        exit.useQuote(quote, destination: "bcrt1qdestination", feeRate: 2, fundingIndex: 3, fundingAddress: "bcrt1qearlier")
        XCTAssertEqual(exit.fundingSeenSats, 8000, "a quote again for the same address keeps what reached it")

        exit.useQuote(quote, destination: "bcrt1qdestination", feeRate: 2, fundingIndex: 4, fundingAddress: "bcrt1qnext")

        XCTAssertEqual(exit.fundingSeenSats, 0, "the earlier exit's funding was taken as already sent")
        XCTAssertEqual(exit.fundingSeenCount, 0)
    }

    // MARK: What stays on Spark (Android 124d66170, caa349d4b)

    /// The start and the requote save what stays on Spark without the lost leaves Spark still counts: 100,000 sats
    /// selected, 32,768 lost and 1,696 skipped save 1,696.
    func testAStartSavesWhatStaysOnSparkWithoutTheLostLeavesSparkStillCounts() throws {
        var prepared = SparkExitFixtures.prepared()
        prepared.skipped = [SkippedLeaf(leafId: "dust", valueSats: 1696, reason: .feeExceedsValue)]
        let quote = SparkExitQuote(prepared: prepared, lostLeafSats: [32768])
        XCTAssertEqual(quote.leafTotalSats, 100_000)

        let record = try XCTUnwrap(SparkExitManager.requoted(SparkExitFixtures.record(), fresh: quote, sparkBalanceSats: 134_464))

        XCTAssertEqual(record.outsideSats, 1696, "the lost leaf was kept as staying on Spark")
    }

    /// A leaf the exit left behind stays on Spark: Spending counts it while it is out of the transfer.
    func testALeafTheExitLeftBehindCountsOnSpark() {
        var record = SparkExitFixtures.record(phase: .running)
        record.leafIds = ["leaf-1", "leaf-2"]
        record.leafTotalSats = 108_192
        record.leftBehindLeaves = [.init(leafId: "leaf-2", valueSats: 8192, reason: "its refund cannot pay")]

        XCTAssertEqual(SparkExitMath.staysOnSparkSats(sparkBalanceSats: 108_192, record: record), 8192, "the leaf is in neither total")
        XCTAssertEqual(SparkExitMath.outsideExitSats(sparkBalanceSats: 108_192, record: record), 8192)
    }

    // MARK: Requote at the start (review 1ac10966a, Android 64004d7)

    /// An optimization swapped the leaves while the start waited: the exit is quoted again over the leaves Spark holds now.
    func testAStartQuotesAgainWhenTheLeavesChanged() async throws {
        let confirmed = SparkExitQuote(prepared: SparkExitFixtures.prepared())
        sdk.preparedResponse = SparkExitFixtures.prepared(funding: 35000, leaves: ["leaf-2", "leaf-3"])

        let requote = await SparkExitManager.requote(sdk, confirmed: confirmed, feeRate: 2, destination: "bcrt1qdestination", lostLeafIds: [])
        let fresh = try XCTUnwrap(requote)
        let record = try XCTUnwrap(SparkExitManager.requoted(SparkExitFixtures.record(), fresh: fresh, sparkBalanceSats: 214_167))

        XCTAssertEqual(record.leafIds, ["leaf-2", "leaf-3"])
        XCTAssertEqual(record.phase, .awaitingFunding(requiredSats: 35000))
        XCTAssertEqual(record.expectedSats, fresh.incomingSats)
        XCTAssertEqual(record.leafTotalSats, 200_000)
        XCTAssertEqual(record.outsideSats, 14167, "what stays on Spark beyond the fresh leaves")
        XCTAssertEqual(record.leafSats?.keys.sorted(), ["leaf-2", "leaf-3"])
        XCTAssertEqual(sdk.prepareRequests.last?.destination, "bcrt1qdestination")
    }

    /// The same leaves in another order, no leaf left, or a quote that fails: the exit goes on with the confirmed quote.
    func testAStartKeepsTheConfirmedQuoteWhenTheLeavesDidNotChange() async {
        let confirmed = SparkExitQuote(prepared: SparkExitFixtures.prepared(leaves: ["leaf-1", "leaf-2"]))
        func requote() async -> SparkExitQuote? {
            await SparkExitManager.requote(sdk, confirmed: confirmed, feeRate: 2, destination: "bcrt1qdestination", lostLeafIds: [])
        }

        sdk.preparedResponse = SparkExitFixtures.prepared(leaves: ["leaf-2", "leaf-1"])
        let reordered = await requote()
        XCTAssertNil(reordered)
        sdk.preparedResponse = SparkExitFixtures.prepared(leaves: [])
        let empty = await requote()
        XCTAssertNil(empty)
        sdk.prepareErrors = [URLError(.timedOut)]
        let failed = await requote()
        XCTAssertNil(failed)
    }

    /// A requote whose write fails leaves the start going on with the confirmed quote, its transfer kept and no new
    /// one left counted.
    func testAFailedRequoteWriteGoesOnWithTheConfirmedQuote() async throws {
        struct WriteFailed: Error {}
        let started = SparkExitFixtures.record()
        let fresh = SparkExitQuote(prepared: SparkExitFixtures.prepared(funding: 25000, leaves: ["leaf-2"]))
        let requoted = try XCTUnwrap(SparkExitManager.requoted(started, fresh: fresh, sparkBalanceSats: 0))
        var settled: [String] = []

        let noTransfer = await SparkExitManager.writeRequote(
            requoted,
            replacing: started,
            incomingSats: fresh.incomingSats,
            createTransfer: { _ in throw WriteFailed() },
            save: { _ in },
            markSettled: { settled.append($0) }
        )
        XCTAssertNil(noTransfer)

        let notSaved = await SparkExitManager.writeRequote(
            requoted,
            replacing: started,
            incomingSats: fresh.incomingSats,
            createTransfer: { _ in "transfer-2" },
            save: { _ in throw WriteFailed() },
            markSettled: { settled.append($0) }
        )
        XCTAssertNil(notSaved)
        XCTAssertEqual(settled, ["transfer-2"], "the confirmed quote's transfer stays; the unsaved one is settled")

        let written = await SparkExitManager.writeRequote(
            requoted,
            replacing: started,
            incomingSats: fresh.incomingSats,
            createTransfer: { _ in "transfer-3" },
            save: { _ in },
            markSettled: { settled.append($0) }
        )
        XCTAssertEqual(written?.transferId, "transfer-3")
        XCTAssertEqual(written?.leafIds, ["leaf-2"])
        XCTAssertEqual(settled, ["transfer-2", "transfer-1"])
    }

    /// A start killed before its transfer is written stores no exit: none runs on without the transfer counting it.
    func testAStartCutShortBeforeItsTransferStoresNoExit() async {
        struct WriteFailed: Error {}
        var record = SparkExitFixtures.record()
        record.transferId = nil
        var saved: [SparkExitRecord] = []

        let started = try? await SparkExitManager.writeStart(
            record,
            incomingSats: 111_000,
            createTransfer: { _ in throw WriteFailed() },
            save: { saved.append($0) },
            markSettled: { _ in }
        )

        XCTAssertNil(started)
        XCTAssertTrue(saved.isEmpty, "no exit is stored before its transfer exists")
    }

    /// A start killed after its transfer is written leaves only that transfer, settled as an orphan on the next load;
    /// a failed save settles it at once. Every exit stored carries its transfer.
    func testAStartCutShortAfterItsTransferLeavesOnlyAnOrphanToSettle() async throws {
        struct WriteFailed: Error {}
        var record = SparkExitFixtures.record()
        record.transferId = nil
        var saved: [SparkExitRecord] = []
        var settled: [String] = []

        let notSaved = try? await SparkExitManager.writeStart(
            record,
            incomingSats: 111_000,
            createTransfer: { _ in "transfer-1" },
            save: { _ in throw WriteFailed() },
            markSettled: { settled.append($0) }
        )
        XCTAssertNil(notSaved)
        XCTAssertEqual(settled, ["transfer-1"])

        let started = try await SparkExitManager.writeStart(
            record,
            incomingSats: 111_000,
            createTransfer: { _ in "transfer-2" },
            save: { saved.append($0) },
            markSettled: { settled.append($0) }
        )
        XCTAssertEqual(started.transferId, "transfer-2")
        XCTAssertEqual(saved.map(\.transferId), ["transfer-2"], "every exit stored carries its transfer")
    }

    /// No tick drives an exit while its start still settles its leaves: the optimization wait, the requote and the
    /// reconnect.
    func testNoTickDrivesAnExitWhileItsStartSettles() {
        let record = SparkExitFixtures.record()
        XCTAssertFalse(SparkExitManager.canDrive(record, startingCreatedAt: record.createdAt))
        XCTAssertTrue(SparkExitManager.canDrive(record, startingCreatedAt: nil))
        XCTAssertTrue(SparkExitManager.canDrive(record, startingCreatedAt: record.createdAt.addingTimeInterval(-60)))
    }

    /// Funding read for a cancelled exit, such as its savings payment, never shows for the next one.
    func testACancelledExitsFundingNeverShowsForTheNextExit() {
        let cancelled = SparkExitFixtures.record()
        var next = SparkExitFixtures.record()
        next = SparkExitRecord(
            network: next.network,
            createdAt: cancelled.createdAt.addingTimeInterval(60),
            phase: next.phase,
            feeRateSatPerVbyte: next.feeRateSatPerVbyte,
            destination: next.destination,
            leafIds: next.leafIds,
            funding: next.funding,
            expectedSats: next.expectedSats
        )
        XCTAssertTrue(SparkExitManager.isFundingOfExit(cancelled.createdAt, record: cancelled))
        XCTAssertFalse(SparkExitManager.isFundingOfExit(cancelled.createdAt, record: next))
        XCTAssertFalse(SparkExitManager.isFundingOfExit(nil, record: next))
    }

    private func refusedPayment(status: OnchainSendAttempt.Status = .rejected, address: String = "bcrt1qfunding") -> OnchainSendAttempt {
        var attempt = OnchainSendAttempt(
            id: UUID(), walletId: "wallet", requestId: nil, orderId: nil, address: address, amountSats: 9000, isMaxAmount: false,
            status: status, txid: "refused"
        )
        attempt.recoveryContext = OnchainSendRecoveryContext(
            inputs: [OnchainSendInput(txid: String(repeating: "a", count: 64), vout: 0)],
            satsPerVbyte: 9,
            paymentIdentity: nil,
            candidateTxids: ["refused"]
        )
        return attempt
    }

    /// Progress says a savings payment was refused only while the exit still waits for its first funding.
    func testARefusedSavingsPaymentIsShownUntilAPaymentIsKept() {
        let record = SparkExitFixtures.record()
        XCTAssertTrue(SparkExitManager.isSavingsPaymentRefused(record, attempt: refusedPayment()))
        XCTAssertFalse(SparkExitManager.isSavingsPaymentRefused(record, attempt: refusedPayment(status: .unknown)), "it may still go out")
        XCTAssertFalse(SparkExitManager.isSavingsPaymentRefused(record, attempt: refusedPayment(address: "bcrt1qother")))
        var paid = record
        paid.fundingPaymentTxid = "paid"
        XCTAssertFalse(SparkExitManager.isSavingsPaymentRefused(paid, attempt: refusedPayment()))
        XCTAssertFalse(SparkExitManager.isSavingsPaymentRefused(SparkExitFixtures.record(phase: .running), attempt: refusedPayment()))
    }

    /// Paying again re-signs the refused attempt itself, over the inputs it already spends, so at most one confirms.
    func testPayingAgainRetriesOnlyTheRefusedAttempt() async throws {
        let refused = refusedPayment()
        var contexts: [OnchainSendPendingContext] = []
        let txid = try await SparkExitManager.payRefusedAgain(refused, record: SparkExitFixtures.record()) { context in
            contexts.append(context)
            return .accepted(txid: "again")
        }
        XCTAssertEqual(txid, "again")
        XCTAssertEqual(contexts, [OnchainSendPendingContext(attemptId: refused.id, walletId: "wallet", txid: "refused")])

        do {
            _ = try await SparkExitManager.payRefusedAgain(refusedPayment(status: .unknown), record: SparkExitFixtures.record()) { context in
                contexts.append(context)
                return .accepted(txid: "again")
            }
            XCTFail("a payment that may still go out is never paid again")
        } catch {}
        XCTAssertEqual(contexts.count, 1)
    }

    /// A wipe closes Spark's connects first, then lets exit work (a tick that may reconnect) finish, and only then
    /// disconnects and deletes: nothing can reconnect the wiped wallet after its SDK is cleared.
    @MainActor
    func testAWipeClosesConnectsAndDrainsExitWorkBeforeItDisconnects() async throws {
        var steps: [String] = []
        try await SparkManager.wipeInOrder(
            closeAdmission: { steps.append("close") },
            drainExitWork: { steps.append("drain") },
            disconnect: { steps.append("disconnect") },
            deleteData: { steps.append("delete") }
        )
        XCTAssertEqual(steps, ["close", "drain", "disconnect", "delete"])
    }

    /// Fee rates that cannot be read fail the savings price, so Pay from savings shows its error instead of loading.
    func testSavingsFeeFailsWithoutFeeRates() async {
        let rates = FeeRates(fast: 9, mid: 6, slow: 1)
        func price(address: String? = "bcrt1qfunding", fundingSats: UInt64 = 20000, rates: FeeRates?) async
            -> SparkExitFundingView.SavingsFee
        {
            await SparkExitFundingView.priceSavingsFee(
                address: address,
                fundingSats: fundingSats,
                estimates: { rates },
                calculate: { _, _, _ in 300 }
            )
        }

        let noRates = await price(rates: nil)
        XCTAssertEqual(noRates, .failed)
        let noAddress = await price(address: nil, rates: rates)
        XCTAssertEqual(noAddress, .unavailable)
        let noFunding = await price(fundingSats: 0, rates: rates)
        XCTAssertEqual(noFunding, .unavailable)
        let priced = await price(rates: rates)
        XCTAssertEqual(priced, .priced(rate: TransactionSpeed.fast.getFeeRate(from: rates), feeSats: 300))
    }

    /// A start whose savings payment was refused for a higher prepared fee: the next funding prices at least that fee,
    /// so Funding shows it and the next swipe approves it.
    @MainActor
    func testTheNextFundingAfterAStartRefusedForAHigherSavingsFeePricesAtLeastThatFee() async {
        let rates = FeeRates(fast: 9, mid: 6, slow: 1)
        let exit = SparkExitManager(walletIndex: 9999)
        func price() async -> SparkExitFundingView.SavingsFee {
            await SparkExitFundingView.priceSavingsFee(
                address: "bcrt1qfunding",
                fundingSats: 20000,
                refusedFeeSats: exit.savingsFundingRefusedFeeSats,
                estimates: { rates },
                calculate: { _, _, _ in 420 }
            )
        }
        let rate = TransactionSpeed.fast.getFeeRate(from: rates)
        let first = await price()
        XCTAssertEqual(first, .priced(rate: rate, feeSats: 420))

        exit.noteSavingsFundingRefused(preparedFeeSats: 600)
        let next = await price()

        // Savings' coin selection needs 600 sats where the estimate says 420.
        XCTAssertEqual(next, .priced(rate: rate, feeSats: 600), "the same refused estimate was confirmed again")
    }

    /// Savings never pays more than the funding the user confirmed; the rest is asked for on Progress once the payment
    /// confirms.
    func testSavingsPaysAtMostTheConfirmedFundingAndProgressAsksForTheRest() throws {
        let confirmed = SparkExitQuote(prepared: SparkExitFixtures.prepared(funding: 20000))
        let higher = SparkExitQuote(prepared: SparkExitFixtures.prepared(funding: 35000, leaves: ["leaf-1", "leaf-2"]))
        let lower = SparkExitQuote(prepared: SparkExitFixtures.prepared(funding: 15000, leaves: ["leaf-2"]))
        XCTAssertEqual(SparkExitManager.savingsFundingSats(confirmed: confirmed, fresh: higher, seenSats: 0, seenCount: 0, feeRate: 2), 20000)
        XCTAssertEqual(SparkExitManager.savingsFundingSats(confirmed: confirmed, fresh: lower, seenSats: 0, seenCount: 0, feeRate: 2), 15000)

        var record = try XCTUnwrap(SparkExitManager.requoted(SparkExitFixtures.record(), fresh: higher, sparkBalanceSats: 0))
        record.fundingPaymentTxid = "paid"
        let paid = [SparkExitFixtures.utxo("paid", value: 20000)]
        guard case let .ask(sats, receivedSats) = SparkExitMath.fundingState(record, utxos: paid) else {
            return XCTFail("the shortfall is asked for")
        }
        XCTAssertEqual(receivedSats, 20000)
        XCTAssertGreaterThanOrEqual(sats, 15000)
    }

    // MARK: Savings payment on Confirm (review thread 4511769453)

    /// Pay from savings shows its own fee and the total that leaves savings; funding from another wallet shows neither.
    @MainActor
    func testConfirmShowsTheSavingsPaymentFeeAndTotal() {
        let exit = SparkExitManager(walletIndex: 9999)
        exit.useQuote(
            SparkExitQuote(prepared: SparkExitFixtures.prepared(funding: 6000)),
            destination: "bcrt1qdestination",
            feeRate: 2,
            fundingIndex: 0,
            fundingAddress: "bcrt1qfunding"
        )
        exit.savingsFeeSats = 453
        XCTAssertNil(exit.savingsPayment, "paid from another wallet")

        exit.fundFromSavings = true
        XCTAssertEqual(exit.savingsPayment?.feeSats, 453)
        XCTAssertEqual(exit.savingsPayment?.totalSats, 6453)

        exit.useQuote(
            SparkExitQuote(prepared: SparkExitFixtures.prepared(funding: nil)),
            destination: "bcrt1qdestination",
            feeRate: 2,
            fundingIndex: 0,
            fundingAddress: "bcrt1qfunding"
        )
        XCTAssertNil(exit.savingsPayment, "nothing to fund")
    }

    // MARK: Transfer while failed leaves are retried (pwltr's Android finding on c554a0185)

    /// A confirmed sweep never ends the transfer while failed cooperative leaves are still retried: their value stays
    /// in transfer to savings until the exit ends.
    func testTheTransferStaysWhileFailedLeavesAreRetried() {
        var record = SparkExitFixtures.record(phase: .running)
        record.failedLeafRetrySince = 1000
        XCTAssertTrue(record.isRetryingFailedLeaves)
        XCTAssertFalse(SparkExitManager.isTransferFinished(record, isSweepSeen: true))
        XCTAssertFalse(SparkExitManager.isTransferFinished(record, isSweepSeen: false))

        record.failedLeafRetrySince = nil
        XCTAssertTrue(SparkExitManager.isTransferFinished(record, isSweepSeen: true), "the sweep reached savings")
        XCTAssertFalse(SparkExitManager.isTransferFinished(record, isSweepSeen: false))

        record.phase = .done
        XCTAssertTrue(SparkExitManager.isTransferFinished(record, isSweepSeen: false), "the exit ended")
    }

    /// A sweep seen before the failed-leaf retry starts never ends the transfer: the running recovery already lists
    /// cooperative leaves the operators could not co-sign, and their value stays in transfer.
    func testTheTransferStaysWhileTheRecoveryListsFailedLeavesBeforeTheirRetry() {
        var record = SparkExitFixtures.record(phase: .running)
        let failure = CooperativeRecoveryFailure(leafId: "coop-1", outputTxid: "w", outputVout: 0, error: .operatorsUnavailable(message: "down"))
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("n1")], failed: [failure]))
        XCTAssertNil(record.failedLeafRetrySince)
        XCTAssertFalse(SparkExitManager.isTransferFinished(record, isSweepSeen: true))

        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("n1")]))
        XCTAssertTrue(SparkExitManager.isTransferFinished(record, isSweepSeen: true), "every leaf is on its way to savings")
    }
}
