//
//  StateLockerTests.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/19.
//

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
       
    func testLockAndUnlock() {
        XCTAssertNoThrow(try StateLocker.lock(.lightning, wait: 1))
        XCTAssertTrue(StateLocker.isLocked(.lightning))
        XCTAssertNoThrow(try StateLocker.unlock(.lightning))
        XCTAssertFalse(StateLocker.isLocked(.lightning))
    }
       
    func testLockTimeout() {
        StateLocker.injectTestEnvironment(.foregroundApp)
        XCTAssertNoThrow(try StateLocker.lock(.lightning, wait: 1))
        
        // Pretend we're not the extension and we need to lock
        StateLocker.injectTestEnvironment(.pushNotificationExtension)
        
        XCTAssertThrowsError(try StateLocker.lock(.lightning, wait: 0.1)) { error in
            XCTAssertEqual(error as? StateLocker.StateLockerError, .alreadyLocked)
        }
        StateLocker.injectTestEnvironment(nil)
    }
       
    func testUnlockNonExistentLock() {
        XCTAssertNoThrow(try StateLocker.unlock(.onchain))
    }
       
    func testLockExpiry() {
        // Inject a past date for quick testing
        let pastDate = Date().addingTimeInterval(-3600) // 1 hour ago
        StateLocker.injectTestDate(pastDate)
           
        XCTAssertNoThrow(try StateLocker.lock(.lightning, wait: 1))
           
        StateLocker.injectTestDate(Date()) // Reset to current date
        XCTAssertFalse(StateLocker.isLocked(.lightning))
    }
       
    func testDifferentProcessLocks() {
        XCTAssertNoThrow(try StateLocker.lock(.lightning, wait: 1))
        XCTAssertNoThrow(try StateLocker.lock(.onchain, wait: 1))
        XCTAssertTrue(StateLocker.isLocked(.lightning))
        XCTAssertTrue(StateLocker.isLocked(.onchain))
    }
    
    func testLockInDifferentEnvironments() {
        // Test foreground app environment
        StateLocker.injectTestEnvironment(.foregroundApp)
        XCTAssertNoThrow(try StateLocker.lock(.lightning, wait: 1))
        XCTAssertTrue(StateLocker.isLocked(.lightning))
        XCTAssertNoThrow(try StateLocker.unlock(.lightning))

        // Test push notification extension environment
        StateLocker.injectTestEnvironment(.pushNotificationExtension)
        XCTAssertNoThrow(try StateLocker.lock(.onchain, wait: 1))
        XCTAssertTrue(StateLocker.isLocked(.onchain))
        XCTAssertNoThrow(try StateLocker.unlock(.onchain))
    }

    func testLockConflictBetweenEnvironments() {
        // Lock in foreground app environment
        StateLocker.injectTestEnvironment(.foregroundApp)
        XCTAssertNoThrow(try StateLocker.lock(.lightning, wait: 1))

        // Attempt to lock in push notification extension environment
        StateLocker.injectTestEnvironment(.pushNotificationExtension)
        XCTAssertThrowsError(try StateLocker.lock(.lightning, wait: 0.1)) { error in
            XCTAssertEqual(error as? StateLocker.StateLockerError, .alreadyLocked)
        }

        StateLocker.injectTestEnvironment(.foregroundApp)
        XCTAssertNoThrow(try StateLocker.unlock(.lightning))
    }

    func testLockExpiryInDifferentEnvironments() {
        let pastDate = Date().addingTimeInterval(-3600) // 1 hour ago
        
        // Set past date and lock in foreground app environment
        StateLocker.injectTestDate(pastDate)
        StateLocker.injectTestEnvironment(.foregroundApp)
        XCTAssertNoThrow(try StateLocker.lock(.lightning, wait: 1))

        // Check lock status in push notification extension environment
        StateLocker.injectTestEnvironment(.pushNotificationExtension)
        StateLocker.injectTestDate(Date()) // Reset to current date
        XCTAssertFalse(StateLocker.isLocked(.lightning))

        // Attempt to lock in push notification extension environment
        XCTAssertNoThrow(try StateLocker.lock(.lightning, wait: 1))
        XCTAssertTrue(StateLocker.isLocked(.lightning))
    }
}
