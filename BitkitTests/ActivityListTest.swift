//
//  ActivityListTest.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2024/12/17.
//

@testable import Bitkit
import XCTest

final class ActivityTests: XCTestCase {
    let testDbPath = NSTemporaryDirectory()
    
    override func setUp() async throws {
        try await super.setUp()
        // Initialize the database before each test
        _ = try initDb(basePath: testDbPath)
    }
    
    override func tearDown() async throws {
        try await super.tearDown()
        
        // Clean up the test database directory
        let fileManager = FileManager.default
        let dbPath = (testDbPath as NSString).appendingPathComponent("activity.db")
        
        if fileManager.fileExists(atPath: dbPath) {
            try fileManager.removeItem(atPath: dbPath)
        }
    }
    
    func testInsertAndRetrieveLightningActivity() throws {
        let testValue: Int64 = 123456789
        let testFee: Int64 = 421
        
        // Create a lightning activity
        let lightningActivity = Activity.lightning(LightningActivity(
            id: "test-lightning-1",
            activityType: .lightning,
            txType: .sent,
            status: .succeeded,
            value: testValue,
            fee: testFee,
            invoice: "lnbc...",
            message: "Test payment",
            timestamp: Int64(Date().timeIntervalSince1970),
            preimage: nil,
            createdAt: nil,
            updatedAt: nil
        ))
        
        // Insert the activity
        try insertActivity(activity: lightningActivity)
        
        // Retrieve the activity
        let retrieved = try getActivityById(activityId: "test-lightning-1")
        XCTAssertNotNil(retrieved)
        
        if case let .lightning(activity) = retrieved {
            XCTAssertEqual(activity.id, "test-lightning-1")
            XCTAssertEqual(activity.value, testValue, "Retrieved value should match inserted value")
            XCTAssertEqual(activity.fee, testFee, "Retrieved fee should match inserted fee")
            XCTAssertEqual(activity.status, .succeeded)
        } else {
            XCTFail("Retrieved activity is not of type lightning")
        }
    }
    
    func testInsertAndRetrieveOnchainActivity() throws {
        let testValue: Int64 = 987654321
        let testFee: Int64 = 1234
        let testFeeRate: Int64 = 8
        
        // Create an onchain activity
        let onchainActivity = Activity.onchain(OnchainActivity(
            id: "test-onchain-1",
            activityType: .onchain,
            txType: .received,
            txId: "abc123",
            value: testValue,
            fee: testFee,
            feeRate: testFeeRate,
            address: "bc1...",
            confirmed: true,
            timestamp: Int64(Date().timeIntervalSince1970),
            isBoosted: false,
            isTransfer: false,
            doesExist: true,
            confirmTimestamp: nil,
            channelId: nil,
            transferTxId: nil,
            createdAt: nil,
            updatedAt: nil
        ))
        
        // Insert the activity
        try insertActivity(activity: onchainActivity)
        
        // Retrieve the activity
        let retrieved = try getActivityById(activityId: "test-onchain-1")
        XCTAssertNotNil(retrieved)
        
        if case let .onchain(activity) = retrieved {
            XCTAssertEqual(activity.id, "test-onchain-1")
            XCTAssertEqual(activity.value, testValue, "Retrieved value should match inserted value")
            XCTAssertEqual(activity.fee, testFee, "Retrieved fee should match inserted fee")
            XCTAssertEqual(activity.feeRate, testFeeRate, "Retrieved fee rate should match inserted fee rate")
        } else {
            XCTFail("Retrieved activity is not of type onchain")
        }
    }
    
    func testActivityTags() throws {
        // Create and insert an activity
        let activity = Activity.lightning(LightningActivity(
            id: "test-tags-1",
            activityType: .lightning,
            txType: .sent,
            status: .succeeded,
            value: 1000,
            fee: 1,
            invoice: "lnbc...",
            message: "Test payment",
            timestamp: Int64(Date().timeIntervalSince1970),
            preimage: nil,
            createdAt: nil,
            updatedAt: nil
        ))
        
        try insertActivity(activity: activity)
        
        // Add tags
        let tags = ["test", "payment"]
        try addTags(activityId: "test-tags-1", tags: tags)
        
        // Retrieve tags
        let retrievedTags = try getTags(activityId: "test-tags-1")
        XCTAssertEqual(Set(retrievedTags), Set(tags))
        
        // Remove a tag
        try removeTags(activityId: "test-tags-1", tags: ["test"])
        let updatedTags = try getTags(activityId: "test-tags-1")
        XCTAssertEqual(updatedTags, ["payment"])
    }
    
