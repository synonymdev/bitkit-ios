@testable import Bitkit
import XCTest

final class NodeStartRetryTests: XCTestCase {
    private struct StartFailure: Error {}

    func testRetriesAFailedStartWhenConnectedWithAWallet() {
        XCTAssertTrue(AppScene.shouldRetryNodeStart(state: .errorStarting(cause: StartFailure()), isConnected: true, walletExists: true))
    }

    func testDoesNotRetryWhileOffline() {
        XCTAssertFalse(AppScene.shouldRetryNodeStart(state: .errorStarting(cause: StartFailure()), isConnected: false, walletExists: true))
    }

    func testDoesNotRetryWithoutAWallet() {
        for walletExists in [false, nil] {
            XCTAssertFalse(AppScene.shouldRetryNodeStart(
                state: .errorStarting(cause: StartFailure()),
                isConnected: true,
                walletExists: walletExists
            ))
        }
    }

    func testDoesNotRetryStatesThatAreNotAFailedStart() {
        for state in [NodeLifecycleState.stopped, .starting, .running, .stopping, .initializing] {
            XCTAssertFalse(AppScene.shouldRetryNodeStart(state: state, isConnected: true, walletExists: true), "\(state)")
        }
    }
}
