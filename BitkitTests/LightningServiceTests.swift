@testable import Bitkit
import LDKNode
import XCTest

final class LightningServiceTests: XCTestCase {
    func testStopReleasesANodeWhoseStartFailed() {
        XCTAssertNoThrow(try Bitkit.LightningService.stopReleasingFinishedNode { throw NodeError.NotRunning(message: "") })
    }

    func testStopKeepsANodeThatFailedToPersistUntilARetryFindsItStopped() {
        XCTAssertThrowsError(try Bitkit.LightningService.stopReleasingFinishedNode { throw NodeError.PersistenceFailed(message: "") })
        XCTAssertNoThrow(try Bitkit.LightningService.stopReleasingFinishedNode { throw NodeError.NotRunning(message: "") })
    }

    func testStopReleasesANodeThatStopped() {
        var didStop = false
        XCTAssertNoThrow(try Bitkit.LightningService.stopReleasingFinishedNode { didStop = true })
        XCTAssertTrue(didStop)
    }

    func testStopKeepsANodeWhoseStopFailedOtherwise() {
        XCTAssertThrowsError(try Bitkit.LightningService.stopReleasingFinishedNode { throw NodeError.ConnectionFailed(message: "") })
    }

    func testAStartFailingBecauseTheNodeRunsIsRecognizedThroughTheQueueWrapper() {
        let alreadyRunning = NodeError.AlreadyRunning(message: "")
        XCTAssertTrue(Bitkit.LightningService.isAlreadyRunning(alreadyRunning))
        XCTAssertTrue(Bitkit.LightningService.isAlreadyRunning(Bitkit.AppError(error: alreadyRunning)))
        XCTAssertFalse(Bitkit.LightningService.isAlreadyRunning(Bitkit.AppError(error: NodeError.ConnectionFailed(message: ""))))
    }

    func testWaitForEndReturnsOnceTheTaskEnds() async {
        let task = Task<Void, Never> { try? await Task.sleep(for: .milliseconds(50)) }
        let ended = await Bitkit.LightningService.waitForEnd(of: task, timeout: .seconds(10))
        XCTAssertTrue(ended)
    }

    func testStopWithoutANodeLeavesTheLightningLockToItsHolder() async throws {
        try XCTSkipIf(Bitkit.LightningService.shared.onchainDispatchNode != nil, "a node is configured in the test host")
        try await StateLocker.lock(.lightning, wait: 1)
        defer { try? StateLocker.unlock(.lightning) }
        try await Bitkit.LightningService.shared.stop()
        XCTAssertTrue(StateLocker.isLocked(.lightning))
    }

    func testWaitForEndNeverReportsAnEndedTaskAsTimedOut() async {
        for _ in 0 ..< 200 {
            let task = Task {}
            let ended = await Bitkit.LightningService.waitForEnd(of: task, timeout: .seconds(10))
            XCTAssertTrue(ended)
        }
    }

