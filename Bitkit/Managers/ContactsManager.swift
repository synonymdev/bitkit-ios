import Foundation
import Paykit
import SwiftUI

private let pubkyPrefix = "pubky"

private func ensurePubkyPrefix(_ key: String) -> String {
    key.hasPrefix(pubkyPrefix) ? key : "\(pubkyPrefix)\(key)"
}

enum AddContactValidationResult: Equatable {
    case empty
    case existingContact
    case invalidKey
    case ownKey
    case valid(normalizedKey: String)

    var localizedMessage: String? {
        switch self {
        case .empty, .valid:
            nil
        case .existingContact:
            t("contacts__add_error_existing")
        case .invalidKey:
            t("contacts__add_error_invalid_key")
        case .ownKey:
            t("contacts__add_error_self")
        }
    }
}

func resolveAddContactValidation(
    input: String,
    ownPublicKey: String?,
    existingContacts: [PubkyContact] = []
) -> AddContactValidationResult {
    let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedInput.isEmpty else {
        return .empty
    }

    if PubkyPublicKeyFormat.matches(trimmedInput, ownPublicKey) {
        return .ownKey
    }

    guard let normalizedKey = PubkyPublicKeyFormat.normalized(trimmedInput) else {
        return .invalidKey
    }

    if existingContacts.contains(where: { PubkyPublicKeyFormat.matches($0.publicKey, normalizedKey) }) {
        return .existingContact
    }

    return .valid(normalizedKey: normalizedKey)
}

enum ContactsManagerError: LocalizedError {
    case invalidPublicKey
    case cannotAddYourself
    case alreadyExists

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return t("contacts__add_error_invalid_key")
        case .cannotAddYourself:
            return t("contacts__add_error_self")
        case .alreadyExists:
            return t("contacts__add_error_existing")
        }
    }
}

// MARK: - PubkyContact

