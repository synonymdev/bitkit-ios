@testable import Bitkit
import XCTest

@MainActor
final class OnchainConnectionMonitorTests: XCTestCase {
    private let backgroundedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testShortBackgroundStayDoesNotWaitForTheNetwork() async {
        let monitor = OnchainConnectionMonitor(retryInterval: .milliseconds(10))
        var syncs = 0
        monitor.appDidEnterBackground(at: backgroundedAt)
        monitor.appDidBecomeActive(at: backgroundedAt.addingTimeInterval(10)) { syncs += 1 }
        XCTAssertFalse(monitor.isReconnecting)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(syncs, 0)
    }

    func testLongBackgroundStayWaitsUntilASyncSucceeds() async throws {
        let monitor = OnchainConnectionMonitor(retryInterval: .milliseconds(10))
        var failures = 2
        monitor.appDidEnterBackground(at: backgroundedAt)
        monitor.appDidBecomeActive(at: backgroundedAt.addingTimeInterval(OnchainConnectionMonitor.backgroundThreshold)) {
            if failures > 0 {
                failures -= 1
                throw URLError(.networkConnectionLost)
            }
        }
        XCTAssertTrue(monitor.isReconnecting)
        for _ in 0 ..< 100 where monitor.isReconnecting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(monitor.isReconnecting)
        XCTAssertEqual(failures, 0)
    }

    func testUnfinishedWaitResumesAfterAShortBackgroundStay() async throws {
        let monitor = OnchainConnectionMonitor(retryInterval: .milliseconds(10))
        monitor.appDidEnterBackground(at: backgroundedAt)
        monitor.appDidBecomeActive(at: backgroundedAt.addingTimeInterval(60)) { throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(monitor.isReconnecting)
        monitor.appDidEnterBackground(at: backgroundedAt.addingTimeInterval(61))
        monitor.appDidBecomeActive(at: backgroundedAt.addingTimeInterval(62)) {}
        XCTAssertTrue(monitor.isReconnecting)
        for _ in 0 ..< 100 where monitor.isReconnecting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(monitor.isReconnecting)
    }

    func testOnchainSyncEndsTheWaitWhileFullSyncKeepsFailing() async throws {
        let monitor = OnchainConnectionMonitor(retryInterval: .milliseconds(10))
        var attempts = 0
        monitor.appDidEnterBackground(at: backgroundedAt)
        monitor.appDidBecomeActive(at: backgroundedAt.addingTimeInterval(60)) {
            attempts += 1
            throw URLError(.timedOut)
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(monitor.isReconnecting)

        monitor.onchainSyncDidComplete()
        XCTAssertFalse(monitor.isReconnecting)
        let attemptsAfterClear = attempts
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(attempts, attemptsAfterClear)
    }

    func testOnchainSyncWhileBackgroundedKeepsTheWait() {
        let monitor = OnchainConnectionMonitor(retryInterval: .milliseconds(10))
        monitor.appDidEnterBackground(at: backgroundedAt)
        monitor.appDidBecomeActive(at: backgroundedAt.addingTimeInterval(60)) { throw URLError(.timedOut) }
        monitor.appDidEnterBackground(at: backgroundedAt.addingTimeInterval(61))
        monitor.onchainSyncDidComplete()
        XCTAssertTrue(monitor.isReconnecting)
    }
}
