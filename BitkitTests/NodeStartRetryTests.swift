@testable import Bitkit
import SwiftUI
import XCTest

@MainActor
final class NodeStartRetryTests: XCTestCase {
    private struct StartFailure: Error {}

    /// Stands in for the wallet, the network and the Recovery screen behind a `NodeRestarter`.
    private final class Harness {
        var state = NodeLifecycleState.errorStarting(cause: StartFailure())
        var isConnected = true
        var walletExists: Bool? = true
        var isRecoveryShown = false
        var startHaptics: [Bool] = []
        var stopCalls = 0
        var stopError: Error?
        /// Runs inside the start, to change the world while the start is in flight.
        var duringStart: (() -> Void)?

        func makeRestarter() -> NodeRestarter {
            NodeRestarter(
                nodeState: { self.state },
                isConnected: { self.isConnected },
                walletExists: { self.walletExists },
                isRecoveryShown: { self.isRecoveryShown },
                start: { playsErrorHaptic in
                    self.startHaptics.append(playsErrorHaptic)
                    self.duringStart?()
                },
                stop: {
                    self.stopCalls += 1
                    if let error = self.stopError {
                        throw error
                    }
                }
            )
        }
    }

    // MARK: Retry on returning to the foreground

    func testRetriesAFailedStartAfterReturningFromTheBackground() async {
        let harness = Harness()
        await harness.makeRestarter().retryOnForeground(returnedFromBackground: true)?.value
        XCTAssertEqual(harness.startHaptics.count, 1)
    }

    func testDoesNotRetryOnAnInactiveBlipThatNeverEnteredTheBackground() async {
        let harness = Harness()
        let task = harness.makeRestarter().retryOnForeground(returnedFromBackground: false)
        await task?.value
        XCTAssertNil(task)
        XCTAssertTrue(harness.startHaptics.isEmpty)
    }

    func testDoesNotRetryWhileOffline() async {
        let harness = Harness()
        harness.isConnected = false
        await harness.makeRestarter().retryOnForeground(returnedFromBackground: true)?.value
        XCTAssertTrue(harness.startHaptics.isEmpty)
    }

    func testDoesNotRetryWithoutAWallet() async {
        for walletExists in [false, nil] {
            let harness = Harness()
            harness.walletExists = walletExists
            await harness.makeRestarter().retryOnForeground(returnedFromBackground: true)?.value
            XCTAssertTrue(harness.startHaptics.isEmpty, "\(String(describing: walletExists))")
        }
    }

    func testDoesNotRetryWhileTheRecoveryScreenIsShown() async {
        let harness = Harness()
        harness.isRecoveryShown = true
        await harness.makeRestarter().retryOnForeground(returnedFromBackground: true)?.value
        XCTAssertTrue(harness.startHaptics.isEmpty)
    }

    func testDoesNotRetryStatesThatAreNotAFailedStart() async {
        for state in [NodeLifecycleState.stopped, .starting, .running, .stopping, .initializing] {
            let harness = Harness()
            harness.state = state
            await harness.makeRestarter().retryOnForeground(returnedFromBackground: true)?.value
            XCTAssertTrue(harness.startHaptics.isEmpty, "\(state)")
        }
    }

    // MARK: Error haptic

    func testRestartsTriggeredByTheLifecycleDoNotPlayTheErrorHaptic() async {
        let foreground = Harness()
        await foreground.makeRestarter().retryOnForeground(returnedFromBackground: true)?.value
        XCTAssertEqual(foreground.startHaptics, [false])

        let networkRestored = Harness()
        await networkRestored.makeRestarter().restart(reason: "Network restored").value
        XCTAssertEqual(networkRestored.startHaptics, [false])
    }

    // MARK: Recovery

    func testRestartDoesNotStartTheNodeWhileTheRecoveryScreenIsShown() async {
        let harness = Harness()
        harness.isRecoveryShown = true
        await harness.makeRestarter().restart(reason: "Network restored").value
        XCTAssertTrue(harness.startHaptics.isEmpty)
        XCTAssertEqual(harness.stopCalls, 0)
    }

    func testStopsANodeThatStartedWhileRecoveryOpened() async {
        let harness = Harness()
        harness.duringStart = {
            harness.state = .running
            harness.isRecoveryShown = true
        }
        await harness.makeRestarter().retryOnForeground(returnedFromBackground: true)?.value
        XCTAssertEqual(harness.stopCalls, 1)
    }

    func testLeavesTheNodeAloneWhenRecoveryOpenedButTheStartFailed() async {
        let harness = Harness()
        harness.duringStart = { harness.isRecoveryShown = true }
        await harness.makeRestarter().restart(reason: "Network restored").value
        XCTAssertEqual(harness.stopCalls, 0)
    }

    func testLeavesARunningNodeAloneOutsideRecovery() async {
        let harness = Harness()
        harness.duringStart = { harness.state = .running }
        await harness.makeRestarter().restart(reason: "Network restored").value
        XCTAssertEqual(harness.stopCalls, 0)
    }

    func testAFailedStopDoesNotEndTheRestartWithAnError() async {
        let harness = Harness()
        harness.stopError = StartFailure()
        harness.duringStart = {
            harness.state = .running
            harness.isRecoveryShown = true
        }
        await harness.makeRestarter().restart(reason: "Network restored").value
        XCTAssertEqual(harness.stopCalls, 1)
    }

    // MARK: Scene phases

    func testOnlyAnActivePhaseAfterTheBackgroundIsAReturnFromTheBackground() {
        var tracker = ForegroundReturnTracker()
        XCTAssertFalse(tracker.scenePhaseChanged(to: .active))
        XCTAssertFalse(tracker.scenePhaseChanged(to: .inactive))
        XCTAssertFalse(tracker.scenePhaseChanged(to: .active), "an inactive blip is not a return")
        XCTAssertFalse(tracker.scenePhaseChanged(to: .inactive))
        XCTAssertFalse(tracker.scenePhaseChanged(to: .background))
        XCTAssertFalse(tracker.scenePhaseChanged(to: .inactive))
        XCTAssertTrue(tracker.scenePhaseChanged(to: .active))
        XCTAssertFalse(tracker.scenePhaseChanged(to: .active), "the return counts once")
    }
}
