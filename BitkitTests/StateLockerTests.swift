import XCTest

final class StateLockerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        try? StateLocker.unlock(.lightning)
        try? StateLocker.unlock(.onchain)
        StateLocker.injectTestDate(Date())
        StateLocker.injectTestEnvironment(nil)
    }

    override func tearDown() {
        try? StateLocker.unlock(.lightning)
        try? StateLocker.unlock(.onchain)
        StateLocker.injectTestDate(Date())
        StateLocker.injectTestEnvironment(nil)
        super.tearDown()
    }

    func testLockAndUnlock() async throws {
        try await StateLocker.lock(.lightning, wait: 1)
        XCTAssertTrue(StateLocker.isLocked(.lightning))
        XCTAssertNoThrow(try StateLocker.unlock(.lightning))
        XCTAssertFalse(StateLocker.isLocked(.lightning))
    }

    func testLockTimeout() async {
        StateLocker.injectTestEnvironment(.foregroundApp)
        try? await StateLocker.lock(.lightning, wait: 1)

        // Pretend we're not the extension and we need to lock
        StateLocker.injectTestEnvironment(.pushNotificationExtension)

        do {
            try await StateLocker.lock(.lightning, wait: 0.1)
            XCTFail("Expected lock to throw")
        } catch {
            XCTAssertEqual(error as? StateLockerError, .alreadyLocked(processName: "lightning"))
        }
        StateLocker.injectTestEnvironment(nil)
    }

    func testUnlockNonExistentLock() {
        XCTAssertNoThrow(try StateLocker.unlock(.onchain))
    }

    func testLockExpiry() async throws {
        // Inject a past date for quick testing
        let pastDate = Date().addingTimeInterval(-3600) // 1 hour ago
        StateLocker.injectTestDate(pastDate)

        try await StateLocker.lock(.lightning, wait: 1)

        StateLocker.injectTestDate(Date()) // Reset to current date
        XCTAssertFalse(StateLocker.isLocked(.lightning))
    }

    func testDifferentProcessLocks() async throws {
        try await StateLocker.lock(.lightning, wait: 1)
        try await StateLocker.lock(.onchain, wait: 1)
        XCTAssertTrue(StateLocker.isLocked(.lightning))
        XCTAssertTrue(StateLocker.isLocked(.onchain))
    }

    func testLockInDifferentEnvironments() async throws {
        // Test foreground app environment
        StateLocker.injectTestEnvironment(.foregroundApp)
        try await StateLocker.lock(.lightning, wait: 1)
        XCTAssertTrue(StateLocker.isLocked(.lightning))
        XCTAssertNoThrow(try StateLocker.unlock(.lightning))

        // Test push notification extension environment
        StateLocker.injectTestEnvironment(.pushNotificationExtension)
        try await StateLocker.lock(.onchain, wait: 1)
        XCTAssertTrue(StateLocker.isLocked(.onchain))
        XCTAssertNoThrow(try StateLocker.unlock(.onchain))
    }

    func testLockConflictBetweenEnvironments() async {
        // Lock in foreground app environment
        StateLocker.injectTestEnvironment(.foregroundApp)
        try? await StateLocker.lock(.lightning, wait: 1)
        XCTAssertTrue(StateLocker.isLocked(.lightning))

        // Attempt to lock in push notification extension environment
        StateLocker.injectTestEnvironment(.pushNotificationExtension)
        do {
            try await StateLocker.lock(.lightning, wait: 0.1)
            XCTFail("Expected lock to throw")
        } catch {
            XCTAssertEqual(error as? StateLockerError, .alreadyLocked(processName: "lightning"))
        }

        StateLocker.injectTestEnvironment(.foregroundApp)
        XCTAssertNoThrow(try StateLocker.unlock(.lightning))
    }

    func testLockExpiryInDifferentEnvironments() async throws {
        let pastDate = Date().addingTimeInterval(-3600) // 1 hour ago

        // Set past date and lock in foreground app environment
        StateLocker.injectTestDate(pastDate)
        StateLocker.injectTestEnvironment(.foregroundApp)
        try await StateLocker.lock(.lightning, wait: 1)

        // Check lock status in push notification extension environment
        StateLocker.injectTestEnvironment(.pushNotificationExtension)
        StateLocker.injectTestDate(Date()) // Reset to current date
        XCTAssertFalse(StateLocker.isLocked(.lightning))

        // Attempt to lock in push notification extension environment
        try await StateLocker.lock(.lightning, wait: 1)
        XCTAssertTrue(StateLocker.isLocked(.lightning))
    }

    func testUnlockDifferentEnvironment() async throws {
        // Lock in foreground app environment
        StateLocker.injectTestEnvironment(.foregroundApp)
        try await StateLocker.lock(.lightning, wait: 1)

        // Try to unlock from push notification extension environment
        StateLocker.injectTestEnvironment(.pushNotificationExtension)
        XCTAssertThrowsError(try StateLocker.unlock(.lightning)) { error in
            XCTAssertEqual(error as? StateLockerError, .differentEnvironmentLocked)
        }
    }

    func testLockSameEnvironment() async throws {
        StateLocker.injectTestEnvironment(.foregroundApp)

        // First lock
        try await StateLocker.lock(.lightning, wait: 1)
        XCTAssertTrue(StateLocker.isLocked(.lightning))

        // Second lock attempt in same environment should succeed
        try await StateLocker.lock(.lightning, wait: 1)
        XCTAssertTrue(StateLocker.isLocked(.lightning))
    }
}
