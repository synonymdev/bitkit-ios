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
    @Published var loadErrorMessage: String?

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
        loadErrorMessage = nil
        pendingImportProfile = nil
        pendingImportContacts = []
    }

    // MARK: - Load Contacts (from bitkit.to homeserver)

    func loadContacts(for publicKey: String) async throws {
        guard !isLoading else {
            Logger.debug("loadContacts skipped — already loading", context: "ContactsManager")
            return
        }

        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false }

        let basePath = contactsBasePath
        Logger.info("Loading contacts from \(basePath) for \(publicKey)", context: "ContactsManager")

        do {
            let sessionSecret = try getSessionSecret()

            let contactPaths = try await Task.detached {
                try await PubkyService.sessionList(sessionSecret: sessionSecret, dirPath: basePath)
            }.value

            Logger.debug("Listed \(contactPaths.count) contacts from homeserver", context: "ContactsManager")

            let strippedKey = stripPubkyPrefix(publicKey)

            let loadedResult: (contacts: [PubkyContact], failures: Int,
                               firstError: Error?) = await withTaskGroup(of: Result<PubkyContact, Error>.self) { group in
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
                            return .success(PubkyContact(publicKey: prefixedKey, profile: profile))
                        } catch {
                            Logger.warn("Failed to load contact data for '\(prefixedKey)': \(error)", context: "ContactsManager")
                            return .failure(error)
                        }
                    }
                }

                var results: [PubkyContact] = []
                var failures = 0
                var firstError: Error?

                for await result in group {
                    switch result {
                    case let .success(contact):
                        results.append(contact)
                    case let .failure(error):
                        failures += 1
                        firstError = firstError ?? error
                    }
                }

                return (results, failures, firstError)
            }

            if !contactPaths.isEmpty, loadedResult.contacts.isEmpty {
                throw loadedResult.firstError ?? PubkyServiceError.profileNotFound
            }

            contacts = loadedResult.contacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            hasLoaded = true

            if loadedResult.failures > 0 {
                Logger.warn(
                    "Skipped \(loadedResult.failures) unreadable contacts while loading list",
                    context: "ContactsManager"
                )
            }

            Logger.info("Loaded \(contacts.count) contacts", context: "ContactsManager")
        } catch {
            Logger.error("Failed to load contacts: \(error)", context: "ContactsManager")
            if contacts.isEmpty {
                loadErrorMessage = error.localizedDescription
            }
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
            try await fetchProfileFromPubkyApp(publicKey: prefixedKey)
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
        let prefixedKeys = Array(Set(publicKeys.map { ensurePubkyPrefix($0) }))

        // Fetch profiles from pubky.app and write each to bitkit.to
        let loadedResult: (contacts: [PubkyContact], failures: Int,
                           firstError: Error?) = await withTaskGroup(of: Result<PubkyContact, Error>.self) { group in
            for key in prefixedKeys {
                group.addTask { [self] in
                    do {
                        let profile = try await fetchProfileFromPubkyApp(publicKey: key)
                        let contactData = PubkyProfileData.from(profile: profile)
                        try await savePubkyProfileData(publicKey: key, data: contactData)
                        return .success(PubkyContact(publicKey: key, profile: profile))
                    } catch {
                        Logger.warn("Failed to save imported contact '\(key)': \(error)", context: "ContactsManager")
                        return .failure(error)
                    }
                }
            }

            var results: [PubkyContact] = []
            var failures = 0
            var firstError: Error?

            for await result in group {
                switch result {
                case let .success(contact):
                    results.append(contact)
                case let .failure(error):
                    failures += 1
                    firstError = firstError ?? error
                }
            }

            return (results, failures, firstError)
        }

        if !prefixedKeys.isEmpty, loadedResult.contacts.isEmpty {
            throw loadedResult.firstError ?? PubkyServiceError.profileNotFound
        }

        // Merge with existing contacts, avoiding duplicates
        let existingKeys = Set(contacts.map(\.publicKey))
        let newContacts = loadedResult.contacts.filter { !existingKeys.contains($0.publicKey) }
        contacts.append(contentsOf: newContacts)
        contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        if loadedResult.failures > 0 {
            Logger.warn("Skipped \(loadedResult.failures) contacts during import", context: "ContactsManager")
        }

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

            let discoveryResult: (contacts: [PubkyContact], failures: Int) = await withTaskGroup(of: Result<PubkyContact, Error>.self) { group in
                for key in contactKeys {
                    let pk = ensurePubkyPrefix(key)
                    group.addTask { [self] in
                        do {
                            let profile = try await fetchProfileFromPubkyApp(publicKey: pk)
                            return .success(PubkyContact(publicKey: pk, profile: profile))
                        } catch {
                            Logger.warn("Failed to discover remote contact '\(pk)': \(error)", context: "ContactsManager")
                            return .failure(error)
                        }
                    }
                }

                var results: [PubkyContact] = []
                var failures = 0

                for await result in group {
                    switch result {
                    case let .success(contact):
                        results.append(contact)
                    case .failure:
                        failures += 1
                    }
                }

                return (results, failures)
            }

            if discoveryResult.failures > 0 {
                Logger.warn("Skipped \(discoveryResult.failures) remote contacts during discovery", context: "ContactsManager")
            }

            pendingImportContacts = discoveryResult.contacts.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } catch {
            Logger.warn("Failed to discover remote contacts: \(error)", context: "ContactsManager")
            pendingImportContacts = []
        }
    }

    // MARK: - Fetch Contact Profile (from pubky.app — used only during add/import)

    func fetchContactProfile(publicKey: String) async -> PubkyProfile? {
        do {
            return try await fetchProfileFromPubkyApp(publicKey: ensurePubkyPrefix(publicKey))
        } catch {
            return nil
        }
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
    private func fetchProfileFromPubkyApp(publicKey: String) async throws -> PubkyProfile {
        let prefixedKey = ensurePubkyPrefix(publicKey)
        do {
            let dto = try await Task.detached {
                try await PubkyService.getProfile(publicKey: prefixedKey)
            }.value
            return PubkyProfile(publicKey: prefixedKey, ffiProfile: dto)
        } catch {
            Logger.warn("Failed to fetch profile from pubky.app for '\(prefixedKey)': \(error)", context: "ContactsManager")
            throw error
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
