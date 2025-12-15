//
//  ContactsViewModel.swift
//  Bitkit
//
//  ViewModel for Contacts management
//

import Foundation
import SwiftUI

@MainActor
class ContactsViewModel: ObservableObject {
    @Published var contacts: [Contact] = []
    @Published var searchQuery: String = ""
    @Published var isLoading = false
    @Published var showingAddContact = false
    @Published var showingDiscovery = false
    @Published var discoveredContacts: [Contact] = []
    @Published var showingDiscoveryResults = false
    
    private let contactStorage: ContactStorage
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.contactStorage = ContactStorage(identityName: identityName)
    }
    
    func loadContacts() {
        isLoading = true
        contacts = contactStorage.listContacts()
        isLoading = false
    }
    
    func searchContacts() {
        if searchQuery.isEmpty {
            contacts = contactStorage.listContacts()
        } else {
            contacts = contactStorage.searchContacts(query: searchQuery)
        }
    }
    
    func addContact(_ contact: Contact) throws {
        try contactStorage.saveContact(contact)
        loadContacts()
    }
    
    func updateContact(_ contact: Contact) throws {
        try contactStorage.saveContact(contact)
        loadContacts()
    }
    
    func deleteContact(_ contact: Contact) throws {
        try contactStorage.deleteContact(id: contact.id)
        loadContacts()
    }
    
    func discoverContacts(directoryService: DirectoryService) async {
        isLoading = true
        defer { isLoading = false }
        
        // In production, would fetch from directory
        // For now, return empty
        discoveredContacts = []
        showingDiscoveryResults = true
    }
    
    func importDiscovered(_ contacts: [Contact]) {
        do {
            try contactStorage.importContacts(contacts)
            loadContacts()
        } catch {
            Logger.error("Failed to import contacts: \(error)", context: "ContactsViewModel")
        }
    }
}

