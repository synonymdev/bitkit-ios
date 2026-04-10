import Foundation
import SwiftUI

private let pubkyPrefix = "pubky"

private func ensurePubkyPrefix(_ key: String) -> String {
    key.hasPrefix(pubkyPrefix) ? key : "\(pubkyPrefix)\(key)"
}

private func stripPubkyPrefix(_ key: String) -> String {
    key.hasPrefix(pubkyPrefix) ? String(key.dropFirst(pubkyPrefix.count)) : key
}

enum PubkyPublicKeyFormat {
    private static let rawKeyLength = 52
    private static let allowedCharacters = Set("ybndrfg8ejkmcpqxot1uwisza345h769")

    static let maximumInputLength = pubkyPrefix.count + rawKeyLength

    static func bounded(_ input: String) -> String {
        String(input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(maximumInputLength))
    }

    static func normalized(_ input: String) -> String? {
        let boundedInput = bounded(input)
        let rawKey = stripPubkyPrefix(boundedInput)

        guard rawKey.count == rawKeyLength else {
            return nil
        }

        guard rawKey.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }

        return ensurePubkyPrefix(rawKey)
    }

    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs.flatMap(normalized),
              let rhs = rhs.flatMap(normalized)
        else {
            return false
        }

        return lhs == rhs
    }
}