    func testGetActivitiesByTag() throws {
        // Create and insert multiple activities with tags
        let activities = [
            Activity.lightning(LightningActivity(
                id: "test-tag-filter-1",
                activityType: .lightning,
                txType: .sent,
                status: .succeeded,
                value: 1000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment 1",
                timestamp: Int64(Date().timeIntervalSince1970),
                preimage: nil,
                createdAt: nil,
                updatedAt: nil
            )),
            Activity.lightning(LightningActivity(
                id: "test-tag-filter-2",
                activityType: .lightning,
                txType: .sent,
                status: .succeeded,
                value: 2000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment 2",
                timestamp: Int64(Date().timeIntervalSince1970),
                preimage: nil,
                createdAt: nil,
                updatedAt: nil
            ))
        ]
        
        // Insert activities and add tags
        for activity in activities {
            try insertActivity(activity: activity)
            if case let .lightning(lightning) = activity {
                try addTags(activityId: lightning.id, tags: ["test-tag"])
            }
        }
        
        // Add an additional tag to one activity
        try addTags(activityId: "test-tag-filter-1", tags: ["special"])
        
        // Test filtering by tag
        let testTagActivities = try getActivitiesByTag(tag: "test-tag", limit: nil)
        XCTAssertEqual(testTagActivities.count, 2)
        
        let specialTagActivities = try getActivitiesByTag(tag: "special", limit: nil)
        XCTAssertEqual(specialTagActivities.count, 1)
    }
    
    func testUpdateActivity() throws {
        // Create and insert an activity
        let initialActivity = Activity.lightning(LightningActivity(
            id: "test-update-1",
            activityType: .lightning,
            txType: .sent,
            status: .pending,
            value: 1000,
            fee: 1,
            invoice: "lnbc...",
            message: "Test payment",
            timestamp: Int64(Date().timeIntervalSince1970),
            preimage: nil,
            createdAt: nil,
            updatedAt: nil
        ))
        
        try insertActivity(activity: initialActivity)
        
        // Create updated version
        let updatedActivity = Activity.lightning(LightningActivity(
            id: "test-update-1",
            activityType: .lightning,
            txType: .sent,
            status: .succeeded,
            value: 1000,
            fee: 1,
            invoice: "lnbc...",
            message: "Updated test payment",
            timestamp: Int64(Date().timeIntervalSince1970),
            preimage: "preimage123",
            createdAt: nil,
            updatedAt: nil
        ))
        
        // Update the activity
        try updateActivity(activityId: "test-update-1", activity: updatedActivity)
        
        // Verify the update
        let retrieved = try getActivityById(activityId: "test-update-1")
        XCTAssertNotNil(retrieved)
        
        if case let .lightning(activity) = retrieved {
            XCTAssertEqual(activity.status, .succeeded)
            XCTAssertEqual(activity.message, "Updated test payment")
            XCTAssertEqual(activity.preimage, "preimage123")
        } else {
            XCTFail("Retrieved activity is not of type lightning")
        }
    }
    
    func testDeleteActivity() throws {
        // Create and insert an activity
        let activity = Activity.lightning(LightningActivity(
            id: "test-delete-1",
            activityType: .lightning,
            txType: .sent,
            status: .succeeded,
            value: 1000,
            fee: 1,
            invoice: "lnbc...",
            message: "Test payment",
            timestamp: Int64(Date().timeIntervalSince1970),
            preimage: nil,
            createdAt: nil,
            updatedAt: nil
        ))
        
        try insertActivity(activity: activity)
        
        // Verify activity exists
        XCTAssertNotNil(try getActivityById(activityId: "test-delete-1"))
        
        // Delete the activity
        let deleted = try deleteActivityById(activityId: "test-delete-1")
        XCTAssertTrue(deleted)
        
        // Verify activity no longer exists
        XCTAssertNil(try getActivityById(activityId: "test-delete-1"))
    }
    
