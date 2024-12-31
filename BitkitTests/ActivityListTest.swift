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
        let testValue: UInt64 = 123456789
        let testFee: UInt64 = 421
        let timestamp = UInt64(Date().timeIntervalSince1970)
        
        // Create a lightning activity
        let lightningActivity = Activity.lightning(LightningActivity(
            id: "test-lightning-1",
            txType: .sent,
            status: .succeeded,
            value: testValue,
            fee: testFee,
            invoice: "lnbc...",
            message: "Test payment",
            timestamp: timestamp,
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
        let testValue: UInt64 = 987654321
        let testFee: UInt64 = 1234
        let testFeeRate: UInt64 = 8
        let timestamp = UInt64(Date().timeIntervalSince1970)
        
        // Create an onchain activity
        let onchainActivity = Activity.onchain(OnchainActivity(
            id: "test-onchain-1",
            txType: .received,
            txId: "abc123",
            value: testValue,
            fee: testFee,
            feeRate: testFeeRate,
            address: "bc1...",
            confirmed: true,
            timestamp: timestamp,
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
        let timestamp = UInt64(Date().timeIntervalSince1970)
        
        // Create and insert an activity
        let activity = Activity.lightning(LightningActivity(
            id: "test-tags-1",
            txType: .sent,
            status: .succeeded,
            value: 1000,
            fee: 1,
            invoice: "lnbc...",
            message: "Test payment",
            timestamp: timestamp,
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
        let timestamp = UInt64(Date().timeIntervalSince1970)
        
        // Create and insert multiple activities with tags
        let activities = [
            Activity.lightning(LightningActivity(
                id: "test-tag-filter-1",
                txType: .sent,
                status: .succeeded,
                value: 1000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment 1",
                timestamp: timestamp,
                preimage: nil,
                createdAt: nil,
                updatedAt: nil
            )),
            Activity.lightning(LightningActivity(
                id: "test-tag-filter-2",
                txType: .sent,
                status: .succeeded,
                value: 2000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment 2",
                timestamp: timestamp,
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
        let testTagActivities = try getActivitiesByTag(tag: "test-tag", limit: nil, sortDirection: .desc)
        XCTAssertEqual(testTagActivities.count, 2)
        
        let specialTagActivities = try getActivitiesByTag(tag: "special", limit: nil, sortDirection: .desc)
        XCTAssertEqual(specialTagActivities.count, 1)
    }
    
    func testUpdateActivity() throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)
        
        // Create and insert an activity
        let initialActivity = Activity.lightning(LightningActivity(
            id: "test-update-1",
            txType: .sent,
            status: .pending,
            value: 1000,
            fee: 1,
            invoice: "lnbc...",
            message: "Test payment",
            timestamp: timestamp,
            preimage: nil,
            createdAt: nil,
            updatedAt: nil
        ))
        
        try insertActivity(activity: initialActivity)
        
        // Create updated version
        let updatedActivity = Activity.lightning(LightningActivity(
            id: "test-update-1",
            txType: .sent,
            status: .succeeded,
            value: 1000,
            fee: 1,
            invoice: "lnbc...",
            message: "Updated test payment",
            timestamp: timestamp,
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
        let timestamp = UInt64(Date().timeIntervalSince1970)
        
        // Create and insert an activity
        let activity = Activity.lightning(LightningActivity(
            id: "test-delete-1",
            txType: .sent,
            status: .succeeded,
            value: 1000,
            fee: 1,
            invoice: "lnbc...",
            message: "Test payment",
            timestamp: timestamp,
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
        let timestamp = UInt64(Date().timeIntervalSince1970)
        
        // Create multiple activities
        let activities = [
            Activity.lightning(LightningActivity(
                id: "test-limit-1",
                txType: .sent,
                status: .succeeded,
                value: 1000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment 1",
                timestamp: timestamp,
                preimage: nil,
                createdAt: nil,
                updatedAt: nil
            )),
            Activity.onchain(OnchainActivity(
                id: "test-limit-2",
                txType: .received,
                txId: "abc123",
                value: 5000,
                fee: 500,
                feeRate: 1,
                address: "bc1...",
                confirmed: true,
                timestamp: timestamp,
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
                txType: .received,
                status: .succeeded,
                value: 2000,
                fee: 1,
                invoice: "lnbc...",
                message: "Test payment 3",
                timestamp: timestamp,
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
        let limitedActivities = try getActivities(filter: .all, limit: 2, sortDirection: nil)
        XCTAssertEqual(limitedActivities.count, 2)
        
        // Test without limit
        let allActivities = try getActivities(filter: .all, limit: nil, sortDirection: nil)
        XCTAssertEqual(allActivities.count, 3)
    }
}
