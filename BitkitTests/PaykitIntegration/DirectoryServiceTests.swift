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

    func testDiscoverPaymentMethodsThrowsWhenNotConfigured() async throws {
        // Given - directory service without PaykitClient configured
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            _ = try await unconfiguredService.discoverPaymentMethods(for: "pk:unknown123")
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }

    func testDiscoverNoiseEndpointReturnsNilWhenNotConfigured() async throws {
        // Given - directory service without PaykitClient configured
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            _ = try await unconfiguredService.discoverNoiseEndpoint(for: "pk:unknown456")
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }

    // MARK: - Endpoint Publishing Tests

    func testPublishNoiseEndpointThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated transport
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.publishNoiseEndpoint(
                host: "localhost",
                port: 8080,
                noisePubkey: "pk:test123"
            )
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }

    func testRemoveNoiseEndpointThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated transport
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.removeNoiseEndpoint()
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }

    // MARK: - Payment Method Publishing Tests
    
    func testPublishPaymentMethodThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated transport
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.publishPaymentMethod(
                methodId: "lightning",
                endpoint: "lnurl1dp68gurn8ghj7um9..."
            )
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }
    
    func testRemovePaymentMethodThrowsWhenNotConfigured() async throws {
        // Given - directory service without authenticated transport
        let unconfiguredService = DirectoryService()
        
        // When/Then - should throw notConfigured error
        do {
            try await unconfiguredService.removePaymentMethod(methodId: "lightning")
            XCTFail("Expected error to be thrown")
        } catch let error as DirectoryError {
            if case .notConfigured = error {
                // Expected
            } else {
                XCTFail("Expected notConfigured error")
            }
        }
    }

    // MARK: - Directory Error Tests

    func testDirectoryErrorDescriptions() {
        let notConfigured = DirectoryError.notConfigured
        XCTAssertNotNil(notConfigured.errorDescription)
        XCTAssertTrue(notConfigured.errorDescription!.contains("not configured"))
        
        let networkError = DirectoryError.networkError("timeout")
        XCTAssertTrue(networkError.errorDescription!.contains("Network error"))
        
        let parseError = DirectoryError.parseError("invalid json")
        XCTAssertTrue(parseError.errorDescription!.contains("Parse error"))
        
        let notFound = DirectoryError.notFound("endpoint")
        XCTAssertTrue(notFound.errorDescription!.contains("Not found"))
        
        let publishFailed = DirectoryError.publishFailed("server error")
        XCTAssertTrue(publishFailed.errorDescription!.contains("Publish failed"))
    }
    
    // MARK: - DirectoryDiscoveredContact Tests
    
    func testDirectoryDiscoveredContactIdentifiable() {
        let contact = DirectoryDiscoveredContact(
            pubkey: "pk:abc123",
            name: "Alice",
            hasPaymentMethods: true,
            supportedMethods: ["lightning", "onchain"]
        )
        
        XCTAssertEqual(contact.id, "pk:abc123")
        XCTAssertEqual(contact.pubkey, "pk:abc123")
        XCTAssertEqual(contact.name, "Alice")
        XCTAssertTrue(contact.hasPaymentMethods)
        XCTAssertEqual(contact.supportedMethods.count, 2)
    }
    
    func testDirectoryDiscoveredContactWithNilName() {
        let contact = DirectoryDiscoveredContact(
            pubkey: "pk:xyz789",
            name: nil,
            hasPaymentMethods: false,
            supportedMethods: []
        )
        
        XCTAssertNil(contact.name)
        XCTAssertFalse(contact.hasPaymentMethods)
        XCTAssertTrue(contact.supportedMethods.isEmpty)
    }
}
