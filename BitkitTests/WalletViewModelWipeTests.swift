@testable import Bitkit
import LDKNode
import XCTest

private struct NodeFailure: Error {}

private final class FakeNodeLifecycle: Bitkit.NodeLifecycleService {
    private let lock = NSLock()
    private var _events: [String] = []
    var hasNode = false
    var isRunning = false
    var startError: Error?
    var stopError: Error?
    var stopReleasesNode = true
    /// Runs inside `setup`, to hold a start in flight.
    var duringSetup: (() async -> Void)?

    var events: [String] {
        lock.withLock { _events }
    }

    private func record(_ event: String) {
        lock.withLock { _events.append(event) }
    }

    func setup(walletIndex _: Int, electrumServerUrl _: String?, rgsServerUrl _: String?, channelMigration _: ChannelDataMigration?) async throws {
        record("setup")
        await duringSetup?()
        hasNode = true
    }

    func start(onEvent _: ((Event) -> Void)?) async throws {
        record("start")
        if let startError {
            throw startError
        }
        isRunning = true
    }

    func stop(clearEventCallback _: Bool) async throws {
        record("stop")
        if let stopError {
            throw stopError
        }
        isRunning = false
        if stopReleasesNode {
            hasNode = false
        }
    }

    func isNodeRunning() async -> Bool {
        isRunning
    }

    func wipeStorage(walletIndex _: Int) async throws {
        guard !hasNode else { throw Bitkit.AppError(serviceError: .nodeStillRunning) }
        record("wipeStorage")
    }
}

@MainActor
final class WalletViewModelWipeTests: XCTestCase {
    private func serviceError(_ error: Error) -> Bitkit.CustomServiceError? {
        (error as? Bitkit.AppError)?.underlyingError as? Bitkit.CustomServiceError
    }

    private func makeWallet(
        _ node: FakeNodeLifecycle,
        swapUpdatesStream: SwapUpdatesStreaming = BoltzService.shared,
        swapUpdatesWipeStopTimeout: Duration = WalletViewModel.swapUpdatesWipeStopTimeout,
        nodeLifecycleWipeTimeout: Duration = WalletViewModel.nodeLifecycleWipeTimeout
    ) -> WalletViewModel {
        // A start would otherwise run the one-time network graph cleanup against VSS.
        snapshotAppDefaults("legacyNetworkGraphCleanupDone")
        UserDefaults.standard.set(true, forKey: "legacyNetworkGraphCleanupDone")
        return WalletViewModel(
            nodeLifecycle: node,
            transferService: Bitkit.TransferService(lightningService: .shared),
            sheetViewModel: SheetViewModel(),
            feeEstimatesManager: FeeEstimatesManager(),
            swapUpdatesStream: swapUpdatesStream,
            swapUpdatesWipeStopTimeout: swapUpdatesWipeStopTimeout,
            nodeLifecycleWipeTimeout: nodeLifecycleWipeTimeout
        )
    }

    func testWipeStopsANodeLeftBuiltByAFailedStartThenWipesItsStorage() async throws {
        // `wipe()` resets the cached balances and invoices, which live in the host app's preferences.
        snapshotAppDefaultsDomain()
        let node = FakeNodeLifecycle()
        node.hasNode = true
        let wallet = makeWallet(node)
        wallet.nodeLifecycleState = .errorStarting(cause: NodeFailure())

        try await wallet.stopForWipe()
        try await wallet.wipe()

        XCTAssertEqual(node.events, ["stop", "wipeStorage"])
        XCTAssertFalse(node.hasNode)
        XCTAssertEqual(wallet.nodeLifecycleState, .stopped)
    }

    func testWipeStopsTheSwapUpdatesStreamOfAWalletWithoutANode() async throws {
        snapshotAppDefaults("devOverrideFeeEstimates")
        UserDefaults.standard.set(true, forKey: "devOverrideFeeEstimates")
        let node = FakeNodeLifecycle()
        let stream = FakeSwapUpdatesStream()
        let wallet = makeWallet(node, swapUpdatesStream: stream)
        wallet.ensureSwapUpdatesRunning()
        await eventually("the stream starts") { stream.calls == ["start"] }

        try await wallet.stopForWipe()

        XCTAssertEqual(stream.calls, ["start", "stop"])
        XCTAssertTrue(node.events.isEmpty)
    }

    func testAWipeRefusesToOpenTheSwapUpdatesStreamAgain() async throws {
        let node = FakeNodeLifecycle()
        let stream = FakeSwapUpdatesStream()
        let wallet = makeWallet(node, swapUpdatesStream: stream)

        try await wallet.stopForWipe()
        wallet.ensureSwapUpdatesRunning()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(stream.startArrivals, 0)
        XCTAssertEqual(stream.calls, ["stop"])
    }

    func testWipeWhoseSwapUpdatesStopTimesOutFailsBeforeTheNodeStopsAndARetrySucceeds() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(true, forKey: "devOverrideFeeEstimates")
        let node = FakeNodeLifecycle()
        node.hasNode = true
        node.isRunning = true
        let stream = FakeSwapUpdatesStream()
        stream.holdsStarts = true
        let wallet = makeWallet(node, swapUpdatesStream: stream, swapUpdatesWipeStopTimeout: .milliseconds(200))
        wallet.nodeLifecycleState = .running
        wallet.ensureSwapUpdatesRunning()
        await eventually("the start is in flight") { stream.startArrivals == 1 }

        let firstAttempt = await withDeadline(.seconds(5)) { () async -> Error? in
            do {
                try await wallet.stopForWipe()
                return nil
            } catch {
                return error
            }
        }

