@testable import Bitkit
import BitkitCore
import BreezSdkSpark
import XCTest

// MARK: - Fixtures

enum SparkExitFixtures {
    static let parentHex = "020000000111111111111111111111111111111111111111111111111111111111111111110000000000ffffffff01e803000000000000160014222222222222222222222222222222222222222200000000"
    /// The id Spark's regtest node reported for `parentHex`.
    static let parentTxid = "b91b720103788b9ae50dbff918bc375d185df91025b9f6e861efe208909b6adf"

    static func tx(
        _ txid: String,
        kind: RecoveryTxKind = .node,
        cpfp: String? = nil,
        dependsOn: [String] = [],
        status: ExitTransactionStatus = .ready,
        csv: UInt32? = nil
    ) -> RecoveryTransaction {
        RecoveryTransaction(
            kind: kind,
            nodeId: kind == .sweep ? nil : "node-\(txid)",
            txid: txid,
            txHex: "02\(txid)",
            cpfpTxHex: cpfp,
            csvTimelockBlocks: csv,
            dependsOn: dependsOn,
            status: status
        )
    }

    static func recovery(_ transactions: [RecoveryTransaction], failed: [CooperativeRecoveryFailure] = []) -> RecoverFundsResponse {
        RecoverFundsResponse(
            recoverableValueSats: 100_000,
            totalFeeSats: 9000,
            cooperativeFeeSats: 0,
            cpfpFeeSats: 7000,
            fanoutFeeSats: 500,
            refundFeeSats: 1000,
            sweepFeeSats: 500,
            leaves: [RecoverFundsLeaf(leafId: "leaf-1", valueSats: 100_000, method: .unilateral)],
            failed: failed,
            transactions: transactions,
            fundingInputs: [.p2wpkh(txid: "f0", vout: 1, valueSats: 20000, pubkey: "02ab")],
            feeRateSatPerVbyte: 2,
            destination: "bcrt1qdestination"
        )
    }

    static func prepared(funding: UInt64? = 20000, leaves: [String] = ["leaf-1"]) -> PrepareRecoverFundsResponse {
        PrepareRecoverFundsResponse(
            leaves: leaves.map { RecoverFundsLeaf(leafId: $0, valueSats: 100_000, method: .unilateral) },
            skipped: [SkippedLeaf(leafId: "dust", valueSats: 300, reason: .feeExceedsValue)],
            recoverableValueSats: 100_000,
            totalFeeSats: 9000,
            cooperativeFeeSats: 0,
            cpfpFeeSats: 7000,
            fanoutFeeSats: 500,
            refundFeeSats: 1000,
            sweepFeeSats: 500,
            funding: funding.map { RecoveryFunding(singleUtxoSats: $0, perBranch: []) },
            feeRateSatPerVbyte: 2,
            destination: "bcrt1qdestination",
            exitChainState: ExitChainState(
                confirmedNodes: [],
                refunds: [],
                stoppedLeafIds: [],
                unverifiedNodeIds: [],
                unverifiableConfirmedNodeIds: []
            )
        )
    }

    static func record(phase: SparkExitRecord.Phase = .awaitingFunding(requiredSats: 20000)) -> SparkExitRecord {
        SparkExitRecord(
            network: "regtest",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            phase: phase,
            feeRateSatPerVbyte: 2,
            destination: "bcrt1qdestination",
            leafIds: ["leaf-1"],
            funding: [.init(index: 0, address: "bcrt1qfunding", pubkey: "02ab")],
            transferId: "transfer-1",
            expectedSats: 111_000
        )
    }

    /// A version 3 transaction with one input spending `csvParentTxid`:0 under a 10-block BIP68 lock.
    static let csvParentTxid = String(repeating: "11", count: 32)
    static let csvHex = "03000000" + "01" + String(repeating: "11", count: 32) + "00000000" + "00" + "0a000000"
        + "01" + "e803000000000000" + "16" + "0014" + String(repeating: "22", count: 20) + "00000000"

    static func refund(_ txid: String, leafId: String, dependsOn: [String], status: ExitTransactionStatus = .ready) -> RecoveryTransaction {
        RecoveryTransaction(
            kind: .refund,
            nodeId: leafId,
            txid: txid,
            txHex: "02\(txid)",
            cpfpTxHex: "03\(txid)",
            csvTimelockBlocks: nil,
            dependsOn: dependsOn,
            status: status
        )
    }

    /// A version 3 transaction spending output 0 of each of `inputs`, with one output.
    static func rawTx(spending inputs: [String]) -> String {
        "03000000" + String(format: "%02x", inputs.count)
            + inputs.map { Data($0.hexaBytes.reversed()).hex + "00000000" + "00" + "ffffffff" }.joined()
            + "01" + "e803000000000000" + "16" + "0014" + String(repeating: "22", count: 20) + "00000000"
    }

    static func utxo(_ txid: String, vout: UInt32 = 0, value: UInt64, confirmed: Bool = true) -> EsploraUtxo {
        EsploraUtxo(txid: txid, vout: vout, value: value, status: EsploraTxStatus(confirmed: confirmed, blockHeight: confirmed ? 100 : nil))
    }
}

final class FakeSparkExitChain: SparkExitChain, @unchecked Sendable {
    private let lock = NSLock()
    var tip: UInt32 = 1000
    var utxosByAddress: [String: [EsploraUtxo]] = [:]
    var confirmedTxids: Set<String> = []
    var mempoolTxids: Set<String> = []
    var outcome: SparkExitBroadcastOutcome = .accepted
    var isUtxosUnreadable = false
    private(set) var broadcasts: [RecoveryTransaction] = []
    var onBroadcast: (() -> Void)?

    func tipHeight() async throws -> UInt32 {
        tip
    }

    func utxos(address: String) async throws -> [EsploraUtxo] {
        if isUtxosUnreadable {
            throw URLError(.timedOut)
        }
        return lock.withLock { utxosByAddress[address] ?? [] }
    }

    func txStatus(txid: String) async throws -> EsploraTxStatus {
        lock.withLock { EsploraTxStatus(confirmed: confirmedTxids.contains(txid), blockHeight: confirmedTxids.contains(txid) ? 900 : nil) }
    }

    func isKnown(txid: String) async throws -> Bool {
        lock.withLock { confirmedTxids.contains(txid) || mempoolTxids.contains(txid) }
    }

    func broadcast(_ tx: RecoveryTransaction) async -> SparkExitBroadcastOutcome {
        onBroadcast?()
        return lock.withLock {
            broadcasts.append(tx)
            return outcome
        }
    }
}

final class FakeSparkExitRecovering: SparkExitRecovering, @unchecked Sendable {
    var preparedResponse = SparkExitFixtures.prepared()
    var builds: [RecoverFundsResponse] = []
    var checks: [CheckRecoverFundsResponse] = []
    var recoverError: Error?
    /// Thrown by the next prepares, in order.
    var prepareErrors: [Error] = []
    var preparedByRequest: ((PrepareRecoverFundsRequest) -> PrepareRecoverFundsResponse)?
    private(set) var prepareRequests: [PrepareRecoverFundsRequest] = []
    private(set) var recoverRequests: [RecoverFundsRequest] = []
    private(set) var checkedRecoveries: [RecoverFundsResponse] = []

    func prepare(_ request: PrepareRecoverFundsRequest) async throws -> PrepareRecoverFundsResponse {
        prepareRequests.append(request)
        if !prepareErrors.isEmpty {
            throw prepareErrors.removeFirst()
        }
        return preparedByRequest?(request) ?? preparedResponse
    }

    func recover(_ request: RecoverFundsRequest, signer _: CpfpSigner?) async throws -> RecoverFundsResponse {
        recoverRequests.append(request)
        if let recoverError {
            throw recoverError
        }
        return builds.removeFirst()
    }

    func check(_ recovery: RecoverFundsResponse) async throws -> CheckRecoverFundsResponse {
        checkedRecoveries.append(recovery)
        return checks.removeFirst()
    }
}

final class StubCpfpSigner: CpfpSigner, @unchecked Sendable {
    func signPsbt(psbtBytes: Data) async throws -> Data {
        psbtBytes
    }
}

// MARK: - Serializer

