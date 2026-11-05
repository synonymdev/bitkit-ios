@testable import Bitkit
import BreezSdkSpark
import XCTest

/// SDK 0.28: per-node funding, the fee bump and the retry of cooperative leaves the operators moved on-chain.
final class SparkExitFeeBumpTests: XCTestCase {
    private var chain: FakeSparkExitChain!
    private var sdk: FakeSparkExitRecovering!
    private var saved: [SparkExitRecord] = []
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        chain = FakeSparkExitChain()
        sdk = FakeSparkExitRecovering()
        saved = []
    }

    private func driver() -> SparkExitDriver {
        SparkExitDriver(
            chain: chain,
            recovering: sdk,
            makeSigner: { _ in StubCpfpSigner() },
            save: { [unowned self] in saved.append($0) },
            now: { [unowned self] in clock }
        )
    }

    /// A per-node exit, running on generation 1 at 2 sat/vB, funded by one 20,000 sat payment.
    private func runningRecord(strategy: String? = SparkExitRecord.perNodeStrategy) -> SparkExitRecord {
        var record = SparkExitFixtures.record(phase: .running)
        record.fundingStrategy = strategy
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("n1", cpfp: "03c1")]), at: .distantPast)
        return record
    }

    // MARK: Per-node funding

    func testTheQuotePreparesPerNode() async throws {
        _ = try await SparkExitQuote.prepare(sdk, feeRateSatPerVbyte: 2, destination: "bcrt1qdestination", lostLeafIds: [])

        XCTAssertEqual(sdk.prepareRequests.map(\.fundingStrategy), [.perNode])
    }

    /// The funding ask is one figure: one payment of `single_utxo_sats`, which the SDK splits per node.
    func testTheQuoteAsksForOnePaymentAndCountsTheStepsItFunds() async throws {
        var prepared = SparkExitFixtures.prepared(funding: 12000)
        prepared.funding = RecoveryFunding(
            singleUtxoSats: 12000,
            perBranch: [
                PerBranchFunding(leafId: "leaf-1", fundingSats: 4000),
                PerBranchFunding(leafId: "leaf-1", fundingSats: 3000),
                PerBranchFunding(leafId: "leaf-1", fundingSats: 3000),
            ],
            strategy: .perNode
        )
        sdk.preparedResponse = prepared

        let quote = try await SparkExitQuote.prepare(sdk, feeRateSatPerVbyte: 2, destination: "bcrt1qdestination", lostLeafIds: [])

        XCTAssertEqual(quote.fundingSats, 12000)
        XCTAssertEqual(quote.fundedSteps, 3)
    }

    /// Every rebuild resumes with the strategy the exit was prepared with; one started before 0.28 stays per branch.
    func testRebuildsKeepTheRecordsStrategy() async throws {
        for (strategy, expected) in [(SparkExitRecord.perNodeStrategy, CpfpFundingStrategy.perNode), (nil, .perBranch)] {
            sdk = FakeSparkExitRecovering()
            var record = runningRecord(strategy: strategy)
            record.isRebuilding = true
            sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n2")])]

            _ = try await driver().tick(record)

            XCTAssertEqual(sdk.prepareRequests.map(\.fundingStrategy), [expected])
        }
    }

    /// With a single payment the SDK's fan-out splits it at the funding address: those outputs are the exit's own.
    func testFanOutOutputsAreNotNewFunding() {
        var record = SparkExitFixtures.record(phase: .running)
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("fan", kind: .fanOut),
            SparkExitFixtures.tx("n1", cpfp: SparkExitFixtures.parentHex, dependsOn: ["fan"]),
        ]))
        let utxos = [
            SparkExitFixtures.utxo("fan", vout: 0, value: 5000),
            SparkExitFixtures.utxo("fan", vout: 1, value: 6000),
            SparkExitFixtures.utxo(SparkExitFixtures.parentTxid, value: 900),
            SparkExitFixtures.utxo("topup", value: 3000),
        ]

        XCTAssertEqual(SparkExitMath.newFunding(utxos, record: record).map(\.txid), ["topup"])

        // A rebuild keeps the replaced fan-out among the exit's own transactions.
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("n2")]))
        XCTAssertEqual(SparkExitMath.newFunding(utxos, record: record).map(\.txid), ["topup"])
    }

    /// Case 4: a first payment short of the quote's funding. The hint asks for the rest plus the input fee of the
    /// payment still to send (68 vB at 2 sat/vB), as the Progress top-up does.
    func testThePrestartHintIncludesTheNextInputsFee() {
        let funding = SparkExitMath.prestartFunding(fundingSats: 10000, payments: 1, receivedSats: 6000, feeRate: 2)

        XCTAssertEqual(funding.covered, 10000)
        XCTAssertEqual(funding.toSend, 10136)
        XCTAssertEqual(SparkExitMath.partialFundingSats(receivedSats: 6000, requiredSats: funding.toSend), 4136)

        // Two payments covering the quote are still short of the second input's fee.
        let two = SparkExitMath.prestartFunding(fundingSats: 10000, payments: 2, receivedSats: 10000, feeRate: 2)
        XCTAssertEqual(two.covered, 10136)
        XCTAssertEqual(two.toSend, 10272)

        // One payment covering the quote is enough: nothing more to send.
        let one = SparkExitMath.prestartFunding(fundingSats: 10000, payments: 1, receivedSats: 10000, feeRate: 2)
        XCTAssertEqual(one.covered, 10000)
        XCTAssertEqual(one.toSend, 10000)
        XCTAssertNil(SparkExitMath.partialFundingSats(receivedSats: 10000, requiredSats: one.toSend))
    }

    // MARK: Fee bump

    func testFeeBumpOffersOnlyRatesAboveTheExits() {
        let options = SparkExitFeeBumpOption.options(exitRate: 5, fees: SparkExitNetworkFees(fastest: 12, halfHour: 8))
        XCTAssertEqual(options.map(\.rate), [12, 8])
        XCTAssertEqual(options.map(\.speed), [.fast, .normal])

        let calm = SparkExitFeeBumpOption.options(exitRate: 5, fees: SparkExitNetworkFees(fastest: 4, halfHour: 3))
        XCTAssertEqual(calm.map(\.rate), [6], "a step stuck while estimates look low still gets one higher rate")
    }

    func testFeeBumpCostIsTheExtraFundingAndItsPayment() {
        var option = SparkExitFeeBumpOption(speed: .fast, rate: 12, extraSats: 5000)
        XCTAssertNil(option.totalSats, "not priced until the savings payment fee is known")
        option.paymentFeeSats = 300
        XCTAssertEqual(option.totalSats, 5300)
        XCTAssertEqual(SparkExitFeeBumpOption(speed: .fast, rate: 12, extraSats: 0).totalSats, 0)
    }

    /// The funding the exit holds covers the higher rate: nothing more to pay.
    func testFeeBumpShortfallIsZeroWhenTheFundingCoversTheRate() async throws {
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n1b")])]

        let shortfall = try await driver().feeBumpShortfall(runningRecord(), rate: 10)

        XCTAssertEqual(shortfall, 0)
        XCTAssertEqual(sdk.prepareRequests.first?.feeRateSatPerVbyte, 10)
        XCTAssertEqual(sdk.prepareRequests.first?.fundingStrategy, .perNode)
        XCTAssertEqual(sdk.prepareRequests.first?.selection, .specific(leafIds: ["leaf-1"]))
        XCTAssertEqual(sdk.recoverRequests.first?.fundingInputs, [.p2wpkh(txid: "f0", vout: 1, valueSats: 20000, pubkey: "02ab")])
        XCTAssertTrue(chain.broadcasts.isEmpty, "pricing broadcasts nothing")
    }

    /// Short at the higher rate: what the inputs lack, plus the input fee of the payment to come at the new rate
    /// (68 vB at 10 sat/vB).
    func testFeeBumpShortfallIsWhatTheInputsLackPlusTheNextInput() async throws {
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("f0", vout: 1, value: 20000)]
        sdk.recoverError = SdkError.InsufficientCpfpFunds(requiredSats: 25000, docsUrl: "")

        let shortfall = try await driver().feeBumpShortfall(runningRecord(), rate: 10)

        XCTAssertEqual(shortfall, 5000 + 680)
    }

    /// Paid from savings: the exit waits for the payment as for a top-up, then rebuilds at the new rate. The rebuild is
    /// neither a Redo nor a stall, so it adds no strike and no stall count.
    func testAPaidFeeBumpRebuildsAtTheNewRateOnceTheFundingConfirms() async throws {
        var record = runningRecord()
        record.applyFeeBump(rate: 10, extraSats: 5680, paymentTxid: "bump")

        XCTAssertEqual(record.phase, .needsFunding(requiredSats: 25680))
        XCTAssertEqual(record.fundingShortfallSats, 5680)
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: []), .paid(txid: "bump"))

        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("bump", value: 5680)]
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n1b", cpfp: "03c2")])]
        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .running)
        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(record.feeRateSatPerVbyte, 10)
        XCTAssertEqual(sdk.prepareRequests.first?.feeRateSatPerVbyte, 10)
        XCTAssertEqual(sdk.recoverRequests.first?.fundingInputs.count, 2)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n1b"])
        XCTAssertNil(record.stallRebuilds)
        XCTAssertNil(record.isRedoRebuild)
    }

    /// The funding already covers the higher rate: the exit rebuilds at once and replaces what has not confirmed.
    func testAFeeBumpWithNothingToPayRebuildsAtOnce() async throws {
        var record = runningRecord()
        record.applyFeeBump(rate: 10, extraSats: 0, paymentTxid: nil)

        XCTAssertEqual(record.phase, .running)
        XCTAssertTrue(record.isRebuilding)

        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n1b", cpfp: "03c2")])]
        record = try await driver().tick(record)

        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(sdk.prepareRequests.first?.feeRateSatPerVbyte, 10)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n1b"])
    }

    // MARK: Leaves the operators moved on-chain

    private let failure = CooperativeRecoveryFailure(
        leafId: "coop-1",
        outputTxid: "watchtower",
        outputVout: 0,
        error: .operatorsUnavailable(message: "operators unreachable")
    )

    private func doneWithFailedLeaf() -> SparkExitRecord {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("s", kind: .sweep)], failed: [failure]))
        let done = SparkExitFixtures.recovery([SparkExitFixtures.tx("s", kind: .sweep, status: .confirmed(blockHeight: 990))], failed: [failure])
        sdk.checks = Array(repeating: CheckRecoverFundsResponse(recovery: done, verdict: .done), count: 20)
        var prepared = SparkExitFixtures.prepared(funding: nil, leaves: [])
        prepared.leaves = [RecoverFundsLeaf(leafId: "coop-1", valueSats: 5000, method: .cooperative)]
        sdk.preparedResponse = prepared
        return record
    }

    /// Done with a failed cooperative leaf: the exit keeps it, tries it at once and then at Glow's doubling gaps
    /// from 6 blocks, as a recovery of its own, and shows the wait instead of Done.
    func testDoneWithAFailedLeafKeepsRetryingIt() async throws {
        var record = doneWithFailedLeaf()
        sdk.builds = [SparkExitFixtures.recovery([], failed: [failure])]

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .running)
        XCTAssertTrue(record.isWaitingForOperators)
        XCTAssertEqual(record.failedLeaves, [.init(leafId: "coop-1", valueSats: 5000)])
        XCTAssertEqual(record.failedLeafRetrySince, 1000)
        XCTAssertEqual(sdk.prepareRequests.map(\.selection), [.specific(leafIds: ["coop-1"])])
        XCTAssertEqual(sdk.recoverRequests.first?.fundingInputs, [], "a cooperative recovery needs no funding")
        XCTAssertTrue(SparkExitMath.reminders(record, tip: 1000, now: clock, network: .regtest).isEmpty)

        chain.tip = 1005
        record = try await driver().tick(record)
        XCTAssertEqual(sdk.prepareRequests.count, 1, "not before 6 blocks")

        chain.tip = 1006
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("c1", kind: .cooperative)])]
        record = try await driver().tick(record)

        XCTAssertEqual(sdk.prepareRequests.count, 2)
        XCTAssertEqual(record.generation, 2)
        XCTAssertFalse(record.isWaitingForOperators)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["c1"])

        let landed = SparkExitFixtures.recovery([SparkExitFixtures.tx("c1", kind: .cooperative, status: .confirmed(blockHeight: 1007))])
        sdk.checks = [CheckRecoverFundsResponse(recovery: landed, verdict: .done)]
        chain.tip = 1008
        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .done)
        XCTAssertNil(record.isFailedLeavesReleased)
    }

    /// After about a week (1,008 blocks) the exit lets the leaf go and ends, saying what is left.
    func testAFailedLeafIsReleasedAfterAWeek() async throws {
        var record = doneWithFailedLeaf()
        sdk.builds = [SparkExitFixtures.recovery([], failed: [failure])]
        record = try await driver().tick(record)

        chain.tip = 1000 + SparkExitDriver.releaseBlocks
        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .done)
        XCTAssertEqual(record.isFailedLeavesReleased, true)
        XCTAssertEqual(record.failedLeavesSats, 5000)
        XCTAssertFalse(record.isRetryingFailedLeaves)
    }

    func testIsRetryingFailedLeavesSurvivesTheRecord() throws {
        var record = doneWithFailedLeaf()
        record.failedLeaves = [.init(leafId: "coop-1", valueSats: 5000)]
        record.failedLeafRetrySince = 1000
        record.failedLeafRetriedAt = 1006
        record.isFailedLeavesReleased = false
        record.fundingStrategy = SparkExitRecord.perNodeStrategy

        let decoded = try SparkExitRecordCoder.decode(SparkExitRecordCoder.encode(record))

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.cpfpFundingStrategy, .perNode)
    }

    // MARK: Copy

    /// The released leaves are on-chain under the operators' output, not on Spark.
    func testFailedLeavesCopySaysTheyAreNotOnSpark() {
        let text = t("lightning__spark_exit__failed_leaves", variables: ["amount": "₿ 5 000"])

        XCTAssertTrue(text.contains("₿ 5 000"))
        XCTAssertTrue(text.contains("not on Spark"))
        XCTAssertFalse(text.contains("stayed on Spark"))
        XCTAssertTrue(t("lightning__spark_exit__waiting_operators", variables: ["amount": "₿ 5 000"]).contains("up to a week"))
        XCTAssertTrue(t("lightning__spark_exit__fee_low", variables: ["rate": "2"]).contains("Pay a higher fee"))
    }
}
