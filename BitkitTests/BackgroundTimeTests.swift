@testable import Bitkit
import UIKit
import XCTest

final class BackgroundTimeTests: XCTestCase {
    private final class FakeTasks: @unchecked Sendable {
        let lock = NSLock()
        var began: [String] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        var expiration: (() -> Void)?
        var expireOnBegin = false

        func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
            lock.withLock {
                began.append(name)
                self.expiration = expiration
            }
            if expireOnBegin {
                expiration()
            }
            return UIBackgroundTaskIdentifier(rawValue: 7)
        }

        func end(_ identifier: UIBackgroundTaskIdentifier) {
            lock.withLock { ended.append(identifier) }
        }

        func make(_ name: String = "work") -> BackgroundTime {
            BackgroundTime(name: name, begin: begin, end: end)
        }
    }

    func testEndEndsTheTaskOnce() {
        let tasks = FakeTasks()
        let backgroundTime = tasks.make()

        backgroundTime.end()
        backgroundTime.end()

        XCTAssertEqual(tasks.began, ["work"])
        XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
    }

    func testExpirationEndsTheTask() {
        let tasks = FakeTasks()
        let backgroundTime = tasks.make()

        tasks.expiration?()
        backgroundTime.end()

        XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
    }

    func testExpirationBeforeTheIdentifierIsStoredStillEndsTheTask() {
        let tasks = FakeTasks()
        tasks.expireOnBegin = true

        let backgroundTime = tasks.make()
        backgroundTime.end()

        XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
    }

    func testReleasingEndsTheTask() {
        let tasks = FakeTasks()
        _ = tasks.make()

        XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
    }

    func testOnlyDatabaseQueuesAskForBackgroundTime() {
        XCTAssertTrue(ServiceQueue.ServiceTypes.core.usesDatabases)
        XCTAssertTrue(ServiceQueue.ServiceTypes.migration.usesDatabases)
        XCTAssertFalse(ServiceQueue.ServiceTypes.ldk.usesDatabases)
        XCTAssertFalse(ServiceQueue.ServiceTypes.forex.usesDatabases)
        XCTAssertFalse(ServiceQueue.ServiceTypes.backup.usesDatabases)
    }
}
