// DirectoryServiceTests.swift
// BitkitTests
//
// Unit tests for DirectoryService

import XCTest
@testable import Bitkit

final class DirectoryServiceTests: XCTestCase {

    var directoryService: DirectoryService!

    override func setUp() {
        super.setUp()
        directoryService = DirectoryService.shared
    }

    override func tearDown() {
        directoryService = nil
        super.tearDown()
    }

    // MARK: - Payment Method Discovery Tests

    func testDiscoverPaymentMethodsReturnsEmptyForUnknown() async throws {
        // Given
        let unknownPubkey = "pk:unknown123"

        // When
        let methods = try await directoryService.discoverPaymentMethods(for: unknownPubkey)

        // Then
        XCTAssertTrue(methods.isEmpty)
    }

    func testDiscoverNoiseEndpointReturnsNilForUnknown() async throws {
        // Given
        let unknownRecipient = "pk:unknown456"

        // When
        let endpoint = try await directoryService.discoverNoiseEndpoint(for: unknownRecipient)

        // Then
        XCTAssertNil(endpoint)
    }

    // MARK: - Endpoint Publishing Tests

    func testPublishNoiseEndpointDoesNotThrow() async throws {
        // Given
        let methodId = "lightning"
        let endpoint = "lnurl1dp68gurn8ghj7um9..."

        // When/Then - should not throw
        try await directoryService.publishNoiseEndpoint(methodId: methodId, endpoint: endpoint)
    }

    func testRemoveNoiseEndpointDoesNotThrow() async throws {
        // Given
        let methodId = "lightning"

        // When/Then - should not throw
        try await directoryService.removeNoiseEndpoint(methodId: methodId)
    }

    // MARK: - Contact Discovery Tests

    func testDiscoverContactsFromFollowsReturnsEmptyWhenNoFollows() async throws {
        // Given
        let userPubkey = "pk:user123"

        // When
        let contacts = try await directoryService.discoverContactsFromFollows(userPubkey: userPubkey)

        // Then
        XCTAssertTrue(contacts.isEmpty)
    }

    // MARK: - Supported Methods Tests

    func testGetSupportedMethodsReturnsArray() async throws {
        // Given
        let pubkey = "pk:test123"

        // When
        let methods = try await directoryService.getSupportedMethods(for: pubkey)

        // Then
        XCTAssertNotNil(methods)
    }
}

