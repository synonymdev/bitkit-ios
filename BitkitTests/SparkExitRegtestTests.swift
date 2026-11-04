@testable import Bitkit
import BitkitCore
import BreezSdkSpark
import XCTest

/// Runs the exit's SDK and chain calls against Spark's hosted regtest. It needs the network, so it only runs with
/// `TEST_RUNNER_SPARK_EXIT_REGTEST=1` in the environment of `xcodebuild test`.
final class SparkExitRegtestTests: XCTestCase {
    private var storageDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["SPARK_EXIT_REGTEST"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SPARK_EXIT_REGTEST=1 to run against Spark's regtest")
        }
        storageDir = FileManager.default.temporaryDirectory.appendingPathComponent("spark-exit-regtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let storageDir {
            try? FileManager.default.removeItem(at: storageDir)
        }
        super.tearDown()
    }

    func testQuotesAnEmptyWalletAndReadsTheChain() async throws {
        let mnemonic = try generateMnemonic(wordCount: .words12)
        let sdk = try await BreezSdkSpark.connect(request: ConnectRequest(
            config: defaultConfig(network: .regtest),
            seed: .mnemonic(mnemonic: mnemonic, passphrase: nil),
            storageDir: storageDir.path
        ))
        defer { Task { try? await sdk.disconnect() } }
        let funding = try SparkExitFundingKey.derive(index: 0, mnemonic: mnemonic, passphrase: nil, network: .regtest)
        let recovering = BreezSparkExitRecovering(sdk: sdk)
        let feeRate = try await max(1, sdk.recommendedFees().fastestFee)

        let prepared = try await recovering.prepare(PrepareRecoverFundsRequest(
            feeRateSatPerVbyte: feeRate,
            fundingKind: .p2wpkh,
            destination: funding.address,
            selection: .all
        ))

        XCTAssertTrue(prepared.leaves.isEmpty)
        XCTAssertFalse(SparkExitQuote(prepared: prepared).isWorthExiting)

        let chain = EsploraSparkExitChain(hosts: EsploraSparkExitChain.defaultHosts(for: .regtest))
        let tip = try await chain.tipHeight()
        XCTAssertGreaterThan(tip, 0)
        let utxos = try await chain.utxos(address: funding.address)
        XCTAssertTrue(utxos.isEmpty)
    }

    /// A parent spending a missing input with its child, as a package: the live node reads the body and answers
    /// per transaction, which the classifier reads as retry later rather than a rejection.
    func testLiveNodeAnswersAPackageTheClassifierRetries() async {
        let parent = SparkExitFixtures.parentHex
        let child = "0200000001" + Data(SparkExitFixtures.parentTxid.hexaBytes.reversed()).hex
            + "0000000000ffffffff01e803000000000000160014222222222222222222222222222222222222222200000000"
        let tx = RecoveryTransaction(
            kind: .node,
            nodeId: "n",
            txid: SparkExitFixtures.parentTxid,
            txHex: parent,
            cpfpTxHex: child,
            csvTimelockBlocks: nil,
            dependsOn: [],
            status: .ready
        )
        let chain = EsploraSparkExitChain(hosts: EsploraSparkExitChain.defaultHosts(for: .regtest))

        let outcome = await chain.broadcast(tx)

        guard case let .retryLater(reason) = outcome else { return XCTFail("Expected retry later, got \(outcome)") }
        XCTAssertTrue(reason.contains("missingorspent"), reason)
    }
}
