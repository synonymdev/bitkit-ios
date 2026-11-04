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

    static func utxo(_ txid: String, vout: UInt32 = 0, value: UInt64, confirmed: Bool = true) -> EsploraUtxo {
        EsploraUtxo(txid: txid, vout: vout, value: value, status: EsploraTxStatus(confirmed: confirmed, blockHeight: confirmed ? 100 : nil))
    }
}

final class FakeSparkExitChain: SparkExitChain, @unchecked Sendable {
    private let lock = NSLock()
    var tip: UInt32 = 1000
    var utxosByAddress: [String: [EsploraUtxo]] = [:]
    var confirmedTxids: Set<String> = []
    var outcome: SparkExitBroadcastOutcome = .accepted
    private(set) var broadcasts: [RecoveryTransaction] = []
    var onBroadcast: (() -> Void)?

    func tipHeight() async throws -> UInt32 {
        tip
    }

    func utxos(address: String) async throws -> [EsploraUtxo] {
        lock.withLock { utxosByAddress[address] ?? [] }
    }

    func txStatus(txid: String) async throws -> EsploraTxStatus {
        lock.withLock { EsploraTxStatus(confirmed: confirmedTxids.contains(txid), blockHeight: confirmedTxids.contains(txid) ? 900 : nil) }
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
    private(set) var prepareRequests: [PrepareRecoverFundsRequest] = []
    private(set) var recoverRequests: [RecoverFundsRequest] = []
    private(set) var checkedRecoveries: [RecoverFundsResponse] = []

    func prepare(_ request: PrepareRecoverFundsRequest) async throws -> PrepareRecoverFundsResponse {
        prepareRequests.append(request)
        return preparedResponse
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
            makeSigner: { StubCpfpSigner() },
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
            makeSigner: { StubCpfpSigner() },
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

    func testDoesNothingOnceFinished() async throws {
        let record = try await driver().tick(SparkExitFixtures.record(phase: .done))

        XCTAssertEqual(record.phase, .done)
        XCTAssertTrue(saved.isEmpty)
    }
}

// MARK: - Fees and funding

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

    func testReminderIsTheNextTimelockAboveTheTip() {
        let recovery = SparkExitFixtures.recovery([
            SparkExitFixtures.tx("a", status: .waitingForTimelock(spendableAtHeight: 900)),
            SparkExitFixtures.tx("b", status: .waitingForTimelock(spendableAtHeight: 2400)),
            SparkExitFixtures.tx("c", status: .waitingForTimelock(spendableAtHeight: 1500)),
        ])

        XCTAssertEqual(SparkExitMath.nextMaturityHeight(recovery, tip: 1000), 1500)
        XCTAssertEqual(SparkExitMath.claimableAtHeight(recovery), 2400)
        XCTAssertNil(SparkExitMath.nextMaturityHeight(recovery, tip: 2400))
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

    func testFundingUtxoMustBeConfirmedAndLargeEnough() {
        let utxos = [
            SparkExitFixtures.utxo("small", value: 999),
            SparkExitFixtures.utxo("pending", value: 50000, confirmed: false),
            SparkExitFixtures.utxo("ok", value: 1000),
            SparkExitFixtures.utxo("big", value: 2000),
        ]

        XCTAssertEqual(SparkExitMath.fundingUtxo(utxos, requiredSats: 1000)?.txid, "big")
        XCTAssertNil(SparkExitMath.fundingUtxo(utxos, requiredSats: 2001))
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
            SparkExitBroadcastClassifier.single(status: 400, body: Data(#"sendrawtransaction RPC error: {"code":-25}"#.utf8)),
            .retryLater(#"sendrawtransaction RPC error: {"code":-25}"#)
        )
        XCTAssertEqual(SparkExitBroadcastClassifier.single(status: 503, body: Data()), .retryLater("HTTP 503"))
        if case .rejected = SparkExitBroadcastClassifier.single(status: 400, body: Data(#"{"code":-26,"message":"min relay fee not met"}"#.utf8)) {}
        else {
            XCTFail("Expected a rejection")
        }
        let missing = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"a","error":"bad-txns-inputs-missingorspent"},"w2":{"txid":"b","error":"bad-txns-inputs-missingorspent"}},"replaced-transactions":[]}"#
        if case .retryLater = SparkExitBroadcastClassifier.package(status: 200, body: Data(missing.utf8)) {} else {
            XCTFail("Missing inputs should be retried")
        }
        let known = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"a","error":"txn-already-in-mempool"},"w2":{"txid":"b"}}}"#
        XCTAssertEqual(SparkExitBroadcastClassifier.package(status: 200, body: Data(known.utf8)), .accepted)
        let nonFinal = #"{"package_msg":"transaction failed","tx-results":{"w1":{"txid":"a","error":"non-BIP68-final"}}}"#
        if case .retryLater = SparkExitBroadcastClassifier.package(status: 200, body: Data(nonFinal.utf8)) {} else {
            XCTFail("A timelock should be retried")
        }
        XCTAssertEqual(
            SparkExitBroadcastClassifier.package(status: 400, body: Data(#"{"error":"submitpackage RPC error: {\"code\":-25}"}"#.utf8)),
            .retryLater(#"{"error":"submitpackage RPC error: {\"code\":-25}"}"#)
        )
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