final class SparkExitRecordTests: XCTestCase {
    func testRecoveryRoundTripsThroughTheRecord() throws {
        var record = SparkExitFixtures.record(phase: .running)
        let recovery = SparkExitFixtures.recovery(
            [
                SparkExitFixtures.tx("fan", kind: .fanOut, status: .confirmed(blockHeight: 120)),
                SparkExitFixtures.tx("node", cpfp: "03cpfp", dependsOn: ["fan"], status: .ready),
                SparkExitFixtures.tx(
                    "refund",
                    kind: .refund,
                    cpfp: "03cpfp2",
                    dependsOn: ["node"],
                    status: .waitingForTimelock(spendableAtHeight: 2100),
                    csv: 2000
                ),
                SparkExitFixtures.tx("wait", dependsOn: ["node"], status: .waitingForDependencies),
                SparkExitFixtures.tx("unknown", status: .unverified),
                SparkExitFixtures.tx("sweep", kind: .sweep, dependsOn: ["refund"], status: .confirmed(blockHeight: nil)),
            ],
            failed: [
                CooperativeRecoveryFailure(
                    leafId: "a",
                    outputTxid: "o1",
                    outputVout: 0,
                    error: .replacementFeeTooLow(requiredFeeSats: 5, requiredFeeRateSatPerVbyte: 6)
                ),
                CooperativeRecoveryFailure(leafId: "b", outputTxid: "o2", outputVout: 1, error: .operatorsUnavailable(message: "down")),
                CooperativeRecoveryFailure(leafId: "c", outputTxid: "o3", outputVout: 2, error: .generic(message: "boom")),
            ]
        )
        record.adopt(recovery, at: Date(timeIntervalSince1970: 1_700_000_050))
        record.broadcastLog = [.init(
            generation: 1,
            txid: "node",
            attempts: 2,
            rejections: 0,
            lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastOutcome: "accepted",
            isAccepted: true
        )]
        record.phase = .needsFunding(requiredSats: 4321)

        let decoded = try SparkExitRecordCoder.decode(SparkExitRecordCoder.encode(record))

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.recovery?.response, recovery)
    }

    /// A record written before the qa-03 fields reads as before; the new fields round-trip.
    func testReadsARecordWithoutTheNewFieldsAndRoundTripsThem() throws {
        let json = #"""
        {"version":1,"network":"regtest","createdAt":1700000000000,"phase":{"done":{}},"feeRateSatPerVbyte":2,
         "destination":"bcrt1qdestination","leafIds":["leaf-1"],"funding":[{"index":0,"address":"bcrt1qfunding","pubkey":"02ab"}],
         "generation":1,"broadcastLog":[{"generation":1,"txid":"n1","attempts":1,"rejections":0,"lastAttemptAt":1700000000000,
         "lastOutcome":"accepted","isAccepted":true}],"expectedSats":1000,"leftover":[{"txid":"c","vout":0,"valueSats":700}],
         "leftoverSweep":{"txid":"t","txHex":"02","valueSats":400,"isAccepted":true},"skippedLeafCount":0,"failedLeafCount":0,
         "isRebuilding":false}
        """#

        var record = try SparkExitRecordCoder.decode(Data(json.utf8))

        XCTAssertEqual(record.fundingIndex, 0)
        XCTAssertNil(record.broadcastLog[0].isInputSpent)
        XCTAssertNil(record.leftoverSweep?.isConfirmed)
        XCTAssertNil(record.fundingPaymentTxid)
        XCTAssertTrue(record.showsResult, "an accepted sweep not known to be confirmed keeps the result")

        record.broadcastLog[0].isInputSpent = true
        record.leftoverSweep?.isConfirmed = true
        record.fundingPaymentTxid = "pay"
        record.spentStepStrikes = ["r1": 1]
        record.lostLeaves = [.init(leafId: "leaf-1", valueSats: 5000)]
        XCTAssertEqual(try SparkExitRecordCoder.decode(SparkExitRecordCoder.encode(record)), record)
    }

    func testRecoveryUsesSparkSdkSerdeShape() throws {
        let recovery = SparkExitFixtures.recovery([
            SparkExitFixtures.tx("a", cpfp: "03c", status: .confirmed(blockHeight: 7)),
            SparkExitFixtures.tx("b", kind: .fanOut, status: .ready),
            SparkExitFixtures.tx("c", status: .waitingForTimelock(spendableAtHeight: nil)),
        ])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(StoredRecovery(recovery))) as? [String: Any])

        XCTAssertEqual(json["fee_rate_sat_per_vbyte"] as? Int, 2)
        let transactions = try XCTUnwrap(json["transactions"] as? [[String: Any]])
        XCTAssertEqual(transactions[0]["kind"] as? String, "Node")
        XCTAssertEqual(transactions[0]["cpfp_tx_hex"] as? String, "03c")
        XCTAssertEqual((transactions[0]["status"] as? [String: [String: Int]])?["Confirmed"]?["block_height"], 7)
        XCTAssertEqual(transactions[1]["kind"] as? String, "FanOut")
        XCTAssertEqual(transactions[1]["status"] as? String, "Ready")
        XCTAssertTrue(transactions[1]["cpfp_tx_hex"] is NSNull)
        let inputs = try XCTUnwrap(json["funding_inputs"] as? [[String: [String: Any]]])
        XCTAssertEqual(inputs[0]["P2wpkh"]?["value_sats"] as? Int, 20000)
    }

    /// A recovery as the Breez CLI's `recover-funds --output-file` writes it (serde_json, spark-sdk 0.27.2).
    func testReadsARecoveryWrittenBySparkSdk() throws {
        let json = """
        {"recoverable_value_sats":90112,"total_fee_sats":8832,"cooperative_fee_sats":0,"cpfp_fee_sats":8388,
         "fanout_fee_sats":0,"refund_fee_sats":0,"sweep_fee_sats":444,
         "leaves":[{"leaf_id":"l1","value_sats":90112,"method":"Unilateral"}],
         "failed":[{"leaf_id":"l2","output_txid":"t","output_vout":3,"error":{"OperatorsUnavailable":{"message":"timeout"}}}],
         "transactions":[
           {"kind":"Node","node_id":"n1","txid":"aa","tx_hex":"02aa","cpfp_tx_hex":"03bb","csv_timelock_blocks":null,
            "depends_on":[],"status":"Ready"},
           {"kind":"Refund","node_id":"l1","txid":"cc","tx_hex":"02cc","cpfp_tx_hex":"03dd","csv_timelock_blocks":2000,
            "depends_on":["aa"],"status":{"WaitingForTimelock":{"spendable_at_height":3100}}},
           {"kind":"Sweep","node_id":null,"txid":"ee","tx_hex":"02ee","cpfp_tx_hex":null,"csv_timelock_blocks":null,
            "depends_on":["cc"],"status":"WaitingForDependencies"}],
         "funding_inputs":[{"P2wpkh":{"txid":"ff","vout":0,"value_sats":10000,"pubkey":"02cd"}}],
         "fee_rate_sat_per_vbyte":1,"destination":"bc1qexample"}
        """

        let recovery = try JSONDecoder().decode(StoredRecovery.self, from: Data(json.utf8)).response

        XCTAssertEqual(recovery.transactions.map(\.kind), [.node, .refund, .sweep])
        XCTAssertEqual(recovery.transactions[1].status, .waitingForTimelock(spendableAtHeight: 3100))
        XCTAssertEqual(recovery.transactions[1].csvTimelockBlocks, 2000)
        XCTAssertNil(recovery.transactions[2].nodeId)
        XCTAssertEqual(recovery.failed[0].error, .operatorsUnavailable(message: "timeout"))
        XCTAssertEqual(recovery.fundingInputs, [.p2wpkh(txid: "ff", vout: 0, valueSats: 10000, pubkey: "02cd")])
    }

    func testRejectsAnUnknownRecordVersion() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: SparkExitRecordCoder.encode(SparkExitFixtures.record())) as? [String: Any])
        object["version"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try SparkExitRecordCoder.decode(data)) { error in
            XCTAssertEqual(error as? SparkExitRecordCoder.UnsupportedVersion, .init(version: 2))
        }
    }

    func testStoreSavesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spark-exit-\(UUID().uuidString)/spark-exit.json")
        let store = SparkExitStore(url: url)
        defer { try? store.delete() }
        XCTAssertNil(try store.load())

        try store.save(SparkExitFixtures.record())

        XCTAssertEqual(try store.load(), SparkExitFixtures.record())
    }
}

// MARK: - Driver

final class SparkExitDriverTests: XCTestCase {
    private var chain: FakeSparkExitChain!
    private var sdk: FakeSparkExitRecovering!
    private var saved: [SparkExitRecord] = []
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        chain = FakeSparkExitChain()
        sdk = FakeSparkExitRecovering()
        saved = []
    }

    private func driver(withSdk: Bool = true) -> SparkExitDriver {
        SparkExitDriver(
            chain: chain,
            recovering: withSdk ? sdk : nil,
            makeSigner: { _ in StubCpfpSigner() },
            save: { [unowned self] in saved.append($0) },
            now: { [unowned self] in clock }
        )
    }

    func testWaitsForAConfirmedFundingUtxo() async throws {
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("f0", value: 20000, confirmed: false)]

        let record = try await driver().tick(SparkExitFixtures.record())

        XCTAssertEqual(record.phase, .awaitingFunding(requiredSats: 20000))
        XCTAssertTrue(sdk.prepareRequests.isEmpty)
    }

    func testBuildsOnceFundedAndSavesBeforeBroadcasting() async throws {
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("f0", vout: 1, value: 25000)]
        sdk.builds = [SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", cpfp: "03c1"),
            SparkExitFixtures.tx("n2", dependsOn: ["n1"], status: .waitingForDependencies),
        ])]
        var savesAtFirstBroadcast: Int?
        chain.onBroadcast = { [unowned self] in savesAtFirstBroadcast = savesAtFirstBroadcast ?? saved.count }

        let record = try await driver().tick(SparkExitFixtures.record())

        XCTAssertEqual(record.phase, .running)
        XCTAssertEqual(record.generation, 1)
        XCTAssertEqual(savesAtFirstBroadcast, 1)
        XCTAssertEqual(saved.first?.recovery, record.recovery)
        XCTAssertEqual(sdk.recoverRequests.first?.fundingInputs, [.p2wpkh(txid: "f0", vout: 1, valueSats: 25000, pubkey: "02ab")])
        guard case let .specific(leafIds) = sdk.prepareRequests.first?.selection else { return XCTFail("Expected a specific selection") }
        XCTAssertEqual(leafIds, ["leaf-1"])
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n1"])
        XCTAssertEqual(record.broadcastLog.map(\.txid), ["n1"])
    }

    func testValidBroadcastsReadyStepsOnceUntilTheyAreDue() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("n1")]))
        let checked = SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 10)),
            SparkExitFixtures.tx("n2", cpfp: "03c2", dependsOn: ["n1"]),
            SparkExitFixtures.tx("r1", kind: .refund, dependsOn: ["n2"], status: .waitingForTimelock(spendableAtHeight: 3000)),
        ])
        sdk.checks = Array(repeating: CheckRecoverFundsResponse(recovery: checked, verdict: .valid), count: 3)

        record = try await driver().tick(record)
        record = try await driver().tick(record)
        clock = clock.addingTimeInterval(SparkExitDriver.rebroadcastInterval)
        record = try await driver().tick(record)

        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n2", "n2"])
        XCTAssertEqual(record.broadcastLog.first?.attempts, 2)
        XCTAssertEqual(record.claimableAtHeight, 3000)
        XCTAssertEqual(record.recovery?.response, checked)
    }

    func testRetriesARejectedStepAndSurfacesItAfterRepeatedRejections() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        let recovery = SparkExitFixtures.recovery([SparkExitFixtures.tx("n1", cpfp: "03c")])
        record.adopt(recovery, at: Date(timeIntervalSince1970: 1_700_000_050))
        chain.outcome = .rejected("min relay fee not met")
        sdk.checks = Array(repeating: CheckRecoverFundsResponse(recovery: recovery, verdict: .valid), count: 3)

        for _ in 0 ..< 3 {
            record = try await driver().tick(record)
        }

        XCTAssertEqual(chain.broadcasts.count, 3)
        XCTAssertEqual(record.surfacedRejection, "rejected: min relay fee not met")
    }

    func testDoneFinishesAndReadsLeftoverFunding() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("s", kind: .sweep)]))
        let done = SparkExitFixtures.recovery([SparkExitFixtures.tx("s", kind: .sweep, status: .confirmed(blockHeight: 50))])
        sdk.checks = [CheckRecoverFundsResponse(recovery: done, verdict: .done)]
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("change", value: 700)]

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .done)
        XCTAssertFalse(record.isActive)
        XCTAssertEqual(record.leftover, [.init(txid: "change", vout: 0, valueSats: 700)])
        XCTAssertTrue(chain.broadcasts.isEmpty)
        XCTAssertEqual(saved.last, record)
    }

    func testDoneWaitsForTheFundingAddressToBeReadBeforeEnding() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("s", kind: .sweep)]))
        let done = SparkExitFixtures.recovery([SparkExitFixtures.tx("s", kind: .sweep, status: .confirmed(blockHeight: 50))])
        sdk.checks = Array(repeating: CheckRecoverFundsResponse(recovery: done, verdict: .done), count: 2)
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("change", value: 700)]
        chain.isUtxosUnreadable = true

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .running)
        XCTAssertTrue(record.leftover.isEmpty)

        chain.isUtxosUnreadable = false
        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .done)
        XCTAssertEqual(record.leftover, [.init(txid: "change", vout: 0, valueSats: 700)])
    }

    func testRedoRebuildsAsANewGenerationAndNeverSendsTheOldOne() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        let old = SparkExitFixtures.recovery([SparkExitFixtures.tx("old")])
        record.adopt(old)
        record.broadcastLog = [.init(
            generation: 1,
            txid: "old",
            attempts: 1,
            rejections: 0,
            lastAttemptAt: clock,
            lastOutcome: "accepted",
            isAccepted: true
        )]
        sdk.checks = [CheckRecoverFundsResponse(recovery: old, verdict: .redo(reason: .onChainStateDiverged))]
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("new", cpfp: "03n")])]

        record = try await driver().tick(record)

        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(record.recovery?.response.transactions.map(\.txid), ["new"])
        XCTAssertEqual(record.broadcastLog.map(\.txid), ["new"])
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["new"])
        XCTAssertEqual(sdk.recoverRequests.first?.fundingInputs, [.p2wpkh(txid: "f0", vout: 1, valueSats: 20000, pubkey: "02ab")])
    }

    func testRebuildThatNeedsMoreFeesAsksForFunding() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("old")]))
        sdk.checks = [CheckRecoverFundsResponse(recovery: SparkExitFixtures.recovery([]), verdict: .redo(reason: .onChainStateDiverged))]
        sdk.recoverError = SdkError.InsufficientCpfpFunds(requiredSats: 3000, docsUrl: "")

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .needsFunding(requiredSats: 3000))
        XCTAssertTrue(record.isActive)
    }

    /// The headless regtest run: a quote for 8,541, five payments of 9,035 together, and the SDK asking for 9,085
    /// in all once it priced the five inputs. Only the 50 missing is asked for.
    func testInsufficientFundsAsksOnlyForWhatTheInputsLack() async throws {
        let values: [UInt64] = [5000, 2000, 1000, 535, 500]
        chain.utxosByAddress["bcrt1qfunding"] = values.enumerated().map { SparkExitFixtures.utxo("u\($0.offset)", value: $0.element) }
        sdk.recoverError = SdkError.InsufficientCpfpFunds(requiredSats: 9085, docsUrl: "")

        var record = try await driver().tick(SparkExitFixtures.record(phase: .awaitingFunding(requiredSats: 8541)))

        XCTAssertEqual(sdk.recoverRequests.first?.fundingInputs.count, 5)
        XCTAssertEqual(record.fundedSats, 9035)
        XCTAssertEqual(record.phase, .needsFunding(requiredSats: 9085))
        XCTAssertEqual(record.fundingShortfallSats, 50)

        chain.utxosByAddress["bcrt1qfunding", default: []] += [SparkExitFixtures.utxo("t1", value: 30), SparkExitFixtures.utxo("t2", value: 30)]
        sdk.recoverError = nil
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n1")])]
        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .running)
        XCTAssertEqual(sdk.recoverRequests.last?.fundingInputs.count, 7)
    }

    /// After a Redo the first inputs are partly spent: what they hold now is the CPFP change at the address.
    func testRebuildShortfallCountsWhatTheSpentInputsStillHold() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        let old = SparkExitFixtures.recovery([SparkExitFixtures.tx("n1", cpfp: SparkExitFixtures.parentHex)])
        record.adopt(old)
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo(SparkExitFixtures.parentTxid, value: 13000)]
        sdk.checks = [CheckRecoverFundsResponse(recovery: old, verdict: .redo(reason: .onChainStateDiverged))]
        sdk.recoverError = SdkError.InsufficientCpfpFunds(requiredSats: 15000, docsUrl: "")

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .needsFunding(requiredSats: 22000))
        XCTAssertEqual(record.fundingShortfallSats, 2000)
    }

    /// Gen 1's change outlives a rebuild that needed no funding; a later shortfall still counts it as held.
    func testChangeOfAnEarlierGenerationIsNotNewFunding() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("n1", cpfp: SparkExitFixtures.parentHex)]))
        let second = SparkExitFixtures.recovery([SparkExitFixtures.tx("n2")])
        record.adopt(second)
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo(SparkExitFixtures.parentTxid, value: 13000)]
        sdk.checks = [CheckRecoverFundsResponse(recovery: second, verdict: .redo(reason: .onChainStateDiverged))]
        sdk.recoverError = SdkError.InsufficientCpfpFunds(requiredSats: 15000, docsUrl: "")

        record = try await driver().tick(record)

        XCTAssertEqual(record.earlierCpfpTxids, [SparkExitFixtures.parentTxid])
        XCTAssertEqual(record.fundingShortfallSats, 2000)
        record = try await driver().tick(record)
        XCTAssertEqual(record.funding.count, 1, "the change is not adopted as a top-up")
    }

    func testTopUpIgnoresCpfpChangeChainedToTheFundingAddress() async throws {
        var record = SparkExitFixtures.record(phase: .needsFunding(requiredSats: 23000))
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)
        record.recovery = StoredRecovery(SparkExitFixtures.recovery([SparkExitFixtures.tx("n1", cpfp: SparkExitFixtures.parentHex)]))
        chain.utxosByAddress["bcrt1qfunding"] = [
            SparkExitFixtures.utxo("f0", vout: 1, value: 20000),
            SparkExitFixtures.utxo(SparkExitFixtures.parentTxid, value: 9000),
        ]

        record = try await driver().tick(record)
        XCTAssertEqual(record.phase, .needsFunding(requiredSats: 23000))
        XCTAssertEqual(record.fundingShortfallSats, 3000)
        XCTAssertTrue(sdk.prepareRequests.isEmpty)

        chain.utxosByAddress["bcrt1qfunding", default: []].append(SparkExitFixtures.utxo("topup", value: 3000))
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n2")])]
        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .running)
        XCTAssertEqual(sdk.recoverRequests.first?.fundingInputs.count, 2)
    }

    func testRedoIsSavedBeforeRebuildingSoTheOldGenerationIsNeverSentWithoutTheSdk() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        let old = SparkExitFixtures.recovery([SparkExitFixtures.tx("old")])
        record.adopt(old, at: clock)
        sdk.checks = [CheckRecoverFundsResponse(recovery: old, verdict: .redo(reason: .onChainStateDiverged))]

        // Built a minute ago: the rebuild waits, but the diverged state is already saved.
        clock = clock.addingTimeInterval(60)
        record = try await driver().tick(record)
        XCTAssertTrue(record.isRebuilding)
        XCTAssertTrue(saved.first?.isRebuilding == true)
        XCTAssertTrue(sdk.recoverRequests.isEmpty)

        record = try await driver(withSdk: false).tick(record)
        XCTAssertTrue(chain.broadcasts.isEmpty)

        clock = clock.addingTimeInterval(SparkExitDriver.rebuildInterval)
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("new")])]
        record = try await driver().tick(record)
        XCTAssertFalse(record.isRebuilding)
        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["new"])
    }

    func testCooperativeLeavesTheOperatorsCouldNotSignAreTriedAgain() async throws {
        sdk.preparedResponse = SparkExitFixtures.prepared(funding: nil)
        sdk.builds = [SparkExitFixtures.recovery(
            [],
            failed: [CooperativeRecoveryFailure(leafId: "leaf-1", outputTxid: "o", outputVout: 0, error: .operatorsUnavailable(message: "down"))]
        )]

        let record = try await driver().tick(SparkExitFixtures.record(phase: .awaitingFunding(requiredSats: 0)))

        XCTAssertEqual(record.phase, .awaitingFunding(requiredSats: 0))
        XCTAssertEqual(record.failedLeafCount, 1)
        XCTAssertNil(record.recovery)
    }

    func testRebuildWithNothingLeftEndsTheExit() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("old")]), at: .distantPast)
        record.isRebuilding = true
        sdk.preparedResponse = SparkExitFixtures.prepared(leaves: [])

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .done)
    }

    func testRebuildWaitsWhileALeafIsUnverified() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("old")]), at: .distantPast)
        record.isRebuilding = true
        var prepared = SparkExitFixtures.prepared(leaves: [])
        prepared.skipped = [SkippedLeaf(leafId: "leaf-1", valueSats: 100_000, reason: .unverified)]
        sdk.preparedResponse = prepared

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .running)
        XCTAssertTrue(record.isRebuilding)
    }

    func testResumesAfterARestartWithoutRepeatingBroadcasts() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spark-exit-\(UUID().uuidString)/spark-exit.json")
        let store = SparkExitStore(url: url)
        defer { try? store.delete() }
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("f0", value: 20000)]
        let built = SparkExitFixtures.recovery([SparkExitFixtures.tx("n1", cpfp: "03c")])
        sdk.builds = [built]
        let persisting = SparkExitDriver(
            chain: chain,
            recovering: sdk,
            makeSigner: { _ in StubCpfpSigner() },
            save: { try store.save($0) },
            now: { [unowned self] in clock }
        )
        try await persisting.tick(SparkExitFixtures.record())

        let reloaded = try XCTUnwrap(store.load())
        sdk.checks = [CheckRecoverFundsResponse(recovery: built, verdict: .valid)]
        try await persisting.tick(reloaded)

        XCTAssertEqual(reloaded.phase, .running)
        XCTAssertEqual(reloaded.generation, 1)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n1"])
        XCTAssertEqual(sdk.recoverRequests.count, 1)
    }

    func testWithoutTheSdkBroadcastsStepsWhoseParentsConfirmedAndTimelocksMatured() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .ready),
            SparkExitFixtures.tx("n2", cpfp: "03c", dependsOn: ["n1"], status: .waitingForDependencies),
            SparkExitFixtures.tx("r1", kind: .refund, dependsOn: ["n2"], status: .waitingForTimelock(spendableAtHeight: 990)),
            SparkExitFixtures.tx("r2", kind: .refund, dependsOn: ["n1"], status: .waitingForTimelock(spendableAtHeight: 1500)),
        ]))
        chain.tip = 1000
        chain.confirmedTxids = ["n1"]

        record = try await driver(withSdk: false).tick(record)

        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n2"])
        XCTAssertEqual(record.recovery?.response.transactions.first?.status, .confirmed(blockHeight: 900))
        XCTAssertEqual(record.phase, .running)
    }

    func testCheckSeesStepsTheChainHostShowsInABlock() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("fanout", status: .ready),
            SparkExitFixtures.tx("n1", cpfp: "03c1", dependsOn: ["fanout"], status: .waitingForDependencies),
            SparkExitFixtures.tx("n2", cpfp: "03c2", dependsOn: ["n1"], status: .waitingForDependencies),
            SparkExitFixtures.tx("r1", kind: .refund, dependsOn: ["n3"], status: .waitingForDependencies),
        ]))
        chain.confirmedTxids = ["fanout", "n1", "r1"]
        let stored = try XCTUnwrap(record.recovery?.response)
        sdk.checks = [CheckRecoverFundsResponse(recovery: stored, verdict: .valid)]

        _ = try await driver().tick(record)

        let statuses = sdk.checkedRecoveries.first?.transactions.map(\.status)
        XCTAssertEqual(statuses, [
            .confirmed(blockHeight: 900),
            .confirmed(blockHeight: 900),
            .waitingForDependencies,
            .waitingForDependencies,
        ])
    }

    // MARK: qa-03

    /// The keyless pass counts a relative timelock from the confirmation height of the parent each input spends,
    /// and sends a step only once it would be valid in the next block.
    func testWithoutTheSdkWaitsForEachRelativeTimelockFromItsParentsHeight() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        let fromHex = RecoveryTransaction(
            kind: .refund,
            nodeId: "leaf-1",
            txid: "r1",
            txHex: SparkExitFixtures.csvHex,
            cpfpTxHex: nil,
            csvTimelockBlocks: 10,
            dependsOn: [SparkExitFixtures.csvParentTxid],
            status: .waitingForDependencies
        )
        let fallback = SparkExitFixtures.tx("r2", kind: .refund, dependsOn: ["n1"], status: .waitingForDependencies, csv: 5)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 995)),
            fromHex,
            fallback,
        ]))
        chain.confirmedTxids = [SparkExitFixtures.csvParentTxid]

        chain.tip = 908
        record = try await driver(withSdk: false).tick(record)
        XCTAssertTrue(chain.broadcasts.isEmpty)
        XCTAssertEqual(record.recovery?.response.transactions[1].status, .waitingForTimelock(spendableAtHeight: 910))
        XCTAssertEqual(record.recovery?.response.transactions[2].status, .waitingForTimelock(spendableAtHeight: 1000))

        chain.tip = 909
        record = try await driver(withSdk: false).tick(record)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["r1"])

        chain.tip = 999
        _ = try await driver(withSdk: false).tick(record)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["r1", "r2"])
    }

    func testWithoutTheSdkSkipsATimelockedStepWhoseParentHeightIsUnknown() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: nil)),
            SparkExitFixtures.tx("r1", kind: .refund, dependsOn: ["n1"], status: .waitingForDependencies, csv: 5),
        ]))
        chain.tip = 5000

        _ = try await driver(withSdk: false).tick(record)

        XCTAssertTrue(chain.broadcasts.isEmpty)
    }

    /// A timelock not yet final is retried and never counts towards the rejection alert.
    func testNotMatureIsNeverARejection() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("n1")]))
        chain.outcome = .notMature("non-BIP68-final")

        for _ in 0 ..< 4 {
            record = try await driver(withSdk: false).tick(record)
        }

        XCTAssertEqual(chain.broadcasts.count, 4)
        XCTAssertEqual(record.broadcastLog.first?.rejections, 0)
        XCTAssertNil(record.broadcastLog.first?.isInputSpent)
        XCTAssertNil(record.surfacedRejection)
    }

    /// The operators went first: with its parents confirmed, missing inputs mean another transaction spent the
    /// step's input. The keyless pass stops sending it; the SDK path still follows its check.
    func testWithoutTheSdkStopsAStepWhoseInputSomeoneElseSpent() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 10)),
            SparkExitFixtures.tx("n2", cpfp: "03c", dependsOn: ["n1"]),
        ]))
        chain.outcome = .inputsMissing("bad-txns-inputs-missingorspent")

        record = try await driver(withSdk: false).tick(record)
        record = try await driver(withSdk: false).tick(record)

        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n2"])
        XCTAssertEqual(record.broadcastLog.first?.isInputSpent, true)
        XCTAssertEqual(record.broadcastLog.first?.rejections, 0)

        sdk.checks = try [CheckRecoverFundsResponse(recovery: XCTUnwrap(record.recovery?.response), verdict: .valid)]
        record = try await driver().tick(record)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n2", "n2"])
    }

    /// qa-03 shared-ancestor race, with the operators down so nothing else diverges: another wallet's CPFP child
    /// confirmed node n1, ours never will, and n2's child spends our child's change. `checkRecoverFunds` answers
    /// Valid, so the exit rebuilds from the same funding and never sends the dead chain again.
    func testAFeeChainThatLostARaceRebuildsWithoutResendingIt() async throws {
        let funding = String(repeating: "f0", count: 32)
        let ourChild = SparkExitFixtures.rawTx(spending: [funding])
        let chained = try SparkExitFixtures.rawTx(spending: [XCTUnwrap(SparkExitTxid.txid(hex: ourChild))])
        var record = SparkExitFixtures.record(phase: .running)
        record.funding[0] = .init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: funding, vout: 0, valueSats: 20000)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", cpfp: ourChild),
            SparkExitFixtures.tx("n2", cpfp: chained, dependsOn: ["n1"], status: .waitingForDependencies),
        ]), at: Date(timeIntervalSince1970: 1_700_000_050))
        chain.confirmedTxids = ["n1"]
        sdk.checks = [CheckRecoverFundsResponse(recovery: SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", cpfp: ourChild, status: .confirmed(blockHeight: 10)),
            SparkExitFixtures.tx("n2", cpfp: chained, dependsOn: ["n1"]),
        ]), verdict: .valid)]
        let fresh = SparkExitFixtures.rawTx(spending: [funding])
        sdk.builds = [SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 10)),
            SparkExitFixtures.tx("n2", cpfp: fresh, dependsOn: ["n1"]),
        ])]

        record = try await driver().tick(record)

        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n2"])
        XCTAssertEqual(chain.broadcasts.map(\.cpfpTxHex), [fresh])
        XCTAssertEqual(sdk.recoverRequests.first?.fundingInputs, [.p2wpkh(txid: funding, vout: 0, valueSats: 20000, pubkey: "02ab")])
        XCTAssertNil(record.surfacedRejection)
    }

    func testAChildStillInTheMempoolIsNotDead() async throws {
        let ourChild = SparkExitFixtures.rawTx(spending: [String(repeating: "f0", count: 32)])
        let childTxid = try XCTUnwrap(SparkExitTxid.txid(hex: ourChild))
        let chained = SparkExitFixtures.rawTx(spending: [childTxid])
        var record = SparkExitFixtures.record(phase: .running)
        let checked = SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", cpfp: ourChild, status: .confirmed(blockHeight: 10)),
            SparkExitFixtures.tx("n2", cpfp: chained, dependsOn: ["n1"]),
        ])
        record.adopt(checked, at: Date(timeIntervalSince1970: 1_700_000_050))
        chain.confirmedTxids = ["n1"]
        chain.mempoolTxids = [childTxid]
        sdk.checks = [CheckRecoverFundsResponse(recovery: checked, verdict: .valid)]

        record = try await driver().tick(record)

        XCTAssertEqual(record.generation, 1)
        XCTAssertEqual(chain.broadcasts.map(\.cpfpTxHex), [chained])
    }

    /// The safety net: a step whose parents confirmed and whose child keeps failing to pay for it rebuilds the exit
    /// once, without counting towards the rejection alert. After that rebuild its failures are rejections again.
    func testAStepWhoseFeeChainKeepsFailingRebuildsOnceThenSurfaces() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        let first = SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 10)),
            SparkExitFixtures.tx("n2", cpfp: "03c", dependsOn: ["n1"]),
        ])
        let second = SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 10)),
            SparkExitFixtures.tx("n2", cpfp: "03d", dependsOn: ["n1"]),
        ])
        record.adopt(first, at: Date(timeIntervalSince1970: 1_700_000_050))
        chain.outcome = .rejected("min relay fee not met, 0 < 17")
        sdk.checks = Array(repeating: CheckRecoverFundsResponse(recovery: first, verdict: .valid), count: 3)
            + Array(repeating: CheckRecoverFundsResponse(recovery: second, verdict: .valid), count: 2)
        sdk.builds = [second]

        record = try await driver().tick(record)
        record = try await driver().tick(record)
        XCTAssertEqual(record.broadcastLog.first?.feeChainFailures, 2)
        XCTAssertEqual(record.broadcastLog.first?.rejections, 0)

        record = try await driver().tick(record)
        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(record.feeChainRebuildTxids, ["n2"])

        record = try await driver().tick(record)
        record = try await driver().tick(record)
        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(record.surfacedRejection, "rejected: min relay fee not met, 0 < 17")
    }

    /// qa-03 repro: an older state's refund took the leaf, so every rebuild reproduces the same refund, whose input
    /// is spent. After two such rebuilds the leaf is lost and the exit goes on with the rest.
    func testALeafAnOlderStateClaimedIsLostAfterTwoRebuildsThatReproduceItsRefund() async throws {
        var record = SparkExitRecord(
            network: "regtest",
            createdAt: clock,
            phase: .running,
            feeRateSatPerVbyte: 2,
            destination: "bcrt1qdestination",
            leafIds: ["leaf-1", "leaf-2"],
            funding: [.init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)],
            expectedSats: 150_000
        )
        let stuck = SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 10)),
            SparkExitFixtures.refund("r1", leafId: "leaf-1", dependsOn: ["n1"]),
            SparkExitFixtures.refund("r2", leafId: "leaf-2", dependsOn: ["n1"], status: .waitingForTimelock(spendableAtHeight: 5000)),
        ])
        record.adopt(stuck, at: clock)
        let redo = CheckRecoverFundsResponse(recovery: stuck, verdict: .redo(reason: .onChainStateDiverged))
        sdk.checks = [CheckRecoverFundsResponse(recovery: stuck, verdict: .valid), redo, redo]
        sdk.builds = [stuck, stuck]
        chain.outcome = .inputsMissing(#"sendrawtransaction RPC error: {"code":-25}"#)

        record = try await driver().tick(record)
        XCTAssertEqual(record.broadcastLog.first { $0.txid == "r1" }?.isInputSpent, true)

        clock = clock.addingTimeInterval(SparkExitDriver.rebuildInterval)
        record = try await driver().tick(record)
        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(record.spentStepStrikes, ["r1": 1])
        XCTAssertNil(record.lostLeaves)

        clock = clock.addingTimeInterval(SparkExitDriver.rebuildInterval)
        record = try await driver().tick(record)
        XCTAssertEqual(record.generation, 2, "the build that found the lost leaf is not adopted")
        XCTAssertEqual(record.lostLeaves, [.init(leafId: "leaf-1", valueSats: 100_000)])
        XCTAssertEqual(record.lostSats, 100_000)
        XCTAssertTrue(record.isRebuilding)
        XCTAssertEqual(record.phase, .running)
        XCTAssertEqual(SparkExitMath.reminders(record, tip: 1000, now: clock, network: .regtest).first?.id, "lost-1")

        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 10)), SparkExitFixtures.refund(
            "r2",
            leafId: "leaf-2",
            dependsOn: ["n1"],
            status: .waitingForTimelock(spendableAtHeight: 5000)
        )])]
        record = try await driver().tick(record)
        guard case let .specific(leafIds) = sdk.prepareRequests.last?.selection else { return XCTFail("Expected a specific selection") }
        XCTAssertEqual(leafIds, ["leaf-2"])
        XCTAssertEqual(record.generation, 3)
        XCTAssertFalse(record.isRebuilding)
    }

    func testAnExitWhoseEveryLeafAnOlderStateClaimedFails() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        let stuck = SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 10)),
            SparkExitFixtures.refund("r1", leafId: "leaf-1", dependsOn: ["n1"]),
        ])
        record.adopt(stuck, at: .distantPast)
        record.spentStepStrikes = ["r1": 1]
        record.broadcastLog = [.init(
            generation: 1,
            txid: "r1",
            attempts: 1,
            rejections: 0,
            lastAttemptAt: clock,
            lastOutcome: "inputs missing",
            isAccepted: false,
            isInputSpent: true
        )]
        sdk.checks = [CheckRecoverFundsResponse(recovery: stuck, verdict: .redo(reason: .onChainStateDiverged))]
        sdk.builds = [stuck]

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .failed(reason: "Claimed by an older state"))
        XCTAssertEqual(record.lostSats, 100_000)
        XCTAssertEqual(SparkExitMath.reminders(record, tip: 1000, now: clock, network: .regtest).map(\.id), ["lost-1"])
    }

    /// A rebuild that replaces the spent step, the operators having gone first, is no strike.
    func testARebuildThatReplacesTheSpentStepIsNoStrike() {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.refund("r1", leafId: "leaf-1", dependsOn: [])]))
        record.broadcastLog = [.init(
            generation: 1,
            txid: "r1",
            attempts: 1,
            rejections: 0,
            lastAttemptAt: clock,
            lastOutcome: "inputs missing",
            isAccepted: false,
            isInputSpent: true
        )]

        XCTAssertEqual(
            record.strikes(rebuiltInto: SparkExitFixtures.recovery([SparkExitFixtures.refund("r1b", leafId: "leaf-1", dependsOn: [])])),
            [:]
        )
        XCTAssertEqual(
            record.strikes(rebuiltInto: SparkExitFixtures.recovery([SparkExitFixtures.refund("r1", leafId: "leaf-1", dependsOn: [])])),
            ["r1": 1]
        )
    }

    /// Top-ups join the exit under its own funding index, and the build signs with that index's key.
    func testFundingAndSigningUseTheRecordsFundingIndex() async throws {
        var record = SparkExitFixtures.record()
        record.funding = [.init(index: 3, address: "bcrt1qfunding3", pubkey: "03cd")]
        chain.utxosByAddress["bcrt1qfunding3"] = [SparkExitFixtures.utxo("f0", value: 12000), SparkExitFixtures.utxo("f1", value: 9000)]
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n1")])]
        var indexes: [UInt32] = []
        let driver = SparkExitDriver(chain: chain, recovering: sdk, makeSigner: { index in
            indexes.append(index)
            return StubCpfpSigner()
        }, save: { _ in })

        record = try await driver.tick(record)

        XCTAssertEqual(record.funding.map(\.index), [3, 3])
        XCTAssertEqual(indexes, [3])
    }

    /// A fee-ladder leaf whose refund cannot pay its fee fails a `Specific` rebuild as a whole: that leaf stays
    /// behind and the rest are prepared again.
    func testARebuildLeavesBehindTheLeafThatCannotPayItsRefund() async throws {
        var record = twoLeafRecord()
        let first = SparkExitFixtures.recovery([SparkExitFixtures.tx("old")])
        record.adopt(first, at: .distantPast)
        sdk.checks = [CheckRecoverFundsResponse(recovery: first, verdict: .redo(reason: .onChainStateDiverged))]
        sdk.prepareErrors = [SdkError.SparkError("Leaf leaf-1 cannot be exited: its refund cannot pay its own fee at this fee rate")]
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("new")])]

        record = try await driver().tick(record)

        XCTAssertEqual(sdk.prepareRequests.map(\.selection), [.specific(leafIds: ["leaf-1", "leaf-2"]), .specific(leafIds: ["leaf-2"])])
        XCTAssertEqual(record.leftBehindLeaves?.map(\.leafId), ["leaf-1"])
        XCTAssertEqual(record.leftBehindSats, 100_000)
        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(record.exitLeafIds, ["leaf-2"])
    }

    /// An error that names no leaf falls back to `RecoverableOnly`, and what it leaves out stays behind.
    func testARebuildFallsBackToRecoverableOnlyWhenTheErrorNamesNoLeaf() async throws {
        var record = twoLeafRecord()
        let first = SparkExitFixtures.recovery([SparkExitFixtures.tx("old")])
        record.adopt(first, at: .distantPast)
        sdk.checks = [CheckRecoverFundsResponse(recovery: first, verdict: .redo(reason: .onChainStateDiverged))]
        sdk.prepareErrors = [SdkError.SparkError("A leaf cannot be exited")]
        sdk.preparedResponse = SparkExitFixtures.prepared(leaves: ["leaf-2"])
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("new")])]

        record = try await driver().tick(record)

        XCTAssertEqual(sdk.prepareRequests.last?.selection, .recoverableOnly)
        XCTAssertEqual(record.leftBehindLeaves?.map(\.leafId), ["leaf-1"])
        XCTAssertEqual(record.generation, 2)
    }

    func testAnExitWithNoLeafLeftToExitFails() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        let first = SparkExitFixtures.recovery([SparkExitFixtures.tx("old")])
        record.adopt(first, at: .distantPast)
        sdk.checks = [CheckRecoverFundsResponse(recovery: first, verdict: .redo(reason: .onChainStateDiverged))]
        sdk.prepareErrors = [SdkError.SparkError("Leaf leaf-1 cannot be exited: its refund cannot pay its own fee at this fee rate")]

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .failed(reason: "No leaf can be exited"))
        XCTAssertEqual(record.leftBehindSats, 100_000)
        XCTAssertTrue(sdk.recoverRequests.isEmpty)
        XCTAssertEqual(SparkExitMath.reminders(record, tip: 1000, now: clock, network: .regtest).map(\.id), ["failed"])
    }

    /// The last leaf lost on a tick that could not read the funding address: the next tick ends the exit through the
    /// no-leaf path, still as lost, and only the lost notification fires.
    func testASingleLostLeafEndedThroughTheNoLeafPathNotifiesOnlyTheLoss() async throws {
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("old")]), at: .distantPast)
        record.lostLeaves = [.init(leafId: "leaf-1", valueSats: 100_000)]
        record.isRebuilding = true

        record = try await driver().tick(record)

        XCTAssertEqual(record.phase, .failed(reason: SparkExitRecord.lostReason))
        XCTAssertTrue(sdk.prepareRequests.isEmpty)
        XCTAssertEqual(SparkExitMath.reminders(record, tip: 1000, now: clock, network: .regtest).map(\.id), ["lost-1"])
        record.phase = .failed(reason: "No leaf can be exited")
        XCTAssertEqual(SparkExitMath.reminders(record, tip: 1000, now: clock, network: .regtest).map(\.id), ["lost-1"])
    }

    /// qa-03: a failed or lost-leaf exit with nothing left to sweep ended at once and Emergency exit opened a new
    /// intro, so the user never saw why.
    func testAFailedOrLostLeafResultStaysReachableUntilSeen() {
        var failed = SparkExitFixtures.record(phase: .failed(reason: "No leaf can be exited"))
        XCTAssertFalse(failed.needsDriving)
        XCTAssertTrue(failed.showsResult)
        failed.isResultSeen = true
        XCTAssertFalse(failed.showsResult)

        var partlyLost = SparkExitFixtures.record(phase: .done)
        XCTAssertFalse(partlyLost.showsResult)
        partlyLost.lostLeaves = [.init(leafId: "leaf-1", valueSats: 4000)]
        XCTAssertTrue(partlyLost.showsResult)
        partlyLost.isResultSeen = true
        XCTAssertFalse(partlyLost.showsResult)

        var running = SparkExitFixtures.record(phase: .running)
        running.lostLeaves = [.init(leafId: "leaf-1", valueSats: 4000)]
        XCTAssertFalse(running.hasUnseenResult)
    }

    private func twoLeafRecord() -> SparkExitRecord {
        SparkExitRecord(
            network: "regtest",
            createdAt: clock,
            phase: .running,
            feeRateSatPerVbyte: 2,
            destination: "bcrt1qdestination",
            leafIds: ["leaf-1", "leaf-2"],
            funding: [.init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 1, valueSats: 20000)],
            expectedSats: 150_000
        )
    }

    func testDoesNothingOnceFinished() async throws {
        let record = try await driver().tick(SparkExitFixtures.record(phase: .done))

        XCTAssertEqual(record.phase, .done)
        XCTAssertTrue(saved.isEmpty)
    }
}

// MARK: - Fees and funding

/// The entry point the background tasks call, from a cold launch with no UI.
final class SparkExitBackgroundRunTests: XCTestCase {
    private var chain: FakeSparkExitChain!
    private var sdk: FakeSparkExitRecovering!
    private var store: SparkExitStore!
    private var connects: [TimeInterval] = []

    override func setUp() {
        super.setUp()
        chain = FakeSparkExitChain()
        sdk = FakeSparkExitRecovering()
        store = SparkExitStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("spark-exit-\(UUID().uuidString)/spark-exit.json"))
        connects = []
    }

    override func tearDown() {
        try? store.delete()
        super.tearDown()
    }

    private func backgroundRun(deadline: TimeInterval = 25, connects sdkConnects: Bool = true) -> SparkExitBackgroundRun {
        let store = store!
        return SparkExitBackgroundRun(
            load: { try store.load() },
            makeDriver: { chain, recovering in
                SparkExitDriver(chain: chain, recovering: recovering, makeSigner: { _ in StubCpfpSigner() }, save: { try store.save($0) })
            },
            chain: chain,
            connected: nil,
            connect: { [unowned self] timeout in
                connects.append(timeout)
                return sdkConnects ? sdk : nil
            },
            deadline: Date(timeIntervalSinceNow: deadline)
        )
    }

    private func savedRunningExit(_ transactions: [RecoveryTransaction]) throws -> RecoverFundsResponse {
        var record = SparkExitFixtures.record(phase: .running)
        let recovery = SparkExitFixtures.recovery(transactions)
        record.adopt(recovery)
        try store.save(record)
        return recovery
    }

    func testColdStartSendsStoredStepsThenChecksWithTheSdkOnly() async throws {
        let recovery = try savedRunningExit([SparkExitFixtures.tx("n1", cpfp: "03c")])
        sdk.checks = [CheckRecoverFundsResponse(recovery: recovery, verdict: .valid)]

        let outcome = await backgroundRun().run()

        XCTAssertTrue(outcome.isConnected)
        XCTAssertEqual(connects.count, 1)
        XCTAssertEqual(sdk.checkedRecoveries.count, 1)
        // The keyless pass sent it; the SDK pass found it accepted and did not send it again.
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n1"])
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.broadcastLog.map(\.txid), ["n1"])
        XCTAssertEqual(saved.broadcastLog.first?.isAccepted, true)
        XCTAssertNotNil(outcome.seconds[.keyless])
        XCTAssertNotNil(outcome.seconds[.check])
        XCTAssertNotNil(outcome.seconds[.broadcast])
    }

    func testColdStartSignsTheBuildOnceFundingConfirmed() async throws {
        try store.save(SparkExitFixtures.record())
        chain.utxosByAddress["bcrt1qfunding"] = [SparkExitFixtures.utxo("f0", vout: 1, value: 25000)]
        sdk.builds = [SparkExitFixtures.recovery([SparkExitFixtures.tx("n1", cpfp: "03c1")])]

        let outcome = await backgroundRun().run()

        XCTAssertEqual(outcome.record?.phase, .running)
        XCTAssertEqual(sdk.recoverRequests.count, 1)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n1"])
        XCTAssertEqual(try store.load()?.generation, 1)
        XCTAssertNotNil(outcome.seconds[.sign])
    }

    func testExpiryMidStepLeavesAWholeRecordAndTheNextRunSendsNothingTwice() async throws {
        let recovery = try savedRunningExit([SparkExitFixtures.tx("n1", cpfp: "03c1"), SparkExitFixtures.tx("n2", cpfp: "03c2")])
        // The OS expires the run while the first package is in flight.
        chain.onBroadcast = { withUnsafeCurrentTask { $0?.cancel() } }
        let first = backgroundRun()
        _ = await Task { await first.run() }.value

        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n1"])
        XCTAssertTrue(connects.isEmpty)
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.broadcastLog.map(\.txid), ["n1"])

        chain.onBroadcast = nil
        sdk.checks = [CheckRecoverFundsResponse(recovery: recovery, verdict: .valid)]
        _ = await backgroundRun().run()

        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n1", "n2"])
        XCTAssertEqual(try store.load()?.broadcastLog.map(\.txid), ["n1", "n2"])
    }

    func testStaysKeylessWhenSparkDoesNotConnectOrTimeIsShort() async throws {
        _ = try savedRunningExit([SparkExitFixtures.tx("n1")])

        let late = await backgroundRun(deadline: SparkExitBackgroundRun.reserveSeconds - 1).run()
        XCTAssertTrue(connects.isEmpty)
        XCTAssertFalse(late.isConnected)

        let offline = await backgroundRun(connects: false).run()
        XCTAssertEqual(connects.count, 1)
        XCTAssertFalse(offline.isConnected)
        XCTAssertTrue(sdk.checkedRecoveries.isEmpty)
        XCTAssertEqual(chain.broadcasts.map(\.txid), ["n1"])
    }

    func testDoesNothingWithoutARunningExit() async {
        let outcome = await backgroundRun().run()

        XCTAssertNil(outcome.record)
        XCTAssertTrue(connects.isEmpty)
        XCTAssertTrue(chain.broadcasts.isEmpty)
    }
}

final class SparkExitMathTests: XCTestCase {
    func testQuoteSplitsWhatArrivesFromWhatItCosts() {
        let quote = SparkExitQuote(prepared: SparkExitFixtures.prepared(funding: 20000))

        XCTAssertEqual(quote.exitSats, 100_000)
        XCTAssertEqual(quote.networkFeeSats, 9000)
        XCTAssertEqual(quote.receiveSats, 91000)
        XCTAssertEqual(quote.fundingSats, 20000)
        XCTAssertEqual(quote.incomingSats, 111_000)
        XCTAssertEqual(quote.leftBehindSats, 300)
        XCTAssertTrue(quote.isWorthExiting)
    }

    func testQuoteIsNotWorthExitingWhenFeesExceedTheValue() {
        var prepared = SparkExitFixtures.prepared()
        prepared.totalFeeSats = 100_000
        XCTAssertFalse(SparkExitQuote(prepared: prepared).isWorthExiting)
        XCTAssertEqual(SparkExitQuote(prepared: prepared).receiveSats, 0)
        XCTAssertFalse(SparkExitQuote(prepared: SparkExitFixtures.prepared(leaves: [])).isWorthExiting)
    }

    func testCooperativeOnlyQuoteNeedsNoFunding() {
        XCTAssertEqual(SparkExitQuote(prepared: SparkExitFixtures.prepared(funding: nil)).fundingSats, 0)
    }

    func testClaimableHeightIsTheLatestTimelock() {
        let recovery = SparkExitFixtures.recovery([
            SparkExitFixtures.tx("a", status: .waitingForTimelock(spendableAtHeight: 2000)),
            SparkExitFixtures.tx("b", status: .waitingForTimelock(spendableAtHeight: 2400)),
            SparkExitFixtures.tx("c", status: .confirmed(blockHeight: 5)),
        ])

        XCTAssertEqual(SparkExitMath.claimableAtHeight(recovery), 2400)
        XCTAssertEqual(SparkExitMath.confirmedCount(recovery), 1)
        XCTAssertNil(SparkExitMath.claimableAtHeight(SparkExitFixtures.recovery([SparkExitFixtures.tx("d")])))
    }

    func testRemindsAheadOfEachTimelockUntilItsStepIsPublished() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let grace = TimeInterval(SparkExitMath.reminderGraceBlocks) * 30
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("a", status: .waitingForTimelock(spendableAtHeight: 900)),
            SparkExitFixtures.tx("b", status: .waitingForTimelock(spendableAtHeight: 2400)),
            SparkExitFixtures.tx("c", status: .waitingForTimelock(spendableAtHeight: 1500)),
            SparkExitFixtures.tx("d", status: .confirmed(blockHeight: 800)),
        ]))

        XCTAssertEqual(SparkExitMath.reminders(record, tip: 1000, now: now, network: .regtest), [
            SparkExitReminder(id: "1-h900", fireAt: now.addingTimeInterval(grace)),
            SparkExitReminder(id: "1-h1500", fireAt: now.addingTimeInterval(500 * 30 + grace)),
            SparkExitReminder(id: "1-h2400", fireAt: now.addingTimeInterval(1400 * 30 + grace)),
        ])
        XCTAssertEqual(try SparkExitMath.claimableAtHeight(XCTUnwrap(record.recovery?.response)), 2400)

        record.broadcastLog = [.init(
            generation: 1,
            txid: "a",
            attempts: 1,
            rejections: 0,
            lastAttemptAt: now,
            lastOutcome: "accepted",
            isAccepted: true
        )]
        XCTAssertEqual(SparkExitMath.reminders(record, tip: 1000, now: now, network: .regtest).map(\.id), ["1-h1500", "1-h2400"])
    }

    func testRemindsWhenStepsWaitingForParentsStopMoving() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([
            SparkExitFixtures.tx("f", kind: .fanOut),
            SparkExitFixtures.tx("n1", dependsOn: ["f"], status: .waitingForDependencies),
            SparkExitFixtures.tx("r1", kind: .refund, dependsOn: ["n1"], status: .waitingForDependencies),
        ]))
        record.broadcastLog = [.init(
            generation: 1,
            txid: "f",
            attempts: 1,
            rejections: 0,
            lastAttemptAt: now,
            lastOutcome: "accepted",
            isAccepted: true
        )]

        let reminders = SparkExitMath.reminders(record, tip: 1000, now: now, network: .bitcoin)

        XCTAssertEqual(reminders, [SparkExitReminder(id: "1-idle-0-1", fireAt: now.addingTimeInterval(4 * 60 * 60))])
    }

    func testRemindsAtOnceForFeeFundingAndRepeatedRejections() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let funding = SparkExitFixtures.record(phase: .needsFunding(requiredSats: 5000))
        XCTAssertEqual(
            SparkExitMath.reminders(funding, tip: 1000, now: now, network: .bitcoin),
            [SparkExitReminder(id: "funding-5000", fireAt: now, isFunding: true)]
        )

        var record = SparkExitFixtures.record(phase: .running)
        record.adopt(SparkExitFixtures.recovery([SparkExitFixtures.tx("n1")]))
        record.broadcastLog = [.init(
            generation: 1,
            txid: "n1",
            attempts: 3,
            rejections: 3,
            lastAttemptAt: now,
            lastOutcome: "rejected",
            isAccepted: false
        )]
        XCTAssertEqual(SparkExitMath.reminders(record, tip: 1000, now: now, network: .bitcoin), [
            SparkExitReminder(id: "rejected-1-n1", fireAt: now),
            SparkExitReminder(id: "1-ready-n1", fireAt: now.addingTimeInterval(TimeInterval(SparkExitMath.reminderGraceBlocks) * 600)),
            SparkExitReminder(id: "1-idle-0-0", fireAt: now.addingTimeInterval(4 * 60 * 60)),
        ])
        XCTAssertTrue(SparkExitMath.reminders(SparkExitFixtures.record(phase: .done), tip: 1000, now: now, network: .bitcoin).isEmpty)
    }

    /// qa-03 case 5 replayed on regtest: a single-leaf exit whose leaf an older state claimed. Generation 2's idle
    /// reminder, planned when it was built, fired a second before the rebuild that found the leaf lost, so two
    /// notifications arrived at once. A pending rebuild now replaces its generation's reminders, and the lost exit
    /// gives only the lost one.
    func testALostLeafExitGivesOneNotificationAcrossItsRebuilds() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let recovery = SparkExitFixtures.recovery([
            SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 10)),
            SparkExitFixtures.refund("r1", leafId: "leaf-1", dependsOn: ["n1"]),
        ])
        var record = SparkExitFixtures.record(phase: .running)
        var scheduled: [String: Date] = [:]
        var fired: [String: Date] = [:]
        var delivered: [String] = []
        // As `SparkExitManager.scheduleReminders`: one that fired is not posted again, one ahead keeps its earliest
        // date, and every reminder no longer planned is removed.
        func schedule(at seconds: TimeInterval) {
            let now = start.addingTimeInterval(seconds)
            for (id, fireAt) in scheduled.sorted(by: { $0.value < $1.value }) where fireAt <= now {
                delivered.append(id)
                fired[id] = fireAt
            }
            var next: [String: Date] = [:]
            for reminder in SparkExitMath.reminders(record, tip: 1000, now: now, network: .regtest) where fired[reminder.id] == nil {
                next[reminder.id] = min(reminder.fireAt, scheduled[reminder.id] ?? reminder.fireAt)
            }
            scheduled = next
        }

        record.adopt(recovery, at: start)
        schedule(at: 0)
        XCTAssertEqual(Set(scheduled.keys), ["1-ready-r1", "1-idle-1-0"])
        // A check says Redo; the rebuild waits for its interval.
        record.isRebuilding = true
        schedule(at: 284)
        XCTAssertEqual(Array(scheduled.keys), ["1-rebuild"])
        record.adopt(recovery, at: start.addingTimeInterval(645))
        schedule(at: 645)
        record.isRebuilding = true
        schedule(at: 705)
        // The next rebuild reproduces the spent refund a second time: the leaf is lost and the exit ends.
        record.lostLeaves = [.init(leafId: "leaf-1", valueSats: 32768)]
        record.isRebuilding = true
        record.phase = .failed(reason: SparkExitRecord.lostReason)
        schedule(at: 1246)
        schedule(at: 1247)

        XCTAssertEqual(delivered, ["lost-1"])
    }

    func testTimelocksMatureOnlyOnceNoRefundWaits() {
        let node = SparkExitFixtures.tx("n1", status: .confirmed(blockHeight: 5))
        let waitingForParent = SparkExitFixtures.tx("r1", kind: .refund, dependsOn: ["n1"], status: .waitingForDependencies)
        let waitingForHeight = SparkExitFixtures.tx("r1", kind: .refund, dependsOn: ["n1"], status: .waitingForTimelock(spendableAtHeight: 2000))
        let ready = SparkExitFixtures.tx("r1", kind: .refund, dependsOn: ["n1"], status: .ready)

        XCTAssertFalse(SparkExitMath.areTimelocksMatured([]))
        XCTAssertFalse(SparkExitMath.areTimelocksMatured([node]))
        XCTAssertFalse(SparkExitMath.areTimelocksMatured([node, waitingForParent]))
        XCTAssertFalse(SparkExitMath.areTimelocksMatured([node, waitingForHeight, ready]))
        XCTAssertTrue(SparkExitMath.areTimelocksMatured([node, ready]))
    }

    func testSettlesExitTransfersNoRunningExitOwns() {
        let transfers = [
            Bitkit.Transfer(id: "transfer-1", type: .sparkExit, amountSats: 1000, createdAt: 0),
            Bitkit.Transfer(id: "orphan", type: .sparkExit, amountSats: 1000, createdAt: 0),
            Bitkit.Transfer(id: "channel", type: .toSavings, amountSats: 1000, createdAt: 0),
        ]
        var unowned = SparkExitFixtures.record(phase: .running)
        unowned.transferId = nil

        XCTAssertEqual(SparkExitMath.orphanedTransferIds(transfers, record: SparkExitFixtures.record(phase: .running)), ["orphan"])
        XCTAssertEqual(SparkExitMath.orphanedTransferIds(transfers, record: unowned), ["transfer-1", "orphan"])
        XCTAssertEqual(SparkExitMath.orphanedTransferIds(transfers, record: SparkExitFixtures.record(phase: .done)), ["transfer-1", "orphan"])
        XCTAssertEqual(SparkExitMath.orphanedTransferIds(transfers, record: nil), ["transfer-1", "orphan"])
    }

    func testFundingTopUpTakesEveryConfirmedPaymentOnceTogetherTheyCover() {
        let utxos = [
            SparkExitFixtures.utxo("a", value: 999),
            SparkExitFixtures.utxo("pending", value: 50000, confirmed: false),
            SparkExitFixtures.utxo("b", value: 1000),
        ]

        XCTAssertEqual(SparkExitMath.fundingTopUp(utxos, requiredSats: 1999)?.map(\.txid), ["a", "b"])
        XCTAssertNil(SparkExitMath.fundingTopUp(utxos, requiredSats: 2000))
        XCTAssertNil(SparkExitMath.fundingTopUp([], requiredSats: 0))
    }

    func testShowsTheSparkBalanceBeyondTheExitsLeaves() {
        var record = SparkExitFixtures.record(phase: .running)
        record.leafTotalSats = 17097

        XCTAssertEqual(SparkExitMath.outsideExitSats(sparkBalanceSats: 49865, record: record), 32768)
        XCTAssertNil(SparkExitMath.outsideExitSats(sparkBalanceSats: 17097, record: record))
        record.phase = .done
        XCTAssertNil(SparkExitMath.outsideExitSats(sparkBalanceSats: 49865, record: record))
    }

    /// A failed exit claims only what Spark still holds beyond its leaves, never the leaves it lost.
    func testFailedExitNamesWhatStaysOnSpark() {
        var record = SparkExitFixtures.record(phase: .failed(reason: "Claimed by an older state"))
        record.leafTotalSats = 17097
        record.lostLeaves = [.init(leafId: "leaf-1", valueSats: 17097)]

        XCTAssertEqual(SparkExitMath.staysOnSparkSats(sparkBalanceSats: 49865, record: record), 32768)
        XCTAssertNil(SparkExitMath.staysOnSparkSats(sparkBalanceSats: 17097, record: record))
        XCTAssertNil(SparkExitMath.staysOnSparkSats(sparkBalanceSats: 0, record: record))
        XCTAssertNil(SparkExitMath.outsideExitSats(sparkBalanceSats: 49865, record: record))
    }

    /// qa-03: once Bitkit paid the funding from savings, or a payment covering it is seen, the exit waits for it
    /// instead of asking again; only what stays short after confirmation is asked for.
    func testFundingStateWaitsForAPaymentInsteadOfAskingAgain() {
        var record = SparkExitFixtures.record(phase: .awaitingFunding(requiredSats: 9000))

        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: []), .ask(sats: 9000))
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: [SparkExitFixtures.utxo("a", value: 4000)]), .ask(sats: 5000, receivedSats: 4000))
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: [SparkExitFixtures.utxo("x", value: 9000, confirmed: false)]), .seen(txid: "x"))

        record.fundingPaymentTxid = "pay"
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: nil), .paid(txid: "pay"))
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: []), .paid(txid: "pay"))
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: [SparkExitFixtures.utxo("pay", value: 9000, confirmed: false)]), .paid(txid: "pay"))
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: [SparkExitFixtures.utxo("pay", value: 6000)]), .ask(sats: 3000, receivedSats: 6000))

        // Adopted, and spent by a rebuild's CPFP: a later shortfall is asked for, not shown as paid.
        record.funding = [.init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "pay", vout: 0, valueSats: 9000)]
        record.phase = .needsFunding(requiredSats: 12000)
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: []), .ask(sats: 3000))

        record.phase = .running
        XCTAssertNil(SparkExitMath.fundingState(record, utxos: []))
    }

    /// qa-03: a short rebuild showed "₿ 68 more" for one tick before the ask's 294 floor applied.
    func testTheNeededAmountIsNeverUnderTheDustLimit() {
        var record = SparkExitFixtures.record(phase: .needsFunding(requiredSats: 20068))
        record.funding = [.init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 0, valueSats: 20000)]

        XCTAssertEqual(SparkExitMath.neededSats(record, state: nil), 294)
        XCTAssertEqual(SparkExitMath.neededSats(record, state: .seen(txid: "x")), 294)
        XCTAssertEqual(SparkExitMath.neededSats(record, state: SparkExitMath.fundingState(record, utxos: [])), 294)
        XCTAssertEqual(SparkExitMath.neededSats(record, state: .ask(sats: 500)), 500)
    }

    /// qa-03: 2,000 of 4,348 at the address showed no hint until the whole sum arrived.
    func testAPartialPaymentNamesWhatIsStillMissing() {
        XCTAssertNil(SparkExitMath.partialFundingSats(receivedSats: 0, requiredSats: 4348))
        XCTAssertEqual(SparkExitMath.partialFundingSats(receivedSats: 2000, requiredSats: 4348), 2348)
        XCTAssertNil(SparkExitMath.partialFundingSats(receivedSats: 4348, requiredSats: 4348))
        // qa-03: bitcoind refuses a 68-sat output, so no ask goes below the P2WPKH dust limit.
        XCTAssertEqual(SparkExitMath.partialFundingSats(receivedSats: 4280, requiredSats: 4348), 294)
        let short = SparkExitFixtures.record(phase: .awaitingFunding(requiredSats: 4348))
        XCTAssertEqual(
            SparkExitMath.fundingState(short, utxos: [SparkExitFixtures.utxo("a", value: 4280)]),
            .ask(sats: 294, receivedSats: 4280)
        )

        // A top-up counts only new funding: the adopted input and CPFP change at the address are not received.
        var record = SparkExitFixtures.record(phase: .needsFunding(requiredSats: 9000))
        record.funding = [.init(index: 0, address: "bcrt1qfunding", pubkey: "02ab", txid: "f0", vout: 0, valueSats: 5000)]
        let utxos = [SparkExitFixtures.utxo("f0", value: 5000), SparkExitFixtures.utxo("new", value: 1500, confirmed: false)]
        XCTAssertEqual(SparkExitMath.fundingState(record, utxos: utxos), .ask(sats: 2500, receivedSats: 1500))
    }

    func testEachExitTakesAFundingIndexNoEarlierExitUsed() {
        var record = SparkExitFixtures.record(phase: .done)

        XCTAssertEqual(SparkExitMath.nextFundingIndex(counter: 0, record: nil), 0)
        XCTAssertEqual(SparkExitMath.nextFundingIndex(counter: 0, record: record), 1, "a record from before per-exit indexes used 0")
        XCTAssertEqual(SparkExitMath.nextFundingIndex(counter: 3, record: record), 3)
        record.funding[0] = .init(index: 4, address: "a", pubkey: "02ab")
        XCTAssertEqual(SparkExitMath.nextFundingIndex(counter: 1, record: record), 5)
    }

    /// qa-03: value the quote cannot exit, such as a counter-swap still unclaimed, is said on the quote screen.
    func testQuoteNamesTheBalanceItCannotExit() {
        let quote = SparkExitQuote(prepared: SparkExitFixtures.prepared())

        XCTAssertEqual(SparkExitMath.unexitableSats(sparkBalanceSats: 133_068, quote: quote), 300 + 32768)
        XCTAssertEqual(SparkExitMath.unexitableSats(sparkBalanceSats: 100_300, quote: quote), 300, "the skipped leaves")
        XCTAssertEqual(SparkExitMath.unexitableSats(sparkBalanceSats: 90000, quote: quote), 300)
    }

    func testReadsTheLeafAnUnexitableErrorNames() {
        let message = "Leaf 0193a7c2-11aa-7bbb-8ccc-1234567890ab cannot be exited: its refund cannot pay its own fee at this fee rate"
        XCTAssertTrue(SparkExitMath.isUnexitableLeafError("SparkError: " + message))
        XCTAssertEqual(SparkExitMath.unexitableLeafId("SparkError: " + message), "0193a7c2-11aa-7bbb-8ccc-1234567890ab")
        XCTAssertNil(SparkExitMath.unexitableLeafId("The leaf cannot be exited: no refund"))
        XCTAssertFalse(SparkExitMath.isUnexitableLeafError("operators unavailable"))
    }

    /// With the operators down an older state's refund can take a leaf 100 blocks after ours matures, and the
    /// watchtower may publish after 50: reminders land well inside the smaller window.
    func testRemindersLandWellInsideTheDeadline() {
        let deadline = min(SparkExitMath.operatorWindowBlocks, SparkExitMath.olderStateLeadBlocks)
        XCTAssertLessThanOrEqual(SparkExitMath.reminderGraceBlocks * 2, deadline)
        XCTAssertLessThanOrEqual(UInt32(SparkExitMath.reminderSeconds(network: .bitcoin) / 600) * 2, deadline)
    }

    func testSavingsMustCoverTheFundingAndItsFee() {
        XCTAssertTrue(SparkExitMath.canFundFromSavings(spendableSats: 10500, fundingSats: 10000, paymentFeeSats: 500))
        XCTAssertFalse(SparkExitMath.canFundFromSavings(spendableSats: 10499, fundingSats: 10000, paymentFeeSats: 500))
        XCTAssertFalse(SparkExitMath.canFundFromSavings(spendableSats: 10000, fundingSats: 0, paymentFeeSats: 0))
    }

    func testEtaUsesTheNetworksBlockTime() {
        XCTAssertEqual(SparkExitMath.secondsUntil(height: 110, tip: 100, network: .bitcoin), 6000)
        XCTAssertEqual(SparkExitMath.secondsUntil(height: 110, tip: 100, network: .regtest), 300)
        XCTAssertEqual(SparkExitMath.secondsUntil(height: 90, tip: 100, network: .bitcoin), 0)
    }

    func testDecodesACompressedWif() throws {
        let key = try SparkExitFundingKey.secretKey(fromWif: "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn")

        XCTAssertEqual(key, Data(repeating: 0, count: 31) + Data([1]))
    }

    func testRejectsAWifWithABadChecksumOrUncompressedKey() {
        XCTAssertThrowsError(try SparkExitFundingKey.secretKey(fromWif: "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWo"))
        // Uncompressed key 1 (no 0x01 flag).
        XCTAssertThrowsError(try SparkExitFundingKey.secretKey(fromWif: "5HpHagT65TZzG1PH3CSu63k8DbpvD8s5ip4nEB3kEsreAnchuDf"))
    }

    func testFundingKeyDerivesOnItsOwnAccount() throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

        let regtest = try SparkExitFundingKey.derive(index: 0, mnemonic: mnemonic, passphrase: nil, network: .regtest)
        let again = try SparkExitFundingKey.derive(index: 0, mnemonic: mnemonic, passphrase: nil, network: .regtest)
        let mainnet = try SparkExitFundingKey.derive(index: 0, mnemonic: mnemonic, passphrase: nil, network: .bitcoin)

        XCTAssertEqual(SparkExitFundingKey.path(index: 0, network: .regtest), "m/84'/1'/7797'/0/0")
        XCTAssertEqual(SparkExitFundingKey.path(index: 3, network: .bitcoin), "m/84'/0'/7797'/0/3")
        XCTAssertTrue(regtest.address.hasPrefix("bcrt1q"))
        XCTAssertTrue(mainnet.address.hasPrefix("bc1q"))
        XCTAssertEqual(regtest.pubkey.count, 66)
        XCTAssertEqual(regtest.secretKey.count, 32)
        XCTAssertEqual(regtest.secretKey, again.secretKey)
        XCTAssertNoThrow(try singleKeyCpfpSigner(secretKeyBytes: regtest.secretKey))
    }

    func testTxidIgnoresWitnessData() {
        let segwit = "0200000000010111111111111111111111111111111111111111111111111111111111111111110000000000ffffffff01e80300000000000016001422222222222222222222222222222222222222220202abcd0301020300000000"

        XCTAssertEqual(SparkExitTxid.txid(hex: SparkExitFixtures.parentHex), SparkExitFixtures.parentTxid)
        XCTAssertEqual(SparkExitTxid.txid(hex: segwit), SparkExitFixtures.parentTxid)
        XCTAssertNil(SparkExitTxid.txid(hex: "02zz"))
    }
}

// MARK: - Broadcast client

final class SparkExitBroadcasterTests: XCTestCase {
    final class FakeHTTP: SparkExitHTTP, @unchecked Sendable {
        var responses: [(path: String, status: Int, body: String)] = []
        private(set) var requests: [URLRequest] = []

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let url = try XCTUnwrap(request.url)
            guard let index = responses.firstIndex(where: { url.absoluteString.hasSuffix($0.path) }) else { throw URLError(.cannotConnectToHost) }
            let response = responses.remove(at: index)
            return (Data(response.body.utf8), HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let hostA = URL(string: "https://a.example/api")!
    private let hostB = URL(string: "https://b.example/api")!

    func testSendsAPackageAsAJsonArray() async throws {
        let http = FakeHTTP()
        http.responses = [("a.example/api/v1/txs/package", 200, #"{"package_msg":"success","tx-results":{}}"#)]
        let chain = EsploraSparkExitChain(hosts: [hostA], http: http)

        let outcome = await chain.broadcast(SparkExitFixtures.tx("n1", cpfp: "03child"))

        XCTAssertEqual(outcome, .accepted)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: XCTUnwrap(request.httpBody)), ["02n1", "03child"])
    }

    func testFallsBackToTheUnversionedPackagePathThenTheNextHost() async {
        let http = FakeHTTP()
        http.responses = [
            ("a.example/api/v1/txs/package", 404, "Not Found"),
            ("a.example/api/txs/package", 404, "Not Found"),
            ("b.example/api/v1/txs/package", 200, #"{"package_msg":"success"}"#),
        ]
        let chain = EsploraSparkExitChain(hosts: [hostA, hostB], http: http)

        let outcome = await chain.broadcast(SparkExitFixtures.tx("n1", cpfp: "03c"))

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(http.requests.map { $0.url?.host }, ["a.example", "a.example", "b.example"])
    }

    func testSendsAStepWithoutCpfpAsOneTransaction() async throws {
        let http = FakeHTTP()
        http.responses = [("a.example/api/tx", 200, "s1")]
        let chain = EsploraSparkExitChain(hosts: [hostA], http: http)

        let outcome = await chain.broadcast(SparkExitFixtures.tx("s1", kind: .sweep))

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(try String(decoding: XCTUnwrap(http.requests.first?.httpBody), as: UTF8.self), "02s1")
    }

    func testTriesTheNextHostAfterARejection() async {
        let http = FakeHTTP()
        http.responses = [
            ("a.example/api/tx", 400, #"sendrawtransaction RPC error: {"code":-26,"message":"min relay fee not met"}"#),
            ("b.example/api/tx", 200, "s1"),
        ]
        let chain = EsploraSparkExitChain(hosts: [hostA, hostB], http: http)

        let outcome = await chain.broadcast(SparkExitFixtures.tx("s1", kind: .sweep))

        XCTAssertEqual(outcome, .accepted)
    }

    func testTriesTheNextHostWhenOneIsUnavailable() async {
        let http = FakeHTTP()
        http.responses = [
            ("a.example/api/tx", 429, "Too Many Requests"),
            ("b.example/api/tx", 200, "s1"),
        ]
        let chain = EsploraSparkExitChain(hosts: [hostA, hostB], http: http)

        let outcome = await chain.broadcast(SparkExitFixtures.tx("s1", kind: .sweep))

        XCTAssertEqual(outcome, .accepted)
    }

    func testANodeRefusalWinsOverAnUnavailableHost() async {
        let http = FakeHTTP()
        http.responses = [
            ("a.example/api/tx", 400, #"sendrawtransaction RPC error: {"code":-26,"message":"min relay fee not met"}"#),
            ("b.example/api/tx", 503, ""),
        ]
        let chain = EsploraSparkExitChain(hosts: [hostA, hostB], http: http)

        let outcome = await chain.broadcast(SparkExitFixtures.tx("s1", kind: .sweep))

        guard case .rejected = outcome else { return XCTFail("Expected the refusal, got \(outcome)") }
    }

    func testClassifiesNodeAnswers() {
        XCTAssertEqual(SparkExitBroadcastClassifier.single(status: 400, body: Data(#"sendrawtransaction RPC error: {"code":-27}"#.utf8)), .accepted)
        XCTAssertEqual(
            SparkExitBroadcastClassifier.single(
                status: 400,
                body: Data(#"sendrawtransaction RPC error: {"code":-26,"message":"non-BIP68-final"}"#.utf8)
            ),
            .notMature(#"sendrawtransaction RPC error: {"code":-26,"message":"non-BIP68-final"}"#)
        )
        XCTAssertEqual(SparkExitBroadcastClassifier.single(status: 503, body: Data()), .retryLater("HTTP 503"))
        if case .rejected = SparkExitBroadcastClassifier.single(status: 400, body: Data(#"{"code":-26,"message":"min relay fee not met"}"#.utf8)) {}
        else {
            XCTFail("Expected a rejection")
        }
        let missing = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"a","error":"bad-txns-inputs-missingorspent"},"w2":{"txid":"b","error":"bad-txns-inputs-missingorspent"}},"replaced-transactions":[]}"#
        if case .inputsMissing = SparkExitBroadcastClassifier.package(status: 200, body: Data(missing.utf8)) {} else {
            XCTFail("Missing inputs are their own outcome")
        }
        if case .inputsMissing = SparkExitBroadcastClassifier.single(status: 400, body: Data(#"sendrawtransaction RPC error: {"code":-25}"#.utf8)) {}
        else {
            XCTFail("RPC -25 is missing inputs")
        }
        let parentNotFinal = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"a","error":"non-BIP68-final"},"w2":{"txid":"b","error":"bad-txns-inputs-missingorspent"}}}"#
        if case .notMature = SparkExitBroadcastClassifier.package(status: 200, body: Data(parentNotFinal.utf8)) {} else {
            XCTFail("A child missing its immature parent is not mature, not spent")
        }
        let childMissing = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"step"},"w2":{"txid":"child","error":"bad-txns-inputs-missingorspent"}}}"#
        if case .retryLater = SparkExitBroadcastClassifier.package(status: 200, body: Data(childMissing.utf8), txid: "step") {} else {
            XCTFail("Only the step's own missing input means it was spent")
        }
        let stepMissing = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"step","error":"bad-txns-inputs-missingorspent"}}}"#
        if case .inputsMissing = SparkExitBroadcastClassifier.package(status: 200, body: Data(stepMissing.utf8), txid: "step") {} else {
            XCTFail("The step's own input is missing")
        }
        let childRejected = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"step","error":"non-BIP68-final"},"w2":{"txid":"child","error":"min relay fee not met"}}}"#
        if case .notMature = SparkExitBroadcastClassifier.package(status: 200, body: Data(childRejected.utf8), txid: "step") {} else {
            XCTFail("An immature parent outranks the child's refusal")
        }
        let stepRejected = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"child","error":"non-BIP68-final"},"w2":{"txid":"step","error":"min relay fee not met"}}}"#
        if case .rejected = SparkExitBroadcastClassifier.package(status: 200, body: Data(stepRejected.utf8), txid: "step") {} else {
            XCTFail("The step's own refusal decides, whatever its child reports")
        }
        let stepSpent = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"child","error":"non-BIP68-final"},"w2":{"txid":"step","error":"bad-txns-inputs-missingorspent"}}}"#
        if case .inputsMissing = SparkExitBroadcastClassifier.package(status: 200, body: Data(stepSpent.utf8), txid: "step") {} else {
            XCTFail("The step's own missing input decides, whatever its child reports")
        }
        let stepKnown = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"step","error":"txn-already-in-mempool"},"w2":{"txid":"child","error":"min relay fee not met"}}}"#
        if case .rejected = SparkExitBroadcastClassifier.package(status: 200, body: Data(stepKnown.utf8), txid: "step") {} else {
            XCTFail("A step the node already has leaves the outcome to its child")
        }
        let known = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"a","error":"txn-already-in-mempool"},"w2":{"txid":"b"}}}"#
        XCTAssertEqual(SparkExitBroadcastClassifier.package(status: 200, body: Data(known.utf8)), .accepted)
        let nonFinal = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"a","error":"non-BIP68-final"}}}"#
        if case .notMature = SparkExitBroadcastClassifier.package(status: 200, body: Data(nonFinal.utf8)) {} else {
            XCTFail("A timelock is not mature")
        }
        XCTAssertEqual(
            SparkExitBroadcastClassifier.package(status: 400, body: Data(#"{"error":"submitpackage RPC error: {\"code\":-25}"}"#.utf8)),
            .inputsMissing(#"{"error":"submitpackage RPC error: {\"code\":-25}"}"#)
        )
    }

    func testKnowsATransactionOnlyWhileAHostHasIt() async throws {
        let http = FakeHTTP()
        let chain = EsploraSparkExitChain(hosts: [hostA, hostB], http: http)

        http.responses = [("a.example/api/tx/c/hex", 404, "Transaction not found"), ("b.example/api/tx/c/hex", 404, "Transaction not found")]
        let isUnknown = try await chain.isKnown(txid: "c")
        http.responses = [("a.example/api/tx/c/hex", 404, "Transaction not found"), ("b.example/api/tx/c/hex", 200, "0300")]
        let isKnown = try await chain.isKnown(txid: "c")
        http.responses = [("a.example/api/tx/c/hex", 404, "Transaction not found")]
        let isUnreachable = await (try? chain.isKnown(txid: "c")) == nil

        XCTAssertFalse(isUnknown)
        XCTAssertTrue(isKnown)
        XCTAssertTrue(isUnreachable, "a host that could not answer is no proof it is gone")
        XCTAssertTrue(SparkExitBroadcastClassifier.isUnpaid(.rejected("min relay fee not met, 0 < 17")))
        XCTAssertFalse(SparkExitBroadcastClassifier.isUnpaid(.rejected("min relay fee not met, 100 < 170")))
        XCTAssertFalse(SparkExitBroadcastClassifier.isUnpaid(.inputsMissing("min relay fee not met, 0 < 17")))
    }

    func testReadsTipAndFundingUtxos() async throws {
        let http = FakeHTTP()
        http.responses = [
            ("a.example/api/blocks/tip/height", 200, "3681536\n"),
            (
                "a.example/api/address/bcrt1qf/utxo",
                200,
                #"[{"txid":"t","vout":1,"value":5000,"status":{"confirmed":true,"block_height":7,"block_hash":"h"}}]"#
            ),
        ]
        let chain = EsploraSparkExitChain(hosts: [hostA], http: http)

        let tip = try await chain.tipHeight()
        let utxos = try await chain.utxos(address: "bcrt1qf")

        XCTAssertEqual(tip, 3_681_536)
        XCTAssertEqual(utxos, [SparkExitFixtures.utxo("t", vout: 1, value: 5000)].map {
            EsploraUtxo(txid: $0.txid, vout: $0.vout, value: $0.value, status: EsploraTxStatus(confirmed: true, blockHeight: 7))
        })
    }
}
