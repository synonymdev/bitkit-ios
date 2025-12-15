//
//  ContactStorage.swift
//  Bitkit
//
//  Persistent storage for contacts using Keychain.
//

import Foundation

/// Manages persistent storage of contacts
public class ContactStorage {
    
    private let keychain: PaykitKeychainStorage
    private let identityName: String
    
    // In-memory cache
    private var contactsCache: [Contact]?
    
    private var contactsKey: String {
        "paykit.contacts.\(identityName)"
    }
    
    public init(identityName: String = "default", keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.identityName = identityName
        self.keychain = keychain
    }
    
    // MARK: - CRUD Operations
    
    /// Get all contacts
    public func listContacts() -> [Contact] {
        if let cached = contactsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: contactsKey) else {
                return []
            }
            let contacts = try JSONDecoder().decode([Contact].self, from: data)
            contactsCache = contacts
            return contacts
        } catch {
            Logger.error("ContactStorage: Failed to load contacts: \(error)", context: "ContactStorage")
            return []
        }
    }
    
    /// Get a specific contact
    public func getContact(id: String) -> Contact? {
        return listContacts().first { $0.id == id }
    }
    
    /// Save a new contact or update existing
    public func saveContact(_ contact: Contact) throws {
        var contacts = listContacts()
        
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            // Update existing
            contacts[index] = contact
        } else {
            // Add new
            contacts.append(contact)
        }
        
        try persistContacts(contacts)
    }
    
    /// Delete a contact
    public func deleteContact(id: String) throws {
        var contacts = listContacts()
        contacts.removeAll { $0.id == id }
        try persistContacts(contacts)
    }
    
    /// Search contacts by name
    public func searchContacts(query: String) -> [Contact] {
        let query = query.lowercased()
        return listContacts().filter { contact in
            contact.name.lowercased().contains(query) ||
            contact.publicKeyZ32.lowercased().contains(query)
        }
    }
    
    /// Record a payment to a contact
    public func recordPayment(contactId: String) throws {
        var contacts = listContacts()
        guard let index = contacts.firstIndex(where: { $0.id == contactId }) else {
            return
        }
        
        contacts[index].recordPayment()
        try persistContacts(contacts)
    }
    
    /// Clear all contacts
    public func clearAll() throws {
        try persistContacts([])
    }
    
    /// Import contacts (merge with existing)
    public func importContacts(_ newContacts: [Contact]) throws {
        var contacts = listContacts()
        
        for newContact in newContacts {
            if !contacts.contains(where: { $0.id == newContact.id }) {
                contacts.append(newContact)
            }
        }
        
        try persistContacts(contacts)
    }
    
    /// Export contacts as JSON string
    public func exportContacts() throws -> String {
        let contacts = listContacts()
        let data = try JSONEncoder().encode(contacts)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
    
    // MARK: - Private
    
    private func persistContacts(_ contacts: [Contact]) throws {
        let data = try JSONEncoder().encode(contacts)
        try keychain.store(key: contactsKey, data: data)
        contactsCache = contacts
    }
}

