import Foundation
import SwiftUI

private let pubkyPrefix = "pubky"

private func ensurePubkyPrefix(_ key: String) -> String {
    key.hasPrefix(pubkyPrefix) ? key : "\(pubkyPrefix)\(key)"
}

private func stripPubkyPrefix(_ key: String) -> String {
    key.hasPrefix(pubkyPrefix) ? String(key.dropFirst(pubkyPrefix.count)) : key
}

// MARK: - PubkyContact

struct PubkyContact: Identifiable, Hashable, Sendable {
    let id: String
    let publicKey: String
    let profile: PubkyProfile

    static func == (lhs: PubkyContact, rhs: PubkyContact) -> Bool {
        lhs.publicKey == rhs.publicKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
    }

    var displayName: String {
        profile.name
    }

    var sortLetter: String {
        let firstChar = displayName.first.map { String($0).uppercased() } ?? "#"
        return firstChar.first?.isLetter == true ? firstChar : "#"
    }

    init(publicKey: String, profile: PubkyProfile) {
        id = publicKey
        self.publicKey = publicKey
        self.profile = profile
    }
}

struct ContactSection: Identifiable {
    let id: String
    let letter: String
    let contacts: [PubkyContact]
}

// MARK: - ContactsManager

@MainActor
class ContactsManager: ObservableObject {
    @Published var contacts: [PubkyContact] = []
    @Published var isLoading = false
    @Published var hasLoaded = false

    /// Temporarily holds contacts discovered during import (e.g., from pubky.app after Ring auth).
    /// Cleared after import is completed or discarded.
    @Published var pendingImportProfile: PubkyProfile?
    @Published var pendingImportContacts: [PubkyContact] = []

    var groupedContacts: [ContactSection] {
        let grouped = Dictionary(grouping: contacts) { $0.sortLetter }
        return grouped.keys.sorted().map { letter in
            ContactSection(id: letter, letter: letter, contacts: grouped[letter] ?? [])
        }
    }

    func reset() {
        contacts = []
        isLoading = false
        hasLoaded = false
    }

    // MARK: - Load Contacts (from bitkit.to homeserver)

    func loadContacts(for publicKey: String) async throws {
        guard !isLoading else {
            Logger.debug("loadContacts skipped — already loading", context: "ContactsManager")
            return
        }

        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        let basePath = contactsBasePath
        Logger.info("Loading contacts from \(basePath) for \(publicKey)", context: "ContactsManager")

        do {
            let sessionSecret = try getSessionSecret()

            let contactPaths: [String]
            do {
                contactPaths = try await Task.detached {
                    try await PubkyService.sessionList(sessionSecret: sessionSecret, dirPath: basePath)
                }.value
            } catch {
                Logger.warn("sessionList failed for \(basePath): \(error)", context: "ContactsManager")
                if !hasLoaded {
                    contacts = []
                }
                return
            }

            Logger.debug("Listed \(contactPaths.count) contacts from homeserver", context: "ContactsManager")

            let strippedKey = stripPubkyPrefix(publicKey)

            let loaded: [PubkyContact] = await withTaskGroup(of: PubkyContact?.self) { group in
                for path in contactPaths {
                    let contactKey = extractPublicKey(from: path)
                    guard !contactKey.isEmpty else { continue }

                    let prefixedKey = ensurePubkyPrefix(contactKey)
                    let uri = "pubky://\(strippedKey)\(basePath)\(prefixedKey)"

                    group.addTask {
                        do {
                            let json = try await PubkyService.fetchFileString(uri: uri)
                            let profileData = try PubkyProfileData.decode(from: json)
                            let profile = profileData.toProfile(publicKey: prefixedKey)
                            return PubkyContact(publicKey: prefixedKey, profile: profile)
                        } catch {
                            Logger.warn("Failed to load contact data for '\(prefixedKey)': \(error)", context: "ContactsManager")
                            return PubkyContact(publicKey: prefixedKey, profile: PubkyProfile.placeholder(publicKey: prefixedKey))
                        }
                    }
                }
                var results: [PubkyContact] = []
                for await contact in group {
                    if let contact { results.append(contact) }
                }
                return results
            }

            contacts = loaded.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            Logger.info("Loaded \(contacts.count) contacts", context: "ContactsManager")
        } catch {
            Logger.error("Failed to load contacts: \(error)", context: "ContactsManager")
            throw error
        }
    }

