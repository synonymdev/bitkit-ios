@testable import Bitkit
import BitkitCore
import XCTest

/// Watcher tests for TrezorViewModel, ported from bitkit-android's `TrezorViewModelTest.kt`.
final class TrezorViewModelWatcherTests: XCTestCase {
    // MARK: - Mock

    /// Mock watcher service, standing in for Android's mocked `TrezorRepo`.
    /// `holdStart` mirrors the `CompletableDeferred`-backed mock used to keep
    /// the native start call in flight until the test resolves it.
    private final class MockWatcherService: TrezorWatcherServicing, @unchecked Sendable {
        private let lock = NSLock()

        private(set) var startedParams: [WatcherParams] = []
        private(set) var startedListeners: [EventListener] = []
        private(set) var stoppedWatcherIds: [String] = []
        private(set) var stopAllWatchersCallCount = 0

        var holdStart = false

        private var startContinuation: CheckedContinuation<Void, Error>?
        private var pendingStartResult: Result<Void, Error>?

        func startWatcher(params: WatcherParams, listener: EventListener) async throws {
            lock.lock()
            startedParams.append(params)
            startedListeners.append(listener)
            let shouldHold = holdStart
            lock.unlock()

            guard shouldHold else { return }
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                if let result = pendingStartResult {
                    pendingStartResult = nil
                    continuation.resume(with: result)
                } else {
                    startContinuation = continuation
                }
            }
        }

        func completeStart(with result: Result<Void, Error> = .success(())) {
            lock.lock()
            defer { lock.unlock() }
            if let continuation = startContinuation {
                startContinuation = nil
                continuation.resume(with: result)
            } else {
                pendingStartResult = result
            }
        }

        func stopWatcher(watcherId: String) throws {
            lock.lock()
            defer { lock.unlock() }
            stoppedWatcherIds.append(watcherId)
        }