// swiftformat:disable:next redundantSendable
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
    @Published var shouldOpenAddContactSheet = false

    /// Pending contacts discovered during import, such as pubky.app follows after Ring auth.
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
        shouldOpenAddContactSheet = false
        clearPendingImport()
    }

    func clearPendingImport() {
        pendingImportProfile = nil
        pendingImportContacts = []
    }

    // MARK: - Load Contacts

    func loadContacts(for publicKey: String) async throws {
        guard !isLoading else {
            Logger.debug("loadContacts skipped — already loading", context: "ContactsManager")
            return
        }

        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false }

        Logger.info("Loading contacts for \(PubkyPublicKeyFormat.redacted(publicKey))", context: "ContactsManager")

        do {
            let records = try await Task.detached {
                try await PubkyService.contactRecords()
            }.value

            Logger.debug("Loaded \(records.count) SDK contact records", context: "ContactsManager")

            let loadedResult: (contacts: [PubkyContact], failures: Int,
                               missingFailures: Int, firstError: Error?) = await withTaskGroup(of: Result<PubkyContact, Error>.self) { group in
                let overrides = Self.loadContactProfileOverrides()
                for record in records {
                    group.addTask {
                        do {
                            let contact = try await Self.contact(from: record, overrides: overrides, includePlaceholder: true)
                            return .success(contact)
                        } catch {
                            Logger.warn(
                                "Failed to load contact data for '\(PubkyPublicKeyFormat.redacted(record.publicKey))': \(error)",
                                context: "ContactsManager"
                            )
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

            if !records.isEmpty, loadedResult.contacts.isEmpty {
                if loadedResult.failures == loadedResult.missingFailures {
                    await PrivatePaykitService.shared.pruneUnsavedContactState(savedPublicKeys: [])
                    contacts = []
                    hasLoaded = true
                    Logger.info("Contacts storage entries were missing, treating list as empty", context: "ContactsManager")
                    return
                }
                throw loadedResult.firstError ?? PubkyServiceError.profileNotFound
            }

            contacts = loadedResult.contacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            await PrivatePaykitService.shared
                .pruneUnsavedContactState(savedPublicKeys: records.compactMap { PubkyPublicKeyFormat.normalized($0.publicKey) })
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
                await PrivatePaykitService.shared.pruneUnsavedContactState(savedPublicKeys: [])
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

    // MARK: - Add Contact

    func addContact(publicKey: String, existingProfile: PubkyProfile? = nil, ownPublicKey: String? = nil) async throws {
        guard let prefixedKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw ContactsManagerError.invalidPublicKey
        }

        if PubkyPublicKeyFormat.matches(prefixedKey, ownPublicKey) {
            throw ContactsManagerError.cannotAddYourself
        }

        guard !contacts.contains(where: { PubkyPublicKeyFormat.matches($0.publicKey, prefixedKey) }) else {
            throw ContactsManagerError.alreadyExists
        }

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

        try await Task.detached {
            _ = try await PubkyService.saveContact(publicKey: prefixedKey, label: profile.name)
        }.value

        Logger.info("Added contact \(PubkyPublicKeyFormat.redacted(prefixedKey))", context: "ContactsManager")

        let contact = PubkyContact(publicKey: prefixedKey, profile: profile)
        contacts.append(contact)
        contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Import Contacts

    func importContacts(publicKeys: [String]) async throws {
        let prefixedKeys = Array(Set(publicKeys.compactMap(PubkyPublicKeyFormat.normalized)))

        let loadedResult: (contacts: [PubkyContact], failures: Int,
                           firstError: Error?) = await withTaskGroup(of: Result<PubkyContact, Error>.self) { group in
            for key in prefixedKeys {
                group.addTask { [self] in
                    do {
                        let profile = try await resolveContactProfile(publicKey: key, includePlaceholder: true)
                        _ = try await PubkyService.saveContact(publicKey: key, label: profile.name)
                        return .success(PubkyContact(publicKey: key, profile: profile))
                    } catch {
                        Logger.warn("Failed to save imported contact '\(PubkyPublicKeyFormat.redacted(key))': \(error)", context: "ContactsManager")
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

        let existingKeys = Set(contacts.map(\.publicKey))
        let newContacts = loadedResult.contacts.filter { !existingKeys.contains($0.publicKey) }
        contacts.append(contentsOf: newContacts)
        contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        if loadedResult.failures > 0 {
            Logger.warn("Skipped \(loadedResult.failures) contacts during import", context: "ContactsManager")
        }

        Logger.info("Imported \(newContacts.count) new contacts", context: "ContactsManager")
    }

    // MARK: - Update Contact

    func updateContact(publicKey: String, name: String, bio: String, imageUrl: String?, links: [PubkyProfileLink], tags: [String]) async throws {
        let prefixedKey = ensurePubkyPrefix(publicKey)

        let contactData = PubkyProfileData(
            name: name,
            bio: bio,
            image: imageUrl,
            links: links.map { PubkyProfileData.Link(label: $0.label, url: $0.url) },
            tags: tags
        )

        try await Task.detached {
            _ = try await PubkyService.saveContact(publicKey: prefixedKey, label: name)
        }.value
        Self.upsertContactProfileOverride(publicKey: prefixedKey, data: contactData)

        let updatedProfile = contactData.toProfile(publicKey: prefixedKey)
        if let index = contacts.firstIndex(where: { $0.publicKey == prefixedKey }) {
            contacts[index] = PubkyContact(publicKey: prefixedKey, profile: updatedProfile)
            contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }

        Logger.info("Updated contact \(PubkyPublicKeyFormat.redacted(prefixedKey))", context: "ContactsManager")
    }

    // MARK: - Delete Contact

    func removeContact(publicKey: String) async throws {
        let prefixedKey = ensurePubkyPrefix(publicKey)

        try await Task.detached {
            _ = try await PubkyService.removeContact(publicKey: prefixedKey)
        }.value
        Self.removeContactProfileOverride(publicKey: prefixedKey)

        Logger.info("Removed contact \(PubkyPublicKeyFormat.redacted(prefixedKey))", context: "ContactsManager")

        contacts.removeAll { $0.publicKey == prefixedKey }
        await PrivatePaykitService.shared.removeSavedContact(publicKey: prefixedKey)
    }

    func deleteAllContacts() async throws {
        let records: [ContactRecord]
        do {
            records = try await Task.detached {
                try await PubkyService.contactRecords()
            }.value
        } catch {
            guard Self.isMissingContactsDataError(error) else {
                throw error
            }

            Self.clearContactProfileOverrides()
            await PrivatePaykitService.shared.pruneUnsavedContactState(savedPublicKeys: [])
            contacts.removeAll()
            Logger.info("Contacts storage missing, treating delete-all as empty", context: "ContactsManager")
            return
        }

        var deletedKeys = Set<String>()
        var firstError: Error?

        for record in records {
            guard let contactKey = PubkyPublicKeyFormat.normalized(record.publicKey) else { continue }
            do {
                try await Task.detached {
                    _ = try await PubkyService.removeContact(publicKey: contactKey)
                }.value
                deletedKeys.insert(contactKey)
            } catch {
                firstError = firstError ?? error
                Logger.warn("Failed to delete contact '\(PubkyPublicKeyFormat.redacted(contactKey))': \(error)", context: "ContactsManager")
            }
        }

        if let firstError {
            if !deletedKeys.isEmpty {
                contacts.removeAll { deletedKeys.contains($0.publicKey) }
                await PrivatePaykitService.shared.removeSavedContacts(publicKeys: Array(deletedKeys))
            }
            throw firstError
        }

        // All remote deletes succeeded, so clear any local-only contacts too.
        Self.clearContactProfileOverrides()
        await PrivatePaykitService.shared.pruneUnsavedContactState(savedPublicKeys: [])
        contacts.removeAll()
        Logger.info("Deleted all contacts", context: "ContactsManager")
    }

    func deleteAllContactsBestEffort() async {
        do {
            try await deleteAllContacts()
        } catch {
            Logger.warn("Continuing after contact cleanup failed: \(error)", context: "ContactsManager")
            Self.clearContactProfileOverrides()
            await PrivatePaykitService.shared.pruneUnsavedContactState(savedPublicKeys: [])
            contacts.removeAll()
        }
    }

    // MARK: - Remote Contact Discovery

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
                            let profile = try await resolveContactProfile(publicKey: pk, includePlaceholder: true)
                            return .success(PubkyContact(publicKey: pk, profile: profile))
                        } catch {
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

    // MARK: - Contact Profile Resolution

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

    nonisolated static func backupContactProfileOverrides() -> [String: PubkyProfileData]? {
        let overrides = loadContactProfileOverrides()
        return overrides.isEmpty ? nil : overrides
    }

    nonisolated static func restoreContactProfileOverrides(_ overrides: [String: PubkyProfileData]?) {
        guard let overrides, !overrides.isEmpty else {
            UserDefaults.standard.removeObject(forKey: contactProfileOverridesKey)
            notifyContactProfileOverridesChanged()
            return
        }

        saveContactProfileOverrides(overrides)
    }

    private func resolveContactProfile(publicKey: String, includePlaceholder: Bool = false) async throws -> PubkyProfile {
        try await Self.resolveContactProfile(publicKey: publicKey, includePlaceholder: includePlaceholder)
    }

    private nonisolated static func resolveContactProfile(publicKey: String, includePlaceholder: Bool = false) async throws -> PubkyProfile {
        let prefixedKey = ensurePubkyPrefix(publicKey)
        for attempt in 0 ..< 2 {
            do {
                if let resolution = try await PubkyService.resolveContactProfile(publicKey: prefixedKey, allowPubkyProfileFallback: true) {
                    return PubkyProfile(resolution: resolution)
                }
                throw PubkyServiceError.profileNotFound
            } catch {
                if attempt == 0, !(error is CancellationError) {
                    Logger.warn(
                        "Retrying contact profile resolution for '\(PubkyPublicKeyFormat.redacted(prefixedKey))' after transient error: \(error)",
                        context: "ContactsManager"
                    )
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                if includePlaceholder, !(error is CancellationError) {
                    let message = Self.isMissingContactsDataError(error)
                        ? "No remote profile found"
                        : "Failed to resolve remote profile"
                    Logger.warn(
                        "\(message) for '\(PubkyPublicKeyFormat.redacted(prefixedKey))', using placeholder: \(error)",
                        context: "ContactsManager"
                    )
                    return PubkyProfile.placeholder(publicKey: prefixedKey)
                }

                Logger.warn(
                    "Failed to resolve contact profile for '\(PubkyPublicKeyFormat.redacted(prefixedKey))': \(error)",
                    context: "ContactsManager"
                )
                throw error
            }
        }

        throw PubkyServiceError.profileNotFound
    }

    private nonisolated static let contactProfileOverridesKey = "pubkyContactProfileOverrides"

    private nonisolated static func contact(
        from record: Paykit.ContactRecord,
        overrides: [String: PubkyProfileData],
        includePlaceholder: Bool
    ) async throws -> PubkyContact {
        let prefixedKey = PubkyPublicKeyFormat.normalized(record.publicKey) ?? ensurePubkyPrefix(record.publicKey)

        if let override = overrides[prefixedKey] {
            return PubkyContact(publicKey: prefixedKey, profile: override.toProfile(publicKey: prefixedKey))
        }

        if let profile = record.profile {
            let contactProfile = PubkyProfile(publicKey: prefixedKey, paykitProfile: profile)
                .withNameFallback(record.label)
            return PubkyContact(publicKey: prefixedKey, profile: contactProfile)
        }

        do {
            let profile = try await resolveContactProfile(publicKey: prefixedKey, includePlaceholder: includePlaceholder)
                .withNameFallback(record.label)
            return PubkyContact(
                publicKey: prefixedKey,
                profile: profile
            )
        } catch {
            if !includePlaceholder {
                throw error
            }
        }

        if includePlaceholder {
            return PubkyContact(
                publicKey: prefixedKey,
                profile: PubkyProfile.forDisplay(publicKey: prefixedKey, name: record.label, imageUrl: nil)
            )
        }

        throw PubkyServiceError.profileNotFound
    }

    private nonisolated static func loadContactProfileOverrides() -> [String: PubkyProfileData] {
        guard let data = UserDefaults.standard.data(forKey: contactProfileOverridesKey),
              let overrides = try? JSONDecoder().decode([String: PubkyProfileData].self, from: data)
        else {
            return [:]
        }
        return overrides
    }

    private nonisolated static func saveContactProfileOverrides(_ overrides: [String: PubkyProfileData]) {
        if overrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: contactProfileOverridesKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: contactProfileOverridesKey)
        }
        notifyContactProfileOverridesChanged()
    }

    private nonisolated static func upsertContactProfileOverride(publicKey: String, data: PubkyProfileData) {
        guard let prefixedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        var overrides = loadContactProfileOverrides()
        overrides[prefixedKey] = data
        saveContactProfileOverrides(overrides)
    }

    private nonisolated static func removeContactProfileOverride(publicKey: String) {
        guard let prefixedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        var overrides = loadContactProfileOverrides()
        overrides.removeValue(forKey: prefixedKey)
        saveContactProfileOverrides(overrides)
    }

    private nonisolated static func clearContactProfileOverrides() {
        saveContactProfileOverrides([:])
    }

    private nonisolated static func notifyContactProfileOverridesChanged() {
        Task { @MainActor in
            SettingsViewModel.shared.notifyAppStateChanged()
        }
    }

    nonisolated static func isMissingContactsDataError(_ error: Error) -> Bool {
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

    private nonisolated static func isMissingContactsDataMessage(_ message: String?) -> Bool {
        guard let message else {
            return false
        }

        let normalized = message.lowercased()
        return normalized.contains("404")
            || normalized.contains("no such file")
            || normalized.contains("does not exist")
            || normalized.contains("profile not found")
            || normalized.contains("profilenotfound")
            || (normalized.contains("fetch failed") && normalized.contains("not found"))
    }
}