        guard let firstAttempt else {
            stream.startGate.open()
            return XCTFail("The wipe kept waiting for the swap updates stream")
        }
        XCTAssertTrue(firstAttempt is SwapUpdatesStopTimeoutError, "Unexpected outcome: \(String(describing: firstAttempt))")
        XCTAssertTrue(node.events.isEmpty, "A wipe that stopped waiting must leave the node and its storage alone")
        XCTAssertTrue(node.isRunning)
        XCTAssertEqual(wallet.nodeLifecycleState, .running)
        XCTAssertTrue(stream.calls.isEmpty)

        stream.startGate.open()
        try await wallet.stopForWipe()
        try await wallet.wipe()

        XCTAssertEqual(node.events, ["stop", "wipeStorage"])
        XCTAssertEqual(stream.calls.filter { $0 == "start" }, ["start"])
        XCTAssertEqual(stream.calls.last, "stop")
    }

    func testWipeGivesUpOnAStartThatHangsAndTouchesNothing() async throws {
        let node = FakeNodeLifecycle()
        let (setupReleased, releaseSetup) = AsyncStream<Void>.makeStream()
        let (setupEntered, enterSetup) = AsyncStream<Void>.makeStream()
        node.duringSetup = {
            enterSetup.yield()
            for await _ in setupReleased {
                break
            }
        }
        node.startError = NodeFailure()
        let wallet = makeWallet(node, nodeLifecycleWipeTimeout: .milliseconds(100))
        wallet.nodeLifecycleState = .initializing
        let start = Task { try await wallet.start() }
        for await _ in setupEntered {
            break
        }

        do {
            try await wallet.stopForWipe()
            XCTFail("Expected the wipe to give up waiting for the start")
        } catch is WipeWaitTimeoutError {}
        XCTAssertEqual(node.events, ["setup"], "A wipe that gave up must not stop or wipe the node")

        releaseSetup.yield()
        await assertThrowsAsync { try await start.value }
        try await wallet.stopForWipe()
        try await wallet.wipe()
        XCTAssertEqual(node.events, ["setup", "start", "stop", "wipeStorage"])
    }

    func testWipeWaitsForAFailingStartInFlightBeforeStopping() async throws {
        let node = FakeNodeLifecycle()
        node.startError = NodeFailure()
        let wallet = makeWallet(node)

        let start = try await startThenWipeWhileStartIsInFlight(wallet, node)

        await assertThrowsAsync { try await start.value }
        XCTAssertEqual(node.events, ["setup", "start", "stop"])
        XCTAssertFalse(node.hasNode)
    }

    func testWipeWaitsForASucceedingStartInFlightBeforeStopping() async throws {
        // A started wallet goes on to refresh its cached state in the host app's preferences.
        snapshotAppDefaultsDomain()
        let node = FakeNodeLifecycle()
        let wallet = makeWallet(node)

        let start = try await startThenWipeWhileStartIsInFlight(wallet, node)

        try await start.value
        XCTAssertEqual(node.events, ["setup", "start", "stop"])
        XCTAssertFalse(node.hasNode)
        XCTAssertFalse(node.isRunning)
    }

    private func startThenWipeWhileStartIsInFlight(
        _ wallet: WalletViewModel,
        _ node: FakeNodeLifecycle
    ) async throws -> Task<Void, Error> {
        let (setupEntered, enterSetup) = AsyncStream<Void>.makeStream()
        let (setupReleased, releaseSetup) = AsyncStream<Void>.makeStream()
        node.duringSetup = {
            enterSetup.yield()
            for await _ in setupReleased {
                break
            }
        }
        wallet.nodeLifecycleState = .initializing

        let start = Task { try await wallet.start() }
        for await _ in setupEntered {
            break
        }
        let wipe = Task { try await wallet.stopForWipe() }
        await Task.yield()
        releaseSetup.yield()

        try await wipe.value
        return start
    }

    func testStartIsRefusedOnceAWipeHasBegun() async {
        let node = FakeNodeLifecycle()
        let wallet = makeWallet(node)

        wallet.closeStartAdmissionForWipe()

        await assertThrowsAsync { try await wallet.start() } _: { error in
            XCTAssertEqual(self.serviceError(error), .wipeInProgress)
        }
        XCTAssertTrue(node.events.isEmpty, "A refused start must not build a node")
        XCTAssertEqual(wallet.nodeLifecycleState, .stopped)
    }

    func testNodeStillHeldAfterTheStopFailsTheWipeAndLeavesStorage() async {
        let node = FakeNodeLifecycle()
        node.hasNode = true
        node.stopReleasesNode = false
        let wallet = makeWallet(node)

        await assertThrowsAsync { try await wallet.stopForWipe() } _: { error in
            XCTAssertEqual(self.serviceError(error), .nodeStillRunning)
        }
        await assertThrowsAsync { try await wallet.wipe() } _: { error in
            XCTAssertEqual(self.serviceError(error), .nodeStillRunning)
        }

        XCTAssertFalse(node.events.contains("wipeStorage"))
    }

    func testFailedStopOfANodeThatIsNotRunningDoesNotReportRunning() async {
        let node = FakeNodeLifecycle()
        node.hasNode = true
        node.stopError = NodeFailure()
        let wallet = makeWallet(node)
        wallet.nodeLifecycleState = .errorStarting(cause: NodeFailure())

        await assertThrowsAsync { try await wallet.stopLightningNode() }

        XCTAssertEqual(wallet.nodeLifecycleState, .stopped)
    }
}