    func testGetAllActivitiesWithLimit() throws {
        // Create multiple activities
        let activities = [
            Activity.lightning(LightningActivity(
                id: "test-limit-1",
                activityType: .lightning,
                txType: .sent,
                status: .succeeded,
                value: 1000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment 1",
                timestamp: Int64(Date().timeIntervalSince1970),
                preimage: nil,
                createdAt: nil,
                updatedAt: nil
            )),
            Activity.onchain(OnchainActivity(
                id: "test-limit-2",
                activityType: .onchain,
                txType: .received,
                txId: "abc123",
                value: 5000,
                fee: 500,
                feeRate: 1,
                address: "bc1...",
                confirmed: true,
                timestamp: Int64(Date().timeIntervalSince1970),
                isBoosted: false,
                isTransfer: false,
                doesExist: true,
                confirmTimestamp: nil,
                channelId: nil,
                transferTxId: nil,
                createdAt: nil,
                updatedAt: nil
            )),
            Activity.lightning(LightningActivity(
                id: "test-limit-3",
                activityType: .lightning,
                txType: .received,
                status: .succeeded,
                value: 2000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment 3",
                timestamp: Int64(Date().timeIntervalSince1970),
                preimage: nil,
                createdAt: nil,
                updatedAt: nil
            ))
        ]
        
        // Insert all activities
        for activity in activities {
            try insertActivity(activity: activity)
        }
        
        // Test with limit
        let limitedActivities = try getAllActivities(limit: 2)
        XCTAssertEqual(limitedActivities.count, 2)
        
        // Test without limit
        let allActivities = try getAllActivities(limit: nil)
        XCTAssertEqual(allActivities.count, 3)
    }
    
    func testGetAllOnchainAndLightningActivitiesWithLimit() throws {
        // Create multiple activities of each type
        let lightningActivities = [
            Activity.lightning(LightningActivity(
                id: "test-lightning-limit-1",
                activityType: .lightning,
                txType: .sent,
                status: .succeeded,
                value: 1000,
                fee: 1,
                invoice: "lnbc...",
                message: "Lightning 1",
                timestamp: Int64(Date().timeIntervalSince1970),
                preimage: nil,
                createdAt: nil,
                updatedAt: nil
            )),
            Activity.lightning(LightningActivity(
                id: "test-lightning-limit-2",
                activityType: .lightning,
                txType: .received,
                status: .succeeded,
                value: 2000,
                fee: 1,
                invoice: "lnbc...",
                message: "Lightning 2",
                timestamp: Int64(Date().timeIntervalSince1970),
                preimage: nil,
                createdAt: nil,
                updatedAt: nil
            ))
        ]
        
        let onchainActivities = [
            Activity.onchain(OnchainActivity(
                id: "test-onchain-limit-1",
                activityType: .onchain,
                txType: .sent,
                txId: "abc123",
                value: 5000,
                fee: 500,
                feeRate: 1,
                address: "bc1...",
                confirmed: true,
                timestamp: Int64(Date().timeIntervalSince1970),
                isBoosted: false,
                isTransfer: false,
                doesExist: true,
                confirmTimestamp: nil,
                channelId: nil,
                transferTxId: nil,
                createdAt: nil,
                updatedAt: nil
            )),
            Activity.onchain(OnchainActivity(
                id: "test-onchain-limit-2",
                activityType: .onchain,
                txType: .received,
                txId: "def456",
                value: 6000,
                fee: 600,
                feeRate: 1,
                address: "bc1...",
                confirmed: true,
                timestamp: Int64(Date().timeIntervalSince1970),
                isBoosted: false,
                isTransfer: false,
                doesExist: true,
                confirmTimestamp: nil,
                channelId: nil,
                transferTxId: nil,
                createdAt: nil,
                updatedAt: nil
            ))
        ]
        
        // Insert all activities
        for activity in lightningActivities + onchainActivities {
            try insertActivity(activity: activity)
        }
        
        // Test lightning activities with limit
        let limitedLightning = try getAllLightningActivities(limit: 1)
        XCTAssertEqual(limitedLightning.count, 1)
        
        // Test lightning activities without limit
        let allLightning = try getAllLightningActivities(limit: nil)
        XCTAssertEqual(allLightning.count, 2)
        
        // Test onchain activities with limit
        let limitedOnchain = try getAllOnchainActivities(limit: 1)
        XCTAssertEqual(limitedOnchain.count, 1)
        
        // Test onchain activities without limit
        let allOnchain = try getAllOnchainActivities(limit: nil)
        XCTAssertEqual(allOnchain.count, 2)
    }
}
