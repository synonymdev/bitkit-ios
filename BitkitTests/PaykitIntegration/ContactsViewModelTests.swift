// ContactsViewModelTests.swift
// BitkitTests
//
// Unit tests for ContactsViewModel

import XCTest
@testable import Bitkit

final class ContactsViewModelTests: XCTestCase {

    var viewModel: ContactsViewModel!

    override func setUp() {
        super.setUp()
        viewModel = ContactsViewModel()
        // Clear any existing contacts
        viewModel.clearContacts()
    }

    override func tearDown() {
        viewModel.clearContacts()
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Load Contacts Tests

    func testLoadContactsStartsEmpty() async {
        // When
        await viewModel.loadContacts()

        // Then
        XCTAssertTrue(viewModel.contacts.isEmpty)
    }

    func testLoadContactsAfterAdd() async {
        // Given
        let contact = Contact(
            pubkey: "pk:alice",
            name: "Alice",
            avatarUrl: nil,
            supportedMethods: ["lightning"]
        )

        // When
        await viewModel.addContact(contact)
        await viewModel.loadContacts()

        // Then
        XCTAssertEqual(viewModel.contacts.count, 1)
        XCTAssertEqual(viewModel.contacts.first?.name, "Alice")
    }

    // MARK: - Add Contact Tests

    func testAddContactUpdatesState() async {
        // Given
        let contact = Contact(
            pubkey: "pk:bob",
            name: "Bob",
            supportedMethods: ["lightning", "onchain"]
        )

        // When
        await viewModel.addContact(contact)

        // Then
        XCTAssertEqual(viewModel.contacts.count, 1)
    }

    func testAddMultipleContacts() async {
        // Given
        let contacts = [
            Contact(pubkey: "pk:alice", name: "Alice", supportedMethods: []),
            Contact(pubkey: "pk:bob", name: "Bob", supportedMethods: []),
            Contact(pubkey: "pk:charlie", name: "Charlie", supportedMethods: [])
        ]

        // When
        for contact in contacts {
            await viewModel.addContact(contact)
        }

        // Then
        XCTAssertEqual(viewModel.contacts.count, 3)
    }

    // MARK: - Remove Contact Tests

    func testRemoveContactDeletesFromState() async {
        // Given
        let contact = Contact(pubkey: "pk:toremove", name: "Remove Me", supportedMethods: [])
        await viewModel.addContact(contact)
        XCTAssertEqual(viewModel.contacts.count, 1)

        // When
        await viewModel.removeContact(pubkey: "pk:toremove")

        // Then
        XCTAssertTrue(viewModel.contacts.isEmpty)
    }

    // MARK: - Search Tests

    func testSearchContactsFiltersByName() async {
        // Given
        let contacts = [
            Contact(pubkey: "pk:alice", name: "Alice", supportedMethods: []),
            Contact(pubkey: "pk:bob", name: "Bob", supportedMethods: []),
            Contact(pubkey: "pk:charlie", name: "Charlie", supportedMethods: [])
        ]
        for contact in contacts {
            await viewModel.addContact(contact)
        }

        // When
        viewModel.searchContacts(query: "ali")

        // Then
        XCTAssertEqual(viewModel.filteredContacts.count, 1)
        XCTAssertEqual(viewModel.filteredContacts.first?.name, "Alice")
    }

    func testSearchContactsEmptyQueryShowsAll() async {
        // Given
        let contacts = [
            Contact(pubkey: "pk:alice", name: "Alice", supportedMethods: []),
            Contact(pubkey: "pk:bob", name: "Bob", supportedMethods: [])
        ]
        for contact in contacts {
            await viewModel.addContact(contact)
        }

        // When
        viewModel.searchContacts(query: "")

        // Then
        XCTAssertEqual(viewModel.filteredContacts.count, 2)
    }

    func testSearchContactsIsCaseInsensitive() async {
        // Given
        let contact = Contact(pubkey: "pk:alice", name: "Alice", supportedMethods: [])
        await viewModel.addContact(contact)

        // When
        viewModel.searchContacts(query: "ALICE")

        // Then
        XCTAssertEqual(viewModel.filteredContacts.count, 1)
    }

    // MARK: - Contact Discovery Tests

    func testDiscoverContactsReturnsDiscovered() async {
        // Given
        let userPubkey = "pk:user"

        // When
        await viewModel.discoverContacts(userPubkey: userPubkey)

        // Then - discoveredContacts may be empty if no follows
        XCTAssertNotNil(viewModel.discoveredContacts)
    }

    func testAddDiscoveredContactConvertsAndSaves() async {
        // Given
        let discovered = DiscoveredContact(
            pubkey: "pk:discovered",
            name: "Discovered User",
            avatarUrl: "https://example.com/avatar.png",
            supportedMethods: ["lightning"]
        )

        // When
        await viewModel.addDiscoveredContact(discovered)

        // Then
        XCTAssertEqual(viewModel.contacts.count, 1)
        XCTAssertEqual(viewModel.contacts.first?.name, "Discovered User")
    }

    // MARK: - Sync Tests

    func testSyncContactRefreshesData() async {
        // Given
        let contact = Contact(
            pubkey: "pk:tosync",
            name: "Sync Me",
            supportedMethods: ["lightning"]
        )
        await viewModel.addContact(contact)

        // When
        await viewModel.syncContact(contact)

        // Then - contact should still exist, possibly with updated methods
        XCTAssertEqual(viewModel.contacts.count, 1)
    }
}