    func testWaitForEndGivesUpOnATaskThatDoesNotEnd() async {
        let release = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in release.stream {}
        }
        let ended = await Bitkit.LightningService.waitForEnd(of: task, timeout: .milliseconds(50))
        XCTAssertFalse(ended)
        release.continuation.finish()
        await task.value
    }

    // Regression: a stopped node's VSS writes can keep retrying past one build's wait for them, so the recovery start
    // retries while the build fails on the busy store instead of leaving the node offline.
    func testRecoveryStartRetriesWhileTheVssStoreIsBusy() async throws {
        let busy = Bitkit.AppError(error: BuildError.KvStoreSetupFailed(message: "in flight"))
        var attempts = 0
        try await Bitkit.LightningService.startRetryingBusyStore(stopRequested: { false }) {
            attempts += 1
            if attempts < 3 {
                throw busy
            }
        }
        XCTAssertEqual(attempts, 3)
    }

    func testRecoveryStartGivesUpAfterItsAttempts() async {
        var attempts = 0
        do {
            try await Bitkit.LightningService.startRetryingBusyStore(stopRequested: { false }) {
                attempts += 1
                throw Bitkit.AppError(error: BuildError.KvStoreSetupFailed(message: "in flight"))
            }
            XCTFail("expected the last failure")
        } catch {}
        XCTAssertEqual(attempts, Bitkit.LightningService.busyStoreStartAttempts)
    }

    func testRecoveryStartDoesNotRetryOtherFailures() async {
        var attempts = 0
        do {
            try await Bitkit.LightningService.startRetryingBusyStore(stopRequested: { false }) {
                attempts += 1
                throw Bitkit.AppError(error: BuildError.WalletSetupFailed(message: ""))
            }
            XCTFail("expected the failure")
        } catch {}
        XCTAssertEqual(attempts, 1)
    }

    // Regression: a stop requested while the recovery runs wins over its retry.
    func testRecoveryStartDoesNotRetryOverARequestedStop() async {
        var attempts = 0
        var stopRequested = false
        do {
            try await Bitkit.LightningService.startRetryingBusyStore(stopRequested: { stopRequested }) {
                attempts += 1
                stopRequested = true
                throw Bitkit.AppError(error: BuildError.KvStoreSetupFailed(message: "in flight"))
            }
            XCTFail("expected the skipped start to fail")
        } catch {}
        XCTAssertEqual(attempts, 1)
    }

    func testRecoveryStartDoesNotStartOverAStopRequestedBeforeIt() async {
        var attempts = 0
        do {
            try await Bitkit.LightningService.startRetryingBusyStore(stopRequested: { true }) { attempts += 1 }
            XCTFail("expected the skipped start to fail")
        } catch {}
        XCTAssertEqual(attempts, 0)
    }

    // Regression: a busy store has nothing to do with the requested Electrum or RGS server, so the change retries it
    // instead of falling back to the previous config.
    func testConfigChangeRetriesItsOwnStartWhileTheVssStoreIsBusy() async throws {
        var attempts = 0
        var recovered = false
        try await Bitkit.LightningService.applyConfigChange(
            stopRequested: { false },
            start: {
                attempts += 1
                if attempts < 2 {
                    throw Bitkit.AppError(error: BuildError.KvStoreSetupFailed(message: "in flight"))
                }
            },
            recover: { recovered = true }
        )
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(recovered)
    }

    func testConfigChangeRecoversAfterAnotherFailure() async {
        var attempts = 0
        var recovered = false
        do {
            try await Bitkit.LightningService.applyConfigChange(
                stopRequested: { false },
                start: {
                    attempts += 1
                    throw Bitkit.AppError(error: BuildError.WalletSetupFailed(message: ""))
                },
                recover: { recovered = true }
            )
            XCTFail("expected the change to fail")
        } catch {}
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(recovered)
    }

    func testBuiltNodeIsReleasedInsteadOfStartedAfterAStopDuringSetup() async {
        var released = false
        var started = false
        do {
            try await Bitkit.LightningService.startUnlessStopRequested(
                stopRequested: { true },
                release: { released = true },
                start: { started = true }
            )
            XCTFail("expected the start to yield to the stop")
        } catch {}
        XCTAssertTrue(released)
        XCTAssertFalse(started)
    }

    func testQueuedRestartLeavesTheCurrentNodeAfterAStopWhileItWaited() async {
        var stoppedCurrent = false
        do {
            try await Bitkit.LightningService.stopCurrentNodeUnlessStopRequested(stopRequested: { true }) {
                stoppedCurrent = true
            }
            XCTFail("expected the restart to yield to the stop")
        } catch {}
        XCTAssertFalse(stoppedCurrent)
    }

    func testQueuedRestartStopsTheCurrentNodeWithoutAStop() async throws {
        var stoppedCurrent = false
        try await Bitkit.LightningService.stopCurrentNodeUnlessStopRequested(stopRequested: { false }) {
            stoppedCurrent = true
        }
        XCTAssertTrue(stoppedCurrent)
    }

    func testBuiltNodeStartsWithoutAStopDuringSetup() async throws {
        var released = false
        var started = false
        try await Bitkit.LightningService.startUnlessStopRequested(
            stopRequested: { false },
            release: { released = true },
            start: { started = true }
        )
        XCTAssertFalse(released)
        XCTAssertTrue(started)
    }

    func testConfigChangeDoesNotRecoverOverAStopThatEndedIt() async {
        var stopped = false
        var recovered = false
        do {
            try await Bitkit.LightningService.applyConfigChange(
                stopRequested: { stopped },
                start: {
                    stopped = true
                    throw Bitkit.AppError(serviceError: .nodeNotSetup)
                },
                recover: { recovered = true }
            )
            XCTFail("expected the change to fail")
        } catch {}
        XCTAssertFalse(recovered)
    }
}
