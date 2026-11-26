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

    func testWithoutTheAppsHooksNoTaskIsEnded() {
        let tasks = FakeTasks()
        let backgroundTime = BackgroundTime(name: "work", begin: { _, _ in .invalid }, end: tasks.end)

        backgroundTime.end()

        XCTAssertEqual(tasks.ended, [])
    }

    /// Runs `body` with `tasks` installed as the app's hooks.
    private func withHooks(_ tasks: FakeTasks, _ body: () async throws -> Void) async rethrows {
        let (begin, end) = (BackgroundTime.beginTask, BackgroundTime.endTask)
        BackgroundTime.beginTask = tasks.begin
        BackgroundTime.endTask = tasks.end
        defer { (BackgroundTime.beginTask, BackgroundTime.endTask) = (begin, end) }
        try await body()
    }

    func testDuringEndsTheTaskAlsoWhenTheBodyThrows() async {
        struct Failure: Error {}
        let tasks = FakeTasks()

        await withHooks(tasks) {
            _ = try? await BackgroundTime.during("quote") { () async throws -> Int in throw Failure() }
        }

        XCTAssertEqual(tasks.began, ["quote"])
        XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
    }

    func testDatabaseQueueWorkHoldsBackgroundTimeUntilItEnds() async throws {
        let tasks = FakeTasks()

        try await withHooks(tasks) {
            _ = try await ServiceQueue.background(.core) { 1 }
            _ = try await ServiceQueue.background(.ldk) { 1 }
        }

        XCTAssertEqual(tasks.began.count, 1)
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
