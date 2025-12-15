// ContactsViewModelTests.swift
// BitkitTests
//
// Unit tests for ContactsViewModel

import XCTest
@testable import Bitkit

@MainActor
final class ContactsViewModelTests: XCTestCase {

    var viewModel: ContactsViewModel!

    override func setUp() {
        super.setUp()
        viewModel = ContactsViewModel(identityName: "test_\(UUID().uuidString)")
    }

    override func tearDown() {
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Load Contacts Tests

    func testLoadContactsStartsEmpty() {
        // When
        viewModel.loadContacts()

        // Then
        XCTAssertTrue(viewModel.contacts.isEmpty)
    }

    func testLoadContactsAfterAdd() throws {
        // Given
        let contact = Contact(
            publicKeyZ32: "pk:alice123",
            name: "Alice"
        )

        // When
        try viewModel.addContact(contact)
        viewModel.loadContacts()

        // Then
        XCTAssertEqual(viewModel.contacts.count, 1)
        XCTAssertEqual(viewModel.contacts.first?.name, "Alice")
    }

    // MARK: - Add Contact Tests

    func testAddContactUpdatesState() throws {
        // Given
        let contact = Contact(
            publicKeyZ32: "pk:bob456",
            name: "Bob"
        )

        // When
        try viewModel.addContact(contact)

        // Then
        XCTAssertEqual(viewModel.contacts.count, 1)
    }

    func testAddMultipleContacts() throws {
        // Given
        let contacts = [
            Contact(publicKeyZ32: "pk:alice", name: "Alice"),
            Contact(publicKeyZ32: "pk:bob", name: "Bob"),
            Contact(publicKeyZ32: "pk:charlie", name: "Charlie")
        ]

        // When
        for contact in contacts {
            try viewModel.addContact(contact)
        }

        // Then
        XCTAssertEqual(viewModel.contacts.count, 3)
    }

    // MARK: - Delete Contact Tests

    func testDeleteContactRemovesFromState() throws {
        // Given
        let contact = Contact(publicKeyZ32: "pk:toremove", name: "Remove Me")
        try viewModel.addContact(contact)
        XCTAssertEqual(viewModel.contacts.count, 1)

        // When
        try viewModel.deleteContact(contact)

        // Then
        XCTAssertTrue(viewModel.contacts.isEmpty)
    }

    // MARK: - Search Tests

    func testSearchContactsFiltersByName() throws {
        // Given
        let contacts = [
            Contact(publicKeyZ32: "pk:alice", name: "Alice"),
            Contact(publicKeyZ32: "pk:bob", name: "Bob"),
            Contact(publicKeyZ32: "pk:charlie", name: "Charlie")
        ]
        for contact in contacts {
            try viewModel.addContact(contact)
        }

        // When
        viewModel.searchQuery = "ali"
        viewModel.searchContacts()

        // Then
        XCTAssertEqual(viewModel.contacts.count, 1)
        XCTAssertEqual(viewModel.contacts.first?.name, "Alice")
    }

    func testSearchContactsEmptyQueryShowsAll() throws {
        // Given
        let contacts = [
            Contact(publicKeyZ32: "pk:alice", name: "Alice"),
            Contact(publicKeyZ32: "pk:bob", name: "Bob")
        ]
        for contact in contacts {
            try viewModel.addContact(contact)
        }

        // When
        viewModel.searchQuery = ""
        viewModel.searchContacts()

        // Then
        XCTAssertEqual(viewModel.contacts.count, 2)
    }

    func testSearchContactsIsCaseInsensitive() throws {
        // Given
        let contact = Contact(publicKeyZ32: "pk:alice", name: "Alice")
        try viewModel.addContact(contact)

        // When
        viewModel.searchQuery = "ALICE"
        viewModel.searchContacts()

        // Then
        XCTAssertEqual(viewModel.contacts.count, 1)
    }

    // MARK: - Contact Discovery Tests

    func testDiscoverContactsSetsLoadingState() async {
        // Given
        let directoryService = DirectoryService.shared
        XCTAssertFalse(viewModel.isLoading)

        // When
        await viewModel.discoverContacts(directoryService: directoryService)

        // Then - discoveredContacts may be empty but loading should complete
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.showingDiscoveryResults)
    }

    // MARK: - Import Discovered Tests

    func testImportDiscoveredSavesContacts() throws {
        // Given
        let discovered = [
            Contact(publicKeyZ32: "pk:discovered1", name: "Discovered 1"),
            Contact(publicKeyZ32: "pk:discovered2", name: "Discovered 2")
        ]

        // When
        viewModel.importDiscovered(discovered)

        // Then
        XCTAssertEqual(viewModel.contacts.count, 2)
    }

    // MARK: - Update Contact Tests

    func testUpdateContactModifiesExisting() throws {
        // Given
        let contact = Contact(publicKeyZ32: "pk:alice", name: "Alice")
        try viewModel.addContact(contact)

        // When
        var updatedContact = contact
        updatedContact.name = "Alice Updated"
        updatedContact.notes = "Some notes"
        try viewModel.updateContact(updatedContact)

        // Then
        XCTAssertEqual(viewModel.contacts.count, 1)
        XCTAssertEqual(viewModel.contacts.first?.name, "Alice Updated")
    }
}