enum ContactsManagerError: LocalizedError {
    case invalidPublicKey
    case cannotAddYourself

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return t("slashtags__contact_error_key")
        case .cannotAddYourself:
            return t("slashtags__contact_error_yourself")
        }
    }
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

    var hasPendingImport: Bool {
        pendingImportProfile != nil && !pendingImportContacts.isEmpty
    }

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
        clearPendingImport()
    }

    func clearPendingImport() {
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
                               missingFailures: Int, firstError: Error?) = await withTaskGroup(of: Result<PubkyContact, Error>.self) { group in
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
                var missingFailures = 0
                var firstError: Error?

                for await result in group {
                    switch result {
                    case let .success(contact):
                        results.append(contact)
                    case let .failure(error):
                        failures += 1
                        if Self.isMissingContactsDataError(error) {
                            missingFailures += 1
                        }
                        firstError = firstError ?? error
                    }
                }

                return (results, failures, missingFailures, firstError)
            }

            if !contactPaths.isEmpty, loadedResult.contacts.isEmpty {
                if loadedResult.failures == loadedResult.missingFailures {
                    contacts = []
                    hasLoaded = true
                    Logger.info("Contacts storage entries were missing, treating list as empty", context: "ContactsManager")
                    return
                }
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
            if Self.isMissingContactsDataError(error) {
                contacts = []
                hasLoaded = true
                loadErrorMessage = nil
                Logger.info("Contacts storage missing, treating list as empty", context: "ContactsManager")
                return
            }

            Logger.error("Failed to load contacts: \(error)", context: "ContactsManager")
            if contacts.isEmpty {
                loadErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    // MARK: - Add Contact (prefer bitkit.to profile, then pubky.app, then placeholder)

    func addContact(publicKey: String, existingProfile: PubkyProfile? = nil, ownPublicKey: String? = nil) async throws {
        guard let prefixedKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw ContactsManagerError.invalidPublicKey
        }

        if PubkyPublicKeyFormat.matches(prefixedKey, ownPublicKey) {
            throw ContactsManagerError.cannotAddYourself
        }

        guard !contacts.contains(where: { $0.publicKey == prefixedKey }) else {
            Logger.debug("Contact \(prefixedKey) already exists, skipping add", context: "ContactsManager")
            return
        }

        // Use existing profile if provided (e.g., already fetched during preview),
        // otherwise resolve remote profile with a placeholder fallback.
        let profile: PubkyProfile = if let existingProfile {
            PubkyProfile(
                publicKey: prefixedKey,
                name: existingProfile.name,
                bio: existingProfile.bio,
                imageUrl: existingProfile.imageUrl,
                links: existingProfile.links,
                tags: existingProfile.tags,
                status: existingProfile.status
            )
        } else {
            try await resolveContactProfile(publicKey: prefixedKey, includePlaceholder: true)
        }

        // Build PubkyProfileData and write to bitkit.to
        let contactData = PubkyProfileData.from(profile: profile)
        try await savePubkyProfileData(publicKey: prefixedKey, data: contactData)

        Logger.info("Added contact \(prefixedKey)", context: "ContactsManager")

        let contact = PubkyContact(publicKey: prefixedKey, profile: profile)
        contacts.append(contact)
        contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Import Contacts (prefer bitkit.to profiles, then pubky.app, then placeholder)

    func importContacts(publicKeys: [String]) async throws {
        let prefixedKeys = Array(Set(publicKeys.compactMap(PubkyPublicKeyFormat.normalized)))

        // Resolve profiles remotely, then write each to bitkit.to
        let loadedResult: (contacts: [PubkyContact], failures: Int,
                           firstError: Error?) = await withTaskGroup(of: Result<PubkyContact, Error>.self) { group in
            for key in prefixedKeys {
                group.addTask { [self] in
                    do {
                        let profile = await resolveImportContactProfile(publicKey: key)
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

    /// Delete all contacts from the homeserver and clear the local list.
    func deleteAllContacts() async {
        let sessionSecret: String
        do {
            sessionSecret = try getSessionSecret()
        } catch {
            Logger.warn("No active session, clearing local contacts only", context: "ContactsManager")
            contacts.removeAll()
            return
        }

        let basePath = contactsBasePath

        let contactPaths: [String]
        do {
            contactPaths = try await Task.detached {
                try await PubkyService.sessionList(sessionSecret: sessionSecret, dirPath: basePath)
            }.value
        } catch {
            if Self.isMissingContactsDataError(error) {
                contacts.removeAll()
                return
            }
            Logger.warn("Failed to list contacts for deletion: \(error)", context: "ContactsManager")
            contacts.removeAll()
            return
        }

        for path in contactPaths {
            let contactKey = extractPublicKey(from: path)
            guard !contactKey.isEmpty else { continue }
            do {
                try await Task.detached {
                    try await PubkyService.sessionDelete(
                        sessionSecret: sessionSecret,
                        path: "\(basePath)\(contactKey)"
                    )
                }.value
            } catch {
                Logger.warn("Failed to delete contact '\(contactKey)': \(error)", context: "ContactsManager")
            }
        }

        contacts.removeAll()
        Logger.info("Deleted all contacts", context: "ContactsManager")
    }

    // MARK: - Discover Remote Contacts (list from pubky.app, then resolve each profile)

    /// Discover profile and contacts from pubky.app, store as pending imports.
    /// Returns true if any import data was found.
    @discardableResult
    func prepareImport(profile: PubkyProfile?, publicKey: String) async -> Bool {
        clearPendingImport()
        await discoverRemoteContacts(publicKey: publicKey)

        guard !pendingImportContacts.isEmpty else {
            return false
        }

        pendingImportProfile = profile ?? PubkyProfile.placeholder(publicKey: ensurePubkyPrefix(publicKey))
        return true
    }

    func destinationAfterAuthentication(profile: PubkyProfile?, publicKey: String) async -> Route {
        let hasImportData = await prepareImport(profile: profile, publicKey: publicKey)
        return hasImportData ? .contactImportOverview : .payContacts
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
                        let profile = await resolveImportContactProfile(publicKey: pk)
                        return .success(PubkyContact(publicKey: pk, profile: profile))
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

    // MARK: - Fetch Contact Profile (prefer bitkit.to profile, then pubky.app)

    func fetchContactProfile(publicKey: String, includePlaceholder: Bool = false) async -> PubkyProfile? {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            return nil
        }

        do {
            return try await resolveContactProfile(publicKey: normalizedKey, includePlaceholder: includePlaceholder)
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

    /// Resolve a contact profile using bitkit.to first, then pubky.app, optionally falling back to a placeholder.
    private func resolveContactProfile(publicKey: String, includePlaceholder: Bool = false) async throws -> PubkyProfile {
        let prefixedKey = ensurePubkyPrefix(publicKey)
        do {
            return try await PubkyProfileManager.resolveRemoteProfile(publicKey: prefixedKey)
        } catch {
            if includePlaceholder, Self.isMissingContactsDataError(error) {
                Logger.info("No remote profile found for '\(prefixedKey)', using placeholder", context: "ContactsManager")
                return PubkyProfile.placeholder(publicKey: prefixedKey)
            }

            Logger.warn("Failed to resolve contact profile for '\(prefixedKey)': \(error)", context: "ContactsManager")
            throw error
        }
    }

    private func resolveImportContactProfile(publicKey: String) async -> PubkyProfile {
        let prefixedKey = ensurePubkyPrefix(publicKey)

        for attempt in 0 ..< 2 {
            do {
                return try await resolveContactProfile(publicKey: prefixedKey, includePlaceholder: true)
            } catch {
                if attempt == 0, !(error is CancellationError) {
                    Logger.warn(
                        "Retrying imported contact profile resolution for '\(prefixedKey)' after transient error: \(error)",
                        context: "ContactsManager"
                    )
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                Logger.warn(
                    "Falling back to placeholder while importing contact '\(prefixedKey)': \(error)",
                    context: "ContactsManager"
                )
                return PubkyProfile.placeholder(publicKey: prefixedKey)
            }
        }

        return PubkyProfile.placeholder(publicKey: prefixedKey)
    }

    /// Extract the public key from a path returned by sessionList
    private func extractPublicKey(from path: String) -> String {
        // sessionList returns paths like "/pub/bitkit.to/contacts/pubkyXYZ" — extract last component
        let components = path.split(separator: "/")
        guard let last = components.last else { return "" }
        return String(last)
    }

    static func isMissingContactsDataError(_ error: Error) -> Bool {
        if case .profileNotFound = error as? PubkyServiceError {
            return true
        }

        if let appError = error as? AppError,
           isMissingContactsDataMessage(appError.debugMessage)
        {
            return true
        }

        let nsError = error as NSError

        if nsError.domain == NSCocoaErrorDomain {
            let cocoaCode = CocoaError.Code(rawValue: nsError.code)
            if cocoaCode == .fileNoSuchFile || cocoaCode == .fileReadNoSuchFile {
                return true
            }
        }

        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }

        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorFileDoesNotExist {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingContactsDataError(underlyingError)
        }

        if isMissingContactsDataMessage(String(describing: error))
            || isMissingContactsDataMessage(String(reflecting: error))
        {
            return true
        }

        if isMissingContactsDataMessage(error.localizedDescription) {
            return true
        }

        return false
    }

    private static func isMissingContactsDataMessage(_ message: String?) -> Bool {
        guard let message else {
            return false
        }

        let normalized = message.lowercased()
        let indicatesMissingResource = normalized.contains("404")
            || normalized.contains("no such file")
            || normalized.contains("does not exist")
            || normalized.contains("profile not found")
            || (normalized.contains("fetch failed") && normalized.contains("not found"))

        return indicatesMissingResource
    }
}
