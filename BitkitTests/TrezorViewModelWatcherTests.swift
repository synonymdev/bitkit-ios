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

    /// iOS-specific: stopping while the native start call is still in flight
    /// quarantines the starting watcher — its events are dropped immediately
    /// instead of repopulating balance/transaction state until the call returns.
    @MainActor
    func testStopWatcherDuringInFlightStartQuarantinesStartingWatcher() async throws {
        let service = MockWatcherService()
        service.holdStart = true
        let viewModel = makeViewModel(service: service)

        let startTask = Task { await viewModel.startWatcher() }
        await waitUntil { service.startedParams.count == 1 }
        let watcherId = try XCTUnwrap(service.startedParams.first?.watcherId)
        let listener = try XCTUnwrap(service.startedListeners.first)

        viewModel.stopWatcher()

        XCTAssertEqual(service.stoppedWatcherIds, [watcherId])
        XCTAssertFalse(viewModel.isStartingWatcher)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .idle)

        // Events from the canceled startup must not repopulate watcher state.
        listener.onEvent(watcherId: watcherId, event: Self.sampleTransactionsChangedEvent())
        await waitUntil(timeout: 0.2) { viewModel.watcherBalance != nil }

        XCTAssertNil(viewModel.watcherBalance)
        XCTAssertTrue(viewModel.watcherTransactions.isEmpty)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .idle)

        // The held native call returning success must not activate the watcher.
        service.completeStart()
        await startTask.value

        XCTAssertNil(viewModel.activeWatcherId)
        XCTAssertFalse(viewModel.isStartingWatcher)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .idle)
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

    /// iOS-specific: dashboard dismissal also resets the watcher input fields.
    @MainActor
    func testHandleDashboardDismissStopsWatchersAndClearsInputState() async throws {
        let service = MockWatcherService()
        let viewModel = makeViewModel(service: service)
        viewModel.watcherGapLimit = "30"
        viewModel.onchainAccountTypeSelection = .legacy

        await viewModel.startWatcher()
        let watcherId = try XCTUnwrap(viewModel.activeWatcherId)

        viewModel.handleDashboardDismiss()

        XCTAssertEqual(service.stoppedWatcherIds, [watcherId])
        XCTAssertEqual(service.stopAllWatchersCallCount, 1)
        XCTAssertNil(viewModel.activeWatcherId)
        XCTAssertEqual(viewModel.watcherExtendedKey, "")
        XCTAssertEqual(viewModel.watcherGapLimit, "20")
        XCTAssertEqual(viewModel.onchainAccountTypeSelection, .automatic)
    }

    /// iOS-specific: changing the account-type override restarts a running watcher
    /// so the Electrum subscription reflects the new type.
    @MainActor
    func testAccountTypeChangeRestartsRunningWatcher() async throws {
        let service = MockWatcherService()
        let viewModel = makeViewModel(service: service)

        await viewModel.startWatcher()
        let firstWatcherId = try XCTUnwrap(viewModel.activeWatcherId)

        viewModel.onchainAccountTypeSelection = .taproot
        await waitUntil { service.startedParams.count == 2 && viewModel.activeWatcherId != nil }

        XCTAssertEqual(service.stoppedWatcherIds, [firstWatcherId])
        XCTAssertEqual(service.startedParams.count, 2)
        XCTAssertEqual(service.startedParams.last?.accountType, .taproot)
        let secondWatcherId = try XCTUnwrap(viewModel.activeWatcherId)
        XCTAssertNotEqual(secondWatcherId, firstWatcherId)
    }

    /// iOS-specific: an account-type change that lands while the start call is still
    /// in flight is picked up once the call returns — the stale watcher is stopped
    /// and a replacement starts with the new type.
    @MainActor
    func testAccountTypeChangeDuringStartRestartsWithNewType() async throws {
        let service = MockWatcherService()
        service.holdStart = true
        let viewModel = makeViewModel(service: service)

        let startTask = Task { await viewModel.startWatcher() }
        await waitUntil { service.startedParams.count == 1 }
        let firstWatcherId = try XCTUnwrap(service.startedParams.first?.watcherId)

        viewModel.onchainAccountTypeSelection = .taproot
        service.holdStart = false
        service.completeStart()
        await startTask.value
        await waitUntil { service.startedParams.count == 2 && viewModel.activeWatcherId != nil }

        XCTAssertEqual(service.stoppedWatcherIds, [firstWatcherId])
        XCTAssertEqual(service.startedParams.count, 2)
        XCTAssertEqual(service.startedParams.last?.accountType, .taproot)
        XCTAssertEqual(viewModel.activeWatcherId, service.startedParams.last?.watcherId)
    }

    /// iOS-specific: dismissing the dashboard right after an account-type change
    /// cancels the pending restart instead of reviving a watcher or surfacing a
    /// validation error for the cleared key.
    @MainActor
    func testDismissAfterAccountTypeChangeCancelsPendingRestart() async throws {
        let service = MockWatcherService()
        let viewModel = makeViewModel(service: service)

        await viewModel.startWatcher()
        let firstWatcherId = try XCTUnwrap(viewModel.activeWatcherId)

        viewModel.onchainAccountTypeSelection = .taproot
        viewModel.handleDashboardDismiss()
        await waitUntil(timeout: 0.2) { service.startedParams.count > 1 }

        XCTAssertEqual(service.startedParams.count, 1)
        XCTAssertEqual(service.stoppedWatcherIds, [firstWatcherId])
        XCTAssertNil(viewModel.activeWatcherId)
        XCTAssertNil(viewModel.watcherError)
    }

    /// iOS-specific: dismissing the dashboard while the native start call is in flight
    /// aborts the Rust-side startup, which surfaces as a thrown
    /// "Watcher stopped during startup" (wrapped in AppError by ServiceQueue).
    /// That is a cancellation, not a failure — no error is shown to the user.
    @MainActor
    func testDismissDuringInFlightStartTreatsAbortedStartupAsCancellation() async {
        let service = MockWatcherService()
        service.holdStart = true
        let viewModel = makeViewModel(service: service)

        let startTask = Task { await viewModel.startWatcher() }
        await waitUntil { service.startedParams.count == 1 }

        viewModel.handleDashboardDismiss()
        let nativeError = AccountInfoError.WatcherError(errorDetails: "Watcher stopped during startup")
        service.completeStart(with: .failure(AppError(error: nativeError)))
        await startTask.value

        XCTAssertNil(viewModel.watcherError)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .idle)
        XCTAssertFalse(viewModel.isStartingWatcher)
        XCTAssertNil(viewModel.activeWatcherId)
        XCTAssertEqual(viewModel.watcherExtendedKey, "")
    }

    /// iOS-specific: the native cancellation error is treated as graceful even when
    /// no stop was requested on the Swift side (e.g. the core stopped the watcher
    /// directly), based on the typed error alone.
    @MainActor
    func testNativeStartupCancellationWithoutStopRequestFinishesGracefully() async {
        let service = MockWatcherService()
        service.holdStart = true
        let viewModel = makeViewModel(service: service)

        let startTask = Task { await viewModel.startWatcher() }
        await waitUntil { service.startedParams.count == 1 }

        service.completeStart(with: .failure(AccountInfoError.WatcherError(errorDetails: "Watcher stopped during startup")))
        await startTask.value

        XCTAssertNil(viewModel.watcherError)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .idle)
        XCTAssertFalse(viewModel.isStartingWatcher)
        XCTAssertNil(viewModel.activeWatcherId)
    }

    /// iOS-specific: a genuine native failure (not a cancellation) still surfaces
    /// to the user as a watcher error.
    @MainActor
    func testGenuineStartFailureStillSurfacesError() async {
        let service = MockWatcherService()
        service.holdStart = true
        let viewModel = makeViewModel(service: service)

        let startTask = Task { await viewModel.startWatcher() }
        await waitUntil { service.startedParams.count == 1 }

        let nativeError = AccountInfoError.ElectrumError(errorDetails: "connection refused")
        service.completeStart(with: .failure(AppError(error: nativeError)))
        await startTask.value

        XCTAssertNotNil(viewModel.watcherError)
        XCTAssertEqual(viewModel.watcherConnectionStatus, .error)
        XCTAssertFalse(viewModel.isStartingWatcher)
        XCTAssertNil(viewModel.activeWatcherId)
    }

    /// iOS-specific: changing the account type while no watcher runs starts nothing.
    @MainActor
    func testAccountTypeChangeDoesNotStartWatcherWhenIdle() async {
        let service = MockWatcherService()
        let viewModel = makeViewModel(service: service)

        viewModel.onchainAccountTypeSelection = .taproot
        await waitUntil(timeout: 0.2) { !service.startedParams.isEmpty }

        XCTAssertTrue(service.startedParams.isEmpty)
        XCTAssertNil(viewModel.activeWatcherId)
    }
}