    // MARK: - Add Contact (fetch from pubky.app once, then store to bitkit.to)

    func addContact(publicKey: String, existingProfile: PubkyProfile? = nil) async throws {
        let prefixedKey = ensurePubkyPrefix(publicKey)

        // Use existing profile if provided (e.g., already fetched during preview), otherwise fetch from pubky.app
        let profile: PubkyProfile = if let existingProfile {
            existingProfile
        } else {
            await fetchProfileFromPubkyApp(publicKey: prefixedKey)
        }

        // Build PubkyProfileData and write to bitkit.to
        let contactData = PubkyProfileData.from(profile: profile)
        try await savePubkyProfileData(publicKey: prefixedKey, data: contactData)

        Logger.info("Added contact \(prefixedKey)", context: "ContactsManager")

        let contact = PubkyContact(publicKey: prefixedKey, profile: profile)
        contacts.append(contact)
        contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Import Contacts (batch fetch from pubky.app, store to bitkit.to)

    func importContacts(publicKeys: [String]) async throws {
        let prefixedKeys = publicKeys.map { ensurePubkyPrefix($0) }

        // Fetch profiles from pubky.app and write each to bitkit.to
        let loaded: [PubkyContact] = await withTaskGroup(of: PubkyContact?.self) { group in
            for key in prefixedKeys {
                group.addTask { [self] in
                    let profile = await fetchProfileFromPubkyApp(publicKey: key)
                    let contactData = PubkyProfileData.from(profile: profile)
                    do {
                        try await savePubkyProfileData(publicKey: key, data: contactData)
                    } catch {
                        Logger.warn("Failed to save imported contact '\(key)': \(error)", context: "ContactsManager")
                    }
                    return PubkyContact(publicKey: key, profile: profile)
                }
            }
            var results: [PubkyContact] = []
            for await contact in group {
                if let contact { results.append(contact) }
            }
            return results
        }

        // Merge with existing contacts, avoiding duplicates
        let existingKeys = Set(contacts.map(\.publicKey))
        let newContacts = loaded.filter { !existingKeys.contains($0.publicKey) }
        contacts.append(contentsOf: newContacts)
        contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        Logger.info("Imported \(newContacts.count) new contacts", context: "ContactsManager")
    }

    // MARK: - Update Contact (edit and save back to bitkit.to)

    func updateContact(publicKey: String, name: String, bio: String, imageUrl: String?, links: [PubkyProfileLink], tags: [String]) async throws {
        let prefixedKey = ensurePubkyPrefix(publicKey)

        let contactData = PubkyProfileData(
            name: name,
            bio: bio,
            image: imageUrl,
            links: links.map { PubkyProfileData.Link(label: $0.label, url: $0.url) },
            tags: tags
        )

        try await savePubkyProfileData(publicKey: prefixedKey, data: contactData)

        // Update local array
        let updatedProfile = contactData.toProfile(publicKey: prefixedKey)
        if let index = contacts.firstIndex(where: { $0.publicKey == prefixedKey }) {
            contacts[index] = PubkyContact(publicKey: prefixedKey, profile: updatedProfile)
            contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        Logger.info("Updated contact \(prefixedKey)", context: "ContactsManager")
    }

    // MARK: - Delete Contact

    func removeContact(publicKey: String) async throws {
        let prefixedKey = ensurePubkyPrefix(publicKey)
        let path = "\(contactsBasePath)\(prefixedKey)"

        let sessionSecret = try getSessionSecret()

        try await Task.detached {
            try await PubkyService.sessionDelete(
                sessionSecret: sessionSecret,
                path: path
            )
        }.value

        Logger.info("Removed contact \(prefixedKey)", context: "ContactsManager")

        contacts.removeAll { $0.publicKey == prefixedKey }
    }

    // MARK: - Discover Remote Contacts (from pubky.app — for Ring auth import flow)

    /// Discover profile and contacts from pubky.app, store as pending imports.
    /// Returns true if any import data was found.
    @discardableResult
    func prepareImport(profile: PubkyProfile?, publicKey: String) async -> Bool {
        pendingImportProfile = profile
        await discoverRemoteContacts(publicKey: publicKey)
        return pendingImportProfile != nil || !pendingImportContacts.isEmpty
    }

    /// Fetch the user's contacts from pubky.app and store as pending imports.
    func discoverRemoteContacts(publicKey: String) async {
        let prefixedKey = ensurePubkyPrefix(publicKey)

        do {
            let contactKeys = try await Task.detached {
                try await PubkyService.getContacts(publicKey: prefixedKey)
            }.value

            Logger.info("Discovered \(contactKeys.count) contacts from pubky.app", context: "ContactsManager")

            let discovered: [PubkyContact] = await withTaskGroup(of: PubkyContact?.self) { group in
                for key in contactKeys {
                    let pk = ensurePubkyPrefix(key)
                    group.addTask { [self] in
                        let profile = await fetchProfileFromPubkyApp(publicKey: pk)
                        return PubkyContact(publicKey: pk, profile: profile)
                    }
                }
                var results: [PubkyContact] = []
                for await contact in group {
                    if let contact { results.append(contact) }
                }
                return results
            }

            pendingImportContacts = discovered.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } catch {
            Logger.warn("Failed to discover remote contacts: \(error)", context: "ContactsManager")
            pendingImportContacts = []
        }
    }

    // MARK: - Fetch Contact Profile (from pubky.app — used only during add/import)

    func fetchContactProfile(publicKey: String) async -> PubkyProfile? {
        await fetchProfileFromPubkyApp(publicKey: ensurePubkyPrefix(publicKey))
    }

    // MARK: - Helpers

    private var contactsBasePath: String {
        switch Env.network {
        case .bitcoin:
            return "/pub/bitkit.to/contacts/"
        default:
            return "/pub/staging.bitkit.to/contacts/"
        }
    }

    private func getSessionSecret() throws -> String {
        guard let sessionSecret = try? Keychain.loadString(key: .paykitSession),
              !sessionSecret.isEmpty
        else {
            throw PubkyServiceError.sessionNotActive
        }
        return sessionSecret
    }

    /// Write PubkyProfileData JSON to homeserver at /pub/bitkit.to/contacts/<pk>
    private func savePubkyProfileData(publicKey: String, data: PubkyProfileData) async throws {
        let path = "\(contactsBasePath)\(publicKey)"
        let sessionSecret = try getSessionSecret()

        let jsonData = try data.encoded()

        try await Task.detached {
            try await PubkyService.sessionPut(
                sessionSecret: sessionSecret,
                path: path,
                content: jsonData
            )
        }.value
    }

    /// Fetch a profile from pubky.app (external, one-time read)
    private func fetchProfileFromPubkyApp(publicKey: String) async -> PubkyProfile {
        let prefixedKey = ensurePubkyPrefix(publicKey)
        do {
            let dto = try await Task.detached {
                try await PubkyService.getProfile(publicKey: prefixedKey)
            }.value
            return PubkyProfile(publicKey: prefixedKey, ffiProfile: dto)
        } catch {
            Logger.warn("Failed to fetch profile from pubky.app for '\(prefixedKey)': \(error)", context: "ContactsManager")
            return PubkyProfile.placeholder(publicKey: prefixedKey)
        }
    }

    /// Extract the public key from a path returned by sessionList
    private func extractPublicKey(from path: String) -> String {
        // sessionList returns paths like "/pub/bitkit.to/contacts/pubkyXYZ" — extract last component
        let components = path.split(separator: "/")
        guard let last = components.last else { return "" }
        return String(last)
    }
}
