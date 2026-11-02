@testable import Bitkit
import LDKNode
import XCTest

private struct NodeFailure: Error {}

/// Stands in for ldk-node behind `WalletViewModel`, recording each lifecycle call in order. The test target compiles its
/// own copy of `LightningService.swift` and `Errors.swift`, so the app's types are named by module.
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
        if let startError { throw startError }
        isRunning = true
    }

    func stop(clearEventCallback _: Bool) async throws {
        record("stop")
        if let stopError { throw stopError }
        isRunning = false
        if stopReleasesNode { hasNode = false }
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

    private func makeWallet(_ node: FakeNodeLifecycle) -> WalletViewModel {
        // A start would otherwise run the one-time network graph cleanup against VSS.
        snapshotAppDefaults("legacyNetworkGraphCleanupDone")
        UserDefaults.standard.set(true, forKey: "legacyNetworkGraphCleanupDone")
        return WalletViewModel(
            nodeLifecycle: node,
            transferService: Bitkit.TransferService(lightningService: .shared),
            sheetViewModel: SheetViewModel(),
            feeEstimatesManager: FeeEstimatesManager()
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

    /// Holds a start from `.initializing` inside `setup`, requests the wipe, then lets the start go on. Returns the start
    /// once the wipe's stop has completed.
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
