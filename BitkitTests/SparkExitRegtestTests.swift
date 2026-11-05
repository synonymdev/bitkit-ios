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

    /// The background tasks' entry point from a cold start, in a process with no UI and no node: the keyless pass
    /// sends a stored package to the live node, then the Spark SDK connects, checks the stored exit and rebuilds it.
    /// Logs the wall time per step and the process footprint, for the refresh and processing budgets.
    @MainActor
    func testBackgroundRunFromAColdStart() async throws {
        let walletIndex = 7
        let mnemonic = try generateMnemonic(wordCount: .words12)
        try Keychain.upsert(key: .bip39Mnemonic(index: walletIndex), data: Data(mnemonic.utf8))
        let store = SparkExitStore(walletIndex: walletIndex)
        defer {
            try? Keychain.delete(key: .bip39Mnemonic(index: walletIndex))
            try? store.delete()
            try? FileManager.default.removeItem(at: Env.sparkStorage(walletIndex: walletIndex))
        }
        let funding = try SparkExitFundingKey.derive(index: 0, mnemonic: mnemonic, passphrase: nil, network: .regtest)
        var record = SparkExitRecord(
            network: "regtest",
            createdAt: Date(),
            phase: .running,
            feeRateSatPerVbyte: 1,
            destination: funding.address,
            leafIds: ["leaf-1"],
            funding: [.init(index: 0, address: funding.address, pubkey: funding.pubkey)],
            expectedSats: 1000
        )
        let child = "0200000001" + Data(SparkExitFixtures.parentTxid.hexaBytes.reversed()).hex
            + "0000000000ffffffff01e803000000000000160014222222222222222222222222222222222222222200000000"
        // The shape of the live regtest exit: a fan-out, 24 node packages, 4 refunds and the sweep. Only the fan-out is
        // a real transaction; the rest wait for parents the chain host has never seen.
        func txid(_ i: Int) -> String {
            String(repeating: String(format: "%02x", i), count: 32)
        }
        let nodes = (1 ... 24).map { SparkExitFixtures.tx(
            txid($0),
            cpfp: "03c\($0)",
            dependsOn: [SparkExitFixtures.parentTxid],
            status: .waitingForDependencies
        ) }
        let refunds = (25 ... 28).map { SparkExitFixtures.tx(txid($0), kind: .refund, dependsOn: [txid($0 - 24)], status: .waitingForDependencies) }
        let sweep = SparkExitFixtures.tx(txid(29), kind: .sweep, dependsOn: (25 ... 28).map(txid), status: .waitingForDependencies)
        var stored = SparkExitFixtures.recovery([SparkExitFixtures.tx(SparkExitFixtures.parentTxid, cpfp: child)] + nodes + refunds + [sweep])
        stored.transactions[0].txHex = SparkExitFixtures.parentHex
        record.adopt(stored, at: Date(timeIntervalSinceNow: -3600))
        try store.save(record)
        UserDefaults.standard.set(walletIndex, forKey: "sparkExitWalletIndex")

        let baseline = SparkExitManager.footprintMegabytes()
        let peak = PeakFootprint()
        let sampler = Task.detached {
            while !Task.isCancelled {
                peak.sample()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let cold = await SparkExitManager.shared.runInBackground(deadline: Date(timeIntervalSinceNow: 25))
        let warm = await SparkExitManager.shared.runInBackground(deadline: Date(timeIntervalSinceNow: 25))
        let prepareStarted = Date()
        let prepared = try await XCTUnwrap(SparkManager.shared.exitRecovering).prepare(PrepareRecoverFundsRequest(
            feeRateSatPerVbyte: 1,
            fundingKind: .p2wpkh,
            destination: funding.address,
            selection: .all
        ))
        let prepareSeconds = Date().timeIntervalSince(prepareStarted)
        sampler.cancel()
        peak.sample()

        func line(_ outcome: SparkExitBackgroundRun.Outcome) -> String {
            SparkExitBackgroundRun.Step.allCases.compactMap { step in
                outcome.seconds[step].map { "\(step.rawValue)=\(String(format: "%.2f", $0))s" }
            }.joined(separator: " ")
        }
        print("SPARK_EXIT_BG cold: \(line(cold)) phase=\(String(describing: cold.record?.phase))")
        print("SPARK_EXIT_BG warm: \(line(warm)) phase=\(String(describing: warm.record?.phase))")
        print("SPARK_EXIT_BG prepare(all): \(String(format: "%.2f", prepareSeconds))s leaves=\(prepared.leaves.count)")
        print("SPARK_EXIT_BG footprint: baseline=\(baseline)MB peak=\(peak.value)MB end=\(SparkExitManager.footprintMegabytes())MB")
        XCTAssertTrue(cold.isConnected)
        XCTAssertNotNil(cold.seconds[.broadcast])
        XCTAssertFalse(LightningService.shared.hasNode)
    }
}

private final class PeakFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0

    var value: Int {
        lock.withLock { peak }
    }

    func sample() {
        let now = SparkExitManager.footprintMegabytes()
        lock.withLock { peak = max(peak, now) }
    }
}
