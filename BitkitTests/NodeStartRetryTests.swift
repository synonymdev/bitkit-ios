@testable import Bitkit
import XCTest

final class NodeStartRetryTests: XCTestCase {
    private struct StartFailure: Error {}

    private let failedStart = NodeLifecycleState.errorStarting(cause: StartFailure())

    private func shouldRetry(
        _ state: NodeLifecycleState,
        isConnected: Bool = true,
        walletExists: Bool? = true,
        isRecoveryShown: Bool = false,
        returnedFromBackground: Bool = true
    ) -> Bool {
        AppScene.shouldRetryNodeStart(
            state: state,
            isConnected: isConnected,
            walletExists: walletExists,
            isRecoveryShown: isRecoveryShown,
            returnedFromBackground: returnedFromBackground
        )
    }

    func testRetriesAFailedStartWhenConnectedWithAWallet() {
        XCTAssertTrue(shouldRetry(failedStart))
    }

    func testDoesNotRetryWhileOffline() {
        XCTAssertFalse(shouldRetry(failedStart, isConnected: false))
    }

    func testDoesNotRetryWhileTheRecoveryScreenIsShown() {
        XCTAssertFalse(shouldRetry(failedStart, isRecoveryShown: true))
    }

    func testDoesNotRetryOnAnInactiveBlipThatNeverEnteredTheBackground() {
        XCTAssertFalse(shouldRetry(failedStart, returnedFromBackground: false))
    }

    func testStopsANodeThatStartedWhileRecoveryOpened() {
        XCTAssertTrue(AppScene.shouldStopNodeStartedUnderRecovery(state: .running, isRecoveryShown: true))
    }

    func testLeavesTheNodeAloneOutsideRecoveryOrBeforeItRuns() {
        XCTAssertFalse(AppScene.shouldStopNodeStartedUnderRecovery(state: .running, isRecoveryShown: false))
        for state in [NodeLifecycleState.stopped, .starting, .stopping, .initializing, failedStart] {
            XCTAssertFalse(AppScene.shouldStopNodeStartedUnderRecovery(state: state, isRecoveryShown: true), "\(state)")
        }
    }

    func testDoesNotRetryWithoutAWallet() {
        for walletExists in [false, nil] {
            XCTAssertFalse(shouldRetry(failedStart, walletExists: walletExists))
        }
    }

    func testDoesNotRetryStatesThatAreNotAFailedStart() {
        for state in [NodeLifecycleState.stopped, .starting, .running, .stopping, .initializing] {
            XCTAssertFalse(shouldRetry(state), "\(state)")
        }
    }
}
