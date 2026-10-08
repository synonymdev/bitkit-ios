@testable import Bitkit
import XCTest

final class JadeBLELinkStateTests: XCTestCase {
    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: Result<Void, Error>?] = [:]
        private var reads: [JadeBLELinkState.ReadOutcome] = []

        func record(_ name: String, _ result: Result<Void, Error>?) {
            lock.withLock { results[name] = result }
        }

        func recordRead(_ outcome: JadeBLELinkState.ReadOutcome) {
            lock.withLock { reads.append(outcome) }
        }

        func error(of name: String) -> JadeBLEError? {
            lock.withLock {
                guard case let .failure(error)?? = results[name] else { return nil }
                return error as? JadeBLEError
            }
        }

        var readOutcomes: [JadeBLELinkState.ReadOutcome] {
            lock.withLock { reads }
        }
    }

    private func makeConnectedLink() -> JadeBLELinkState {
        let state = JadeBLELinkState(generation: 1)
        _ = state.begin(.connect)
        XCTAssertTrue(state.markConnected())
        return state
    }

    private func failure(of waiter: BLEOneShot, timeout: TimeInterval = 0) -> JadeBLEError? {
        guard case let .failure(error)? = waiter.wait(timeout: timeout) else { return nil }
        return error as? JadeBLEError
    }

    private func succeeded(_ waiter: BLEOneShot, timeout: TimeInterval = 0) -> Bool {
        guard case .success? = waiter.wait(timeout: timeout) else { return false }
        return true
    }

    // MARK: - Closing

    func testClosingReleasesEveryPendingWaiter() {
        let state = JadeBLELinkState(generation: 1)
        let waiters: [(String, BLEOneShot)] = [
            ("connect", state.begin(.connect)),
            ("subscribe", state.begin(.subscribe)),
            ("write", state.begin(.write)),
        ]
        let outcomes = Outcomes()
        let returned = expectation(description: "every blocked thread returned")
        returned.expectedFulfillmentCount = waiters.count + 1

        for (name, waiter) in waiters {
            DispatchQueue.global().async {
                outcomes.record(name, waiter.wait(timeout: 10))
                returned.fulfill()
            }
        }
        DispatchQueue.global().async {
            outcomes.recordRead(state.read(timeout: 10))
            returned.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertTrue(state.beginClosing())
        wait(for: [returned], timeout: 1)

        for (name, _) in waiters {
            XCTAssertEqual(outcomes.error(of: name), .closed, name)
        }
        XCTAssertEqual(outcomes.readOutcomes, [.down])
    }

    func testCloseIsIdempotent() {
        let state = makeConnectedLink()

        XCTAssertTrue(state.beginClosing())
        XCTAssertFalse(state.beginClosing())
        XCTAssertTrue(state.isClosing)
    }

    func testSecondCloserWaitsForTheFirstToFinish() {
        let state = makeConnectedLink()
        XCTAssertTrue(state.beginClosing())

        XCTAssertFalse(state.waitUntilClosed(timeout: 0.05))
        state.finishClosing()
        XCTAssertTrue(state.waitUntilClosed(timeout: 0))
    }

    func testClosingKeepsTheDisconnectWaiter() {
        let state = makeConnectedLink()
        let disconnected = state.begin(.disconnect)

        XCTAssertTrue(state.beginClosing())
        XCTAssertNil(disconnected.wait(timeout: 0))

        XCTAssertFalse(state.markDown(reason: JadeBLEError.disconnected))
        XCTAssertTrue(succeeded(disconnected))
    }

    func testClosingLinkIsNeverReady() throws {
        let state = makeConnectedLink()
        try state.markReady(chunkSize: 182)
        XCTAssertTrue(state.isReady)
        XCTAssertTrue(state.isUsable)
        XCTAssertEqual(state.chunkSize, 182)

        XCTAssertTrue(state.beginClosing())

        XCTAssertFalse(state.isReady)
        XCTAssertFalse(state.isUsable)
        XCTAssertFalse(state.reuseIfUsable())
        XCTAssertThrowsError(try state.markReady(chunkSize: 182)) { XCTAssertEqual($0 as? JadeBLEError, .closed) }
        XCTAssertEqual(failure(of: state.begin(.write)), .closed)
    }

    func testReadyLinkCanBeReused() throws {
        let state = makeConnectedLink()
        try state.markReady(chunkSize: 20)
        state.enqueue(Data([0x01]))

        XCTAssertTrue(state.reuseIfUsable())
        XCTAssertEqual(state.read(timeout: 0.01), .empty)
    }

    // MARK: - Reads

    func testReadReturnsEmptyAfterTimeout() {
        let state = makeConnectedLink()
        let start = Date()

        XCTAssertEqual(state.read(timeout: 0.05), .empty)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.04)
    }

    func testNotificationsReturnedInOrderJoined() {
        let state = makeConnectedLink()
        state.enqueue(Data([0x01, 0x02]))
        state.enqueue(Data([0x03]))
        state.enqueue(Data([0x04, 0x05]))

        XCTAssertEqual(state.read(timeout: 0.05), .data(Data([0x01, 0x02, 0x03, 0x04, 0x05])))
        XCTAssertEqual(state.read(timeout: 0.01), .empty)
    }

    func testEmptyNotificationsAndNotificationsAfterClosingAreIgnored() {
        let state = makeConnectedLink()
        state.enqueue(Data())
        XCTAssertEqual(state.read(timeout: 0.01), .empty)

        XCTAssertTrue(state.beginClosing())
        state.enqueue(Data([0x01]))
        XCTAssertEqual(state.read(timeout: 0.01), .down)
    }

    func testReadReportsDownAfterLinkDrops() {
        let state = makeConnectedLink()
        state.enqueue(Data([0x01]))

        XCTAssertTrue(state.markDown(reason: JadeBLEError.disconnected))

        XCTAssertEqual(state.read(timeout: 0.05), .down)
        XCTAssertFalse(state.isLinkUp)
    }

    // MARK: - Drops

    func testDropDuringSetupFailsWaitersWithTheReason() {
        let state = makeConnectedLink()
        let subscribed = state.begin(.subscribe)
        let disconnected = state.begin(.disconnect)

        XCTAssertTrue(state.markDown(reason: JadeBLEError.staleBond))

        XCTAssertEqual(failure(of: subscribed), .staleBond)
        XCTAssertTrue(succeeded(disconnected))
        XCTAssertEqual(failure(of: state.begin(.write)), .staleBond)
        XCTAssertTrue(succeeded(state.begin(.disconnect)))
        XCTAssertThrowsError(try state.markReady(chunkSize: 20)) { XCTAssertEqual($0 as? JadeBLEError, .staleBond) }
    }

    func testDropWhileClosingIsNotExternal() {
        let state = makeConnectedLink()
        XCTAssertTrue(state.beginClosing())

        XCTAssertFalse(state.markDown(reason: JadeBLEError.disconnected))
    }

    // MARK: - Waiters

    func testTimedOutWaiterIgnoresLateResolution() {
        let state = makeConnectedLink()
        let written = state.begin(.write)
        XCTAssertNil(written.wait(timeout: 0.01))

        state.abandon(.write, written)

        XCTAssertFalse(state.resolve(.write, error: nil))
        XCTAssertFalse(written.isResolved)
    }

    func testAbandoningAnOlderWaiterKeepsTheNewerOne() {
        let state = makeConnectedLink()
        let older = state.begin(.subscribe)
        let newer = state.begin(.subscribe)
        XCTAssertEqual(failure(of: older), .closed)

        state.abandon(.subscribe, older)

        XCTAssertTrue(state.resolve(.subscribe, error: nil))
        XCTAssertTrue(succeeded(newer))
    }

    func testResolutionCarriesTheError() {
        let state = makeConnectedLink()
        let written = state.begin(.write)

        XCTAssertTrue(state.resolve(.write, error: JadeBLEError.writeFailed("busy")))

        XCTAssertEqual(failure(of: written), .writeFailed("busy"))
    }

    func testConnectNobodyWaitsForIsNotMarkedUp() {
        let state = JadeBLELinkState(generation: 1)

        XCTAssertFalse(state.markConnected())
        XCTAssertFalse(state.isLinkUp)

        let connected = state.begin(.connect)
        XCTAssertTrue(state.beginClosing())
        XCTAssertEqual(failure(of: connected), .closed)
        XCTAssertFalse(state.markConnected())
        XCTAssertFalse(state.isLinkUp)
    }

    func testFirstResolutionWins() {
        let waiter = BLEOneShot()

        waiter.resolve(.failure(JadeBLEError.writeTimeout))
        waiter.resolve(.success(()))

        XCTAssertEqual(failure(of: waiter), .writeTimeout)
        XCTAssertEqual(failure(of: waiter), .writeTimeout)
    }

    func testWritesAreCounted() {
        let state = makeConnectedLink()

        state.recordWrite()
        state.recordWrite()

        XCTAssertEqual(state.writesCompleted, 2)
    }
}
