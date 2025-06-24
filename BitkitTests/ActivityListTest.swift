//
//  ActivityListTest.swift
//  BitkitTests
//
//  Created by Jason van den Berg on 2024/12/17.
//

import XCTest
import BitkitCore

@testable import Bitkit

final class ActivityTests: XCTestCase {
    let testDbPath = NSTemporaryDirectory()
    let service = CoreService.shared.activity

    override func setUp() async throws {
        try await super.setUp()
        // Initialize the database before each test
        _ = try initDb(basePath: testDbPath)
        try await Task.sleep(nanoseconds: 1_000_000_000)
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

    func testInsertAndRetrieveLightningActivity() async throws {
        let testValue: UInt64 = 123_456_789
        let testFee: UInt64 = 421
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create a lightning activity
        let lightningActivity = Activity.lightning(
            LightningActivity(
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
        try await service.insert(lightningActivity)

        // Retrieve the activity
        let retrieved = try await service.getActivity(id: "test-lightning-1")
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

    func testInsertAndRetrieveOnchainActivity() async throws {
        let testValue: UInt64 = 987_654_321
        let testFee: UInt64 = 1234
        let testFeeRate: UInt64 = 8
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create an onchain activity
        let onchainActivity = Activity.onchain(
            OnchainActivity(
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
        try await service.insert(onchainActivity)

        // Retrieve the activity
        let retrieved = try await service.getActivity(id: "test-onchain-1")
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

    func testActivityTags() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create and insert an activity
        let activity = Activity.lightning(
            LightningActivity(
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

        try await service.insert(activity)

        // Add tags
        let tags = ["test", "payment"]
        try await service.appendTag(toActivity: "test-tags-1", tags)

        // Retrieve tags
        let retrievedTags = try await service.tags(forActivity: "test-tags-1")
        XCTAssertEqual(Set(retrievedTags), Set(tags))

        // Remove a tag
        try await service.dropTags(fromActivity: "test-tags-1", ["test"])
        let updatedTags = try await service.tags(forActivity: "test-tags-1")
        XCTAssertEqual(updatedTags, ["payment"])
    }

    func testGetActivitiesByTag() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create and insert multiple activities with tags
        let activities = [
            Activity.lightning(
                LightningActivity(
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
            Activity.lightning(
                LightningActivity(
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
                )),
        ]

        // Insert activities and add tags
        for activity in activities {
            try await service.insert(activity)
            if case let .lightning(lightning) = activity {
                try await service.appendTag(toActivity: lightning.id, ["test-tag"])
            }
        }

        // Add an additional tag to one activity
        try await service.appendTag(toActivity: "test-tag-filter-1", ["special"])

        // Test filtering by tag
        let testTagActivities = try await service.get(tags: ["test-tag"], sortDirection: .desc)
        XCTAssertEqual(testTagActivities.count, 2)

        let specialTagActivities = try await service.get(tags: ["special"])
        XCTAssertEqual(specialTagActivities.count, 1)
    }

    func testGetAllUniqueTags() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create test activities with different tags
        let activities = [
            Activity.lightning(
                LightningActivity(
                    id: "test-unique-tags-1",
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
            Activity.onchain(
                OnchainActivity(
                    id: "test-unique-tags-2",
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
        ]

        // Insert activities and add different combinations of tags
        for activity in activities {
            try await service.insert(activity)
        }

        // Add tags to first activity
        try await service.appendTag(toActivity: "test-unique-tags-1", ["payment", "important", "personal"])

        // Add tags to second activity
        try await service.appendTag(toActivity: "test-unique-tags-2", ["payment", "business", "onchain"])

        // Get all unique tags
        let uniqueTags = try await service.allPossibleTags()

        // Verify the results
        XCTAssertEqual(Set(uniqueTags), Set(["payment", "important", "personal", "business", "onchain"]))
        XCTAssertEqual(uniqueTags.count, 5)

        // Add duplicate tags to verify they don't create duplicates in unique tags
        try await service.appendTag(toActivity: "test-unique-tags-1", ["payment", "business"])
        let uniqueTagsAfterDuplicates = try await service.allPossibleTags()
        XCTAssertEqual(Set(uniqueTagsAfterDuplicates), Set(["payment", "important", "personal", "business", "onchain"]))
        XCTAssertEqual(uniqueTagsAfterDuplicates.count, 5)

        // Remove some tags and verify the list updates
        try await service.dropTags(fromActivity: "test-unique-tags-1", ["important", "personal"])
        try await service.dropTags(fromActivity: "test-unique-tags-2", ["onchain"])

        let uniqueTagsAfterRemoval = try await service.allPossibleTags()
        XCTAssertEqual(Set(uniqueTagsAfterRemoval), Set(["payment", "business"]))
        XCTAssertEqual(uniqueTagsAfterRemoval.count, 2)
    }

    func testUpdateActivity() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create and insert an activity
        let initialActivity = Activity.lightning(
            LightningActivity(
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

        try await service.insert(initialActivity)

        // Create updated version
        let updatedActivity = Activity.lightning(
            LightningActivity(
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
        try await service.update(id: "test-update-1", activity: updatedActivity)

        // Verify the update
        let retrieved = try await service.getActivity(id: "test-update-1")
        XCTAssertNotNil(retrieved)

        if case let .lightning(activity) = retrieved {
            XCTAssertEqual(activity.status, .succeeded)
            XCTAssertEqual(activity.message, "Updated test payment")
            XCTAssertEqual(activity.preimage, "preimage123")
        } else {
            XCTFail("Retrieved activity is not of type lightning")
        }
    }

    func testDeleteActivity() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create and insert an activity
        let activity = Activity.lightning(
            LightningActivity(
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

        try await service.insert(activity)

        // Verify activity exists
        let activity1 = try await service.getActivity(id: "test-delete-1")
        XCTAssertNotNil(activity1)

        // Delete the activity
        let deleted = try await service.delete(id: "test-delete-1")
        XCTAssertTrue(deleted)

        // Verify activity no longer exists
        let deletedActivity = try await service.getActivity(id: "test-delete-1")
        XCTAssertNil(deletedActivity)
    }

    func testGetAllActivitiesWithLimit() async throws {
        let timestamp = UInt64(Date().timeIntervalSince1970)

        // Create multiple activities
        let activities = [
            Activity.lightning(
                LightningActivity(
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
            Activity.onchain(
                OnchainActivity(
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
            Activity.lightning(
                LightningActivity(
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
                )),
        ]

        // Insert all activities
        for activity in activities {
            try await service.insert(activity)
        }

        // Test with limit
        let limitedActivities = try await service.get(filter: .all, limit: 2)
        XCTAssertEqual(limitedActivities.count, 2)

        // Test without limit
        let allActivities = try await service.get(filter: .all)
        XCTAssertEqual(allActivities.count, 3)
    }
}