        func stopAllWatchers() {
            lock.lock()
            defer { lock.unlock() }
            stopAllWatchersCallCount += 1
        }
    }

    // MARK: - Fixtures

    private static let sampleBalance = WalletBalance(
        confirmed: 150_000,
        immature: 0,
        trustedPending: 5000,
        untrustedPending: 1000,
        spendable: 155_000,
        total: 156_000
    )

    private static let sampleTransactions: [HistoryTransaction] = [
        HistoryTransaction(
            txid: "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16",
            received: 50000,
            sent: 0,
            net: 50000,
            fee: nil,
            amount: 50000,
            direction: .received,
            blockHeight: 849_990,
            timestamp: 1_700_000_000,
            confirmations: 11
        ),
        HistoryTransaction(
            txid: "a1075db55d416d3ca199f55b6084e2115b9345e16c5cf302fc80e9d5fbf5d48d",
            received: 0,
            sent: 20000,
            net: -20000,
            fee: 500,
            amount: 19500,
            direction: .sent,
            blockHeight: 849_995,
            timestamp: 1_700_001_000,
            confirmations: 6
        ),
        HistoryTransaction(
            txid: "6f7cf9580f1c2dfb3c4d5d043cdbb128c640e3f20161245aa7372e9666168516",
            received: 10000,
            sent: 10500,
            net: -500,
            fee: 500,
            amount: 500,
            direction: .selfTransfer,
            blockHeight: nil,
            timestamp: nil,
            confirmations: 0
        ),
    ]

    private static func sampleTransactionsChangedEvent() -> WatcherEvent {
        .transactionsChanged(
            transactions: sampleTransactions,
            balance: sampleBalance,
            txCount: 3,
            blockHeight: 850_000,
            accountType: .nativeSegwit
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(service: MockWatcherService) -> TrezorViewModel {
        let viewModel = TrezorViewModel(watcherService: service)
        viewModel.watcherExtendedKey = "xpub6test123"
        return viewModel
    }

    /// Poll until `condition` is true or the timeout elapses, yielding the main
    /// actor between checks so listener Tasks can run (Android: advanceUntilIdle).
    @MainActor
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Tests

    @MainActor
    func testStartWatcherDoesNotExposeActiveWatcherUntilStartCompletes() async {
        let service = MockWatcherService()
        service.holdStart = true
        let viewModel = makeViewModel(service: service)

        let startTask = Task { await viewModel.startWatcher() }
        await waitUntil { service.startedParams.count == 1 }

        XCTAssertEqual(service.startedParams.count, 1)
        XCTAssertTrue(viewModel.isStartingWatcher)
        XCTAssertNil(viewModel.activeWatcherId)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .starting)

        service.completeStart()
        await startTask.value

        XCTAssertFalse(viewModel.isStartingWatcher)
        XCTAssertEqual(viewModel.activeWatcherId, service.startedParams[0].watcherId)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .starting)
    }

    @MainActor
    func testStartWatcherRejectsZeroGapLimit() async {
        let service = MockWatcherService()
        let viewModel = makeViewModel(service: service)
        viewModel.watcherGapLimit = "0"

        await viewModel.startWatcher()

        XCTAssertTrue(service.startedParams.isEmpty)
        XCTAssertNil(viewModel.activeWatcherId)
        XCTAssertNotNil(viewModel.watcherError)
    }

    @MainActor
    func testWatcherTransactionEventMarksWatcherConnected() async throws {
        let service = MockWatcherService()
        let viewModel = makeViewModel(service: service)

        await viewModel.startWatcher()
        let watcherId = try XCTUnwrap(viewModel.activeWatcherId)
        let listener = try XCTUnwrap(service.startedListeners.first)

        listener.onEvent(watcherId: watcherId, event: Self.sampleTransactionsChangedEvent())
        await waitUntil { viewModel.watcherConnectionStatus == .connected }

        XCTAssertEqual(viewModel.watcherConnectionStatus, .connected)
        XCTAssertEqual(viewModel.watcherBalance?.total, Self.sampleBalance.total)
        XCTAssertEqual(viewModel.watcherTransactionCount, 3)
    }

    @MainActor
    func testWatcherEventIsHandledWhileStartIsInFlight() async throws {
        let service = MockWatcherService()
        service.holdStart = true
        let viewModel = makeViewModel(service: service)

        let startTask = Task { await viewModel.startWatcher() }
        await waitUntil { service.startedParams.count == 1 }
        let watcherId = try XCTUnwrap(service.startedParams.first?.watcherId)
        let listener = try XCTUnwrap(service.startedListeners.first)

        listener.onEvent(watcherId: watcherId, event: Self.sampleTransactionsChangedEvent())
        await waitUntil { viewModel.watcherConnectionStatus == .connected }

        XCTAssertTrue(viewModel.isStartingWatcher)
        XCTAssertNil(viewModel.activeWatcherId)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .connected)

        service.completeStart()
        await startTask.value

        XCTAssertFalse(viewModel.isStartingWatcher)
        XCTAssertEqual(viewModel.activeWatcherId, watcherId)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .connected)
    }

    @MainActor
    func testStopWatcherStopsServiceWatcherAndClearsWatcherState() async throws {
        let service = MockWatcherService()
        let viewModel = makeViewModel(service: service)

        await viewModel.startWatcher()
        let watcherId = try XCTUnwrap(viewModel.activeWatcherId)
        let listener = try XCTUnwrap(service.startedListeners.first)
        listener.onEvent(watcherId: watcherId, event: Self.sampleTransactionsChangedEvent())
        await waitUntil { viewModel.watcherConnectionStatus == .connected }

        viewModel.stopWatcher()

        XCTAssertEqual(service.stoppedWatcherIds, [watcherId])
        XCTAssertNil(viewModel.activeWatcherId)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .idle)
        XCTAssertNil(viewModel.watcherBalance)
        XCTAssertTrue(viewModel.watcherTransactions.isEmpty)
    }

    /// iOS-specific: the root view calls stopAllWatchers from onDisappear since the
    /// ViewModel is app-lifetime (no onCleared equivalent).
    @MainActor
    func testStopAllWatchersStopsActiveWatcherAndService() async throws {
        let service = MockWatcherService()
        let viewModel = makeViewModel(service: service)

        await viewModel.startWatcher()
        let watcherId = try XCTUnwrap(viewModel.activeWatcherId)

        viewModel.stopAllWatchers()

        XCTAssertEqual(service.stoppedWatcherIds, [watcherId])
        XCTAssertEqual(service.stopAllWatchersCallCount, 1)
        XCTAssertNil(viewModel.activeWatcherId)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .idle)
    }
}
