import Combine
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
    private var contactsRevision = 0
    private var loadGeneration = 0
    private var isApplyingProfileRefresh = false
    private var profileRefresh: ContactProfileRefresh?
    private var profileRefreshCount = 0
    private var pendingProfileLookups: [String: Task<Void, Never>] = [:]
    /// Profiles resolved this session for the owner's contacts, shown in place of stored labels while a load refreshes.
    private var resolvedProfiles: [String: PubkyProfile] = [:]
    private var resolvedProfilesOwner: String?
    private var resolvedProfilesGeneration = 0
    private let contactRecords: @Sendable () async throws -> [ContactRecord]
    private let fetchFollows: @Sendable (String) async throws -> [String]
    private let fetchRemoteProfile: @Sendable (_ publicKey: String, _ priority: PaykitPublicReadPriority) async throws -> PubkyProfile?

    init(
        contactRecords: @escaping @Sendable () async throws -> [ContactRecord] = PubkyService.contactRecords,
        fetchFollows: @escaping @Sendable (String) async throws -> [String] = { try await PubkyService.getContacts(publicKey: $0) },
        fetchRemoteProfile: @escaping @Sendable (_ publicKey: String, _ priority: PaykitPublicReadPriority) async throws -> PubkyProfile? = {
            try await ContactsManager.remoteContactProfile(publicKey: $0, priority: $1)
        }
    ) {
        self.contactRecords = contactRecords
        self.fetchFollows = fetchFollows
        self.fetchRemoteProfile = fetchRemoteProfile
    }

    /// Profile refreshes replace rows without counting as a change to the saved contacts.
    @Published var contacts: [PubkyContact] = [] {
        didSet {
            guard !isApplyingProfileRefresh else { return }
            contactsRevision += 1
            savedContactsChangedSubject.send(contacts)
        }
    }

    private let savedContactsChangedSubject = PassthroughSubject<[PubkyContact], Never>()

    /// The contacts after every change that may have changed the saved contact list. Profiles a background refresh
    /// fills in do not emit, so work that runs per saved contact, such as private Paykit sync, does not rerun per row.
    var savedContactsChangedPublisher: AnyPublisher<[PubkyContact], Never> {
        savedContactsChangedSubject.eraseToAnyPublisher()
    }

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
        loadGeneration += 1
        forgetResolvedProfiles(owner: nil)
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

    /// Clears the pending import once an import of it finishes and returns whether it was still pending. An import
    /// outlives its screens and leaving the import flow discards the pending import, so false means the user left and
    /// must not be taken to Pay Contacts.
    func completePendingImport() -> Bool {
        guard hasPendingImport else { return false }
        clearPendingImport()
        return true
    }

    // MARK: - Load Contacts

    func loadContactsIfNeeded(for publicKey: String) async throws {
        while !hasLoaded {
            try Task.checkCancellation()
            if isLoading {
                for await isLoading in $isLoading.values {
                    try Task.checkCancellation()
                    if !isLoading {
                        break
                    }
                }
            } else {
                try await loadContacts(for: publicKey)
            }
        }
    }

    func loadContacts(for publicKey: String) async throws {
        try await loadContacts(
            for: publicKey,
            fetchContactRecords: contactRecords,
            fetchRemoteProfile: remoteProfileLookup(on: .bulk)
        )
    }

    /// Publishes the saved records straight away, each with the best profile already known, then looks the remaining
    /// profiles up in the background on the bulk read lane and updates rows as they resolve. A failed lookup leaves its
    /// row as it is. A cancelled or failed load publishes nothing and leaves a running refresh to finish.
    func loadContacts(
        for publicKey: String,
        fetchContactRecords: @escaping @Sendable () async throws -> [Paykit.ContactRecord],
        fetchRemoteProfile: @escaping @Sendable (String) async throws -> PubkyProfile?
    ) async throws {
        guard !isLoading else {
            Logger.debug("loadContacts skipped — already loading", context: "ContactsManager")
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        useResolvedProfiles(of: publicKey)
        isLoading = true
        loadErrorMessage = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        Logger.info("Loading contacts for \(PubkyPublicKeyFormat.redacted(publicKey))", context: "ContactsManager")

        while generation == loadGeneration {
            try Task.checkCancellation()
            let revision = contactsRevision
            do {
                let records = try await fetchContactRecords()
                guard !Task.isCancelled, generation == loadGeneration else { return }
                guard contactsRevision == revision else { continue }

                Logger.debug("Loaded \(records.count) SDK contact records", context: "ContactsManager")

                let overrides = Self.loadContactProfileOverrides()
                contacts = records.map { savedContact(from: $0, overrides: overrides) }.sorted(by: Self.isOrderedByName)
                hasLoaded = true
                refreshContactProfiles(
                    for: records.filter { $0.profile == nil && overrides[Self.contactKey(for: $0)] == nil },
                    fetchRemoteProfile: fetchRemoteProfile
                )
                await PrivatePaykitService.shared
                    .pruneUnsavedContactState(savedPublicKeys: records.compactMap { PubkyPublicKeyFormat.normalized($0.publicKey) })

                Logger.info("Loaded \(contacts.count) contacts", context: "ContactsManager")
                return
            } catch {
                guard contactsRevision == revision else { continue }
                if Self.isMissingContactsDataError(error) {
                    contacts = []
                    hasLoaded = true
                    loadErrorMessage = nil
                    await PrivatePaykitService.shared.pruneUnsavedContactState(savedPublicKeys: [])
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
    }

    private func savedContact(from record: Paykit.ContactRecord, overrides: [String: PubkyProfileData]) -> PubkyContact {
        let publicKey = Self.contactKey(for: record)
        if let override = overrides[publicKey] {
            return PubkyContact(publicKey: publicKey, profile: override.toProfile(publicKey: publicKey))
        }
        if let profile = record.profile {
            return PubkyContact(
                publicKey: publicKey,
                profile: PubkyProfile(publicKey: publicKey, paykitProfile: profile).withNameFallback(record.label)
            )
        }
        if let profile = resolvedProfiles[publicKey] {
            return PubkyContact(publicKey: publicKey, profile: profile.withNameFallback(record.label))
        }
        let label = record.label.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return PubkyContact(publicKey: publicKey, profile: PubkyProfile.forDisplay(publicKey: publicKey, name: label, imageUrl: nil))
    }

    /// Keeps a running refresh that already looks up every one of `records`, so reopening Contacts does not start the same
    /// lookups again; otherwise replaces it.
    private func refreshContactProfiles(
        for records: [Paykit.ContactRecord],
        fetchRemoteProfile: @escaping @Sendable (String) async throws -> PubkyProfile?
    ) {
        let labels = Dictionary(records.map { (Self.contactKey(for: $0), $0.label) }, uniquingKeysWith: { first, _ in first })
        if let running = profileRefresh, Set(running.labels.keys).isSuperset(of: labels.keys) {
            return
        }
        profileRefresh?.task.cancel()
        profileRefresh = nil
        guard !labels.isEmpty else { return }

        profileRefreshCount += 1
        let refreshID = profileRefreshCount
        let task = Task { [weak self] in
            await withTaskGroup(of: (publicKey: String, profile: PubkyProfile?).self) { group in
                for (publicKey, label) in labels {
                    group.addTask {
                        let profile = try? await Self.resolveContactProfile(publicKey: publicKey, fetchRemoteProfile: fetchRemoteProfile)
                        return (publicKey, profile?.withNameFallback(label))
                    }
                }

                for await result in group {
                    self?.finishRefreshLookup(of: result.publicKey, profile: result.profile, refreshID: refreshID)
                }
            }
            self?.finishProfileRefresh(refreshID)
        }
        profileRefresh = ContactProfileRefresh(id: refreshID, labels: labels, pendingKeys: Set(labels.keys), task: task)
    }

    private func finishRefreshLookup(of publicKey: String, profile: PubkyProfile?, refreshID: Int) {
        guard profileRefresh?.id == refreshID else { return }
        profileRefresh?.pendingKeys.remove(publicKey)
        if let profile {
            applyResolvedProfile(profile, for: publicKey)
        }
    }

    private func finishProfileRefresh(_ refreshID: Int) {
        if profileRefresh?.id == refreshID {
            profileRefresh = nil
        }
    }

    /// Looks a saved contact's profile up on the interactive read lane while its row still shows only its saved label
    /// because the background refresh has not reached it, so a screen showing that contact does not wait behind bulk
    /// reads and an edit made there keeps the contact's avatar, bio and links. Returns at once for any other row, and
    /// joins a lookup already running for the contact. When the lookup fails, the row keeps its label.
    func resolvePendingContactProfile(publicKey: String) async {
        await resolvePendingContactProfile(publicKey: publicKey, fetchRemoteProfile: remoteProfileLookup(on: .interactive))
    }

    func resolvePendingContactProfile(
        publicKey: String,
        fetchRemoteProfile: @escaping @Sendable (String) async throws -> PubkyProfile?
    ) async {
        guard let key = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        if let lookup = pendingProfileLookups[key] {
            return await lookup.value
        }
        guard let refresh = profileRefresh,
              refresh.pendingKeys.contains(key),
              let label = refresh.labels[key],
              resolvedProfiles[key] == nil,
              Self.loadContactProfileOverrides()[key] == nil
        else { return }

        let generation = resolvedProfilesGeneration
        let lookup = Task { [weak self] in
            let profile = try? await Self.resolveContactProfile(publicKey: key, fetchRemoteProfile: fetchRemoteProfile)
            self?.finishPendingProfileLookup(of: key, profile: profile?.withNameFallback(label), generation: generation)
        }
        pendingProfileLookups[key] = lookup
        await lookup.value
    }

    private func finishPendingProfileLookup(of publicKey: String, profile: PubkyProfile?, generation: Int) {
        guard generation == resolvedProfilesGeneration else { return }
        pendingProfileLookups[publicKey] = nil
        profileRefresh?.pendingKeys.remove(publicKey)
        if let profile {
            applyResolvedProfile(profile, for: publicKey)
        }
    }

    private func applyResolvedProfile(_ profile: PubkyProfile, for publicKey: String) {
        rememberResolvedProfile(profile, for: publicKey)
        guard Self.loadContactProfileOverrides()[publicKey] == nil,
              let index = contacts.firstIndex(where: { $0.publicKey == publicKey })
        else { return }

        var refreshed = contacts
        refreshed[index] = PubkyContact(publicKey: publicKey, profile: profile)
        refreshed.sort(by: Self.isOrderedByName)
        isApplyingProfileRefresh = true
        contacts = refreshed
        isApplyingProfileRefresh = false
    }

    private func useResolvedProfiles(of ownerPublicKey: String) {
        let owner = PubkyPublicKeyFormat.normalized(ownerPublicKey) ?? ownerPublicKey
        guard owner != resolvedProfilesOwner else { return }
        forgetResolvedProfiles(owner: owner)
    }

    /// Stops every profile lookup still running for the previous owner, so none of them can fill the next owner's rows
    /// or cache.
    private func forgetResolvedProfiles(owner: String?) {
        resolvedProfilesGeneration += 1
        profileRefresh?.task.cancel()
        profileRefresh = nil
        pendingProfileLookups.values.forEach { $0.cancel() }
        pendingProfileLookups = [:]
        resolvedProfiles = [:]
        resolvedProfilesOwner = owner
    }

    private func rememberResolvedProfile(_ profile: PubkyProfile, for publicKey: String) {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        resolvedProfiles[normalizedKey] = profile
    }

    #if DEBUG
        func waitForProfileRefreshForTesting() async {
            await profileRefresh?.task.value
        }
    #endif

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
            try await resolveContactProfile(publicKey: prefixedKey, includePlaceholder: true, retryTransient: true)
        }

        let receiverPaths = try await Self.relevantReceiverPaths(for: prefixedKey)
        _ = try await PubkyService.saveContact(
            publicKey: prefixedKey,
            label: profile.name,
            receiverPaths: receiverPaths,
            restorePrivateConnection: true
        )

        Logger.info("Added contact \(PubkyPublicKeyFormat.redacted(prefixedKey))", context: "ContactsManager")

        rememberResolvedProfile(profile, for: prefixedKey)
        let contact = PubkyContact(publicKey: prefixedKey, profile: profile)
        contacts.append(contact)
        contacts.sort(by: Self.isOrderedByName)
    }

    func refreshContactReceiverPaths(publicKey: String, wallet: WalletViewModel) async {
        guard let prefixedKey = PubkyPublicKeyFormat.normalized(publicKey),
              let contact = contacts.first(where: { PubkyPublicKeyFormat.matches($0.publicKey, prefixedKey) })
        else { return }

        do {
            let receiverPaths = try await Self.relevantReceiverPaths(for: prefixedKey)
            _ = try await PubkyService.saveContact(publicKey: prefixedKey, label: contact.profile.name, receiverPaths: receiverPaths)
            await PrivatePaykitService.shared.startInitialLinkBurst(
                for: [prefixedKey],
                savedPublicKeys: contacts.map(\.publicKey),
                wallet: wallet,
                reason: "contact receiver refresh"
            )
        } catch is CancellationError {
            return
        } catch {
            Logger.warn(
                "Failed to refresh contact receiver paths for \(PubkyPublicKeyFormat.redacted(prefixedKey)): \(error)",
                context: "ContactsManager"
            )
        }
    }

    // MARK: - Import Contacts

    /// Remembers the profiles it saves for this session, so the Contacts list shows them at once rather than only their
    /// saved labels. A placeholder for a follow whose lookup failed is not remembered, so that profile is still looked up.
    /// An import outlives its screens, so a reset or another identity's load while it runs, such as after a sign-out,
    /// stops it quietly: it saves nothing more, adds nothing to the next session's list and reports no error.
    func importContacts(
        contacts selected: [PubkyContact],
        saveContact: (String, String) async throws -> Void = { publicKey, label in
            _ = try await PubkyService.saveContact(publicKey: publicKey, label: label, restorePrivateConnection: true)
        }
    ) async throws {
        let profilesGeneration = resolvedProfilesGeneration
        var imported: [PubkyContact] = []
        var existingKeys = Set(contacts.map(\.publicKey))
        var firstError: Error?

        for contact in selected {
            try Task.checkCancellation()
            guard profilesGeneration == resolvedProfilesGeneration else { break }
            guard !existingKeys.contains(contact.publicKey) else { continue }
            do {
                // The preview already resolved this profile. Receiver discovery runs during contact refresh.
                try await saveContact(contact.publicKey, contact.displayName)
                imported.append(contact)
                existingKeys.insert(contact.publicKey)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                Logger.warn(
                    "Failed to save imported contact '\(PubkyPublicKeyFormat.redacted(contact.publicKey))': \(error)",
                    context: "ContactsManager"
                )
            }
        }

        try Task.checkCancellation()
        guard profilesGeneration == resolvedProfilesGeneration else {
            Logger.info("Stopped a contact import that a reset overtook after \(imported.count) saves", context: "ContactsManager")
            return
        }
        for contact in imported where !contact.profile.isPlaceholder {
            rememberResolvedProfile(contact.profile, for: contact.publicKey)
        }
        let currentKeys = Set(contacts.map(\.publicKey))
        contacts.append(contentsOf: imported.filter { !currentKeys.contains($0.publicKey) })
        contacts.sort(by: Self.isOrderedByName)
        Logger.info("Imported \(imported.count) new contacts", context: "ContactsManager")
        if let firstError {
            throw firstError
        }
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
            contacts.sort(by: Self.isOrderedByName)
        }

        Logger.info("Updated contact \(PubkyPublicKeyFormat.redacted(prefixedKey))", context: "ContactsManager")
    }

    // MARK: - Delete Contact

    func removeContact(publicKey: String) async throws {
        let prefixedKey = ensurePubkyPrefix(publicKey)

        try await Task.detached {
            _ = try await PubkyService.removeContact(publicKey: prefixedKey)
        }.value
        contacts.removeAll { $0.publicKey == prefixedKey }
        Self.removeContactProfileOverride(publicKey: prefixedKey)
        await PrivatePaykitService.shared.removeSavedContact(publicKey: prefixedKey)

        Logger.info("Removed contact \(PubkyPublicKeyFormat.redacted(prefixedKey))", context: "ContactsManager")
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
                await PrivatePaykitService.shared.removeSavedContacts(publicKeys: Array(deletedKeys))
                for publicKey in deletedKeys {
                    Self.removeContactProfileOverride(publicKey: publicKey)
                }
                contacts.removeAll { deletedKeys.contains($0.publicKey) }
            }
            throw firstError
        }

        // All remote deletes succeeded, so clear any local-only contacts too.
        await PrivatePaykitService.shared.removeSavedContacts(publicKeys: Array(deletedKeys))
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

    /// Looks every follow's profile up on the interactive read lane: the user waits on the choice screen until the import
    /// overview opens, and the bulk lane would use only four of the six read slots for those lookups.
    @discardableResult
    func prepareImport(profile: PubkyProfile?, publicKey: String) async -> Bool {
        clearPendingImport()
        useResolvedProfiles(of: publicKey)
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
        let fetchRemoteProfile = remoteProfileLookup(on: .interactive)
        await discoverRemoteContacts(
            publicKey: publicKey,
            fetchContactKeys: fetchFollows,
            resolveProfile: { try await Self.resolveContactProfile(publicKey: $0, includePlaceholder: true, fetchRemoteProfile: fetchRemoteProfile) }
        )
    }

    func discoverRemoteContacts(
        publicKey: String,
        fetchContactKeys: @escaping @Sendable (String) async throws -> [String],
        resolveProfile: @escaping @Sendable (String) async throws -> PubkyProfile
    ) async {
        let prefixedKey = ensurePubkyPrefix(publicKey)

        do {
            let contactKeys = try await Task.detached {
                try await fetchContactKeys(prefixedKey)
            }.value

            Logger.info("Discovered \(contactKeys.count) contacts from pubky.app", context: "ContactsManager")

            let discoveryResult: (contacts: [PubkyContact], failures: Int) = await withTaskGroup(of: Result<PubkyContact, Error>.self) { group in
                for key in contactKeys {
                    let pk = ensurePubkyPrefix(key)
                    guard !PubkyPublicKeyFormat.matches(pk, prefixedKey) else { continue }
                    group.addTask {
                        do {
                            let profile = try await resolveProfile(pk)
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

            pendingImportContacts = discoveryResult.contacts.sorted(by: Self.isOrderedByName)
        } catch {
            Logger.warn("Failed to discover remote contacts: \(error)", context: "ContactsManager")
            pendingImportContacts = []
        }
    }

    /// A background refresh of saved contacts' profiles. `labels` maps each contact it looks up to its saved label, and
    /// `pendingKeys` holds those whose lookup has not finished, whose rows may still show only that label.
    private struct ContactProfileRefresh {
        let id: Int
        let labels: [String: String?]
        var pendingKeys: Set<String>
        let task: Task<Void, Never>
    }

    // MARK: - Contact Profile Resolution

    func fetchContactProfile(publicKey: String, includePlaceholder: Bool = false, retryTransient: Bool = false) async -> PubkyProfile? {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else {
            return nil
        }

        do {
            return try await resolveContactProfile(publicKey: normalizedKey, includePlaceholder: includePlaceholder, retryTransient: retryTransient)
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

    private func resolveContactProfile(
        publicKey: String,
        includePlaceholder: Bool = false,
        retryTransient: Bool = false
    ) async throws -> PubkyProfile {
        try await Self.resolveContactProfile(publicKey: publicKey, includePlaceholder: includePlaceholder, retryTransient: retryTransient)
    }

    nonisolated static let fetchRemoteContactProfile: @Sendable (String) async throws -> PubkyProfile? = {
        try await remoteContactProfile(publicKey: $0, priority: .interactive)
    }

    nonisolated static func remoteContactProfile(publicKey: String, priority: PaykitPublicReadPriority) async throws -> PubkyProfile? {
        try await PubkyService.resolveContactProfile(publicKey: publicKey, allowPubkyProfileFallback: true, priority: priority)
            .map(PubkyProfile.init(resolution:))
    }

    private func remoteProfileLookup(on priority: PaykitPublicReadPriority) -> @Sendable (String) async throws -> PubkyProfile? {
        let fetchRemoteProfile = fetchRemoteProfile
        return { try await fetchRemoteProfile($0, priority) }
    }

    /// A missing profile is never retried. `retryTransient` retries any other failure once and is for user-initiated
    /// lookups only: the SDK reports a key with no pkarr record and a network failure as the same transport error, so a
    /// retry in bulk loads doubles the wait for every contact without a profile.
    nonisolated static func resolveContactProfile(
        publicKey: String,
        includePlaceholder: Bool = false,
        retryTransient: Bool = false,
        fetchRemoteProfile: @Sendable (String) async throws -> PubkyProfile? = ContactsManager.fetchRemoteContactProfile
    ) async throws -> PubkyProfile {
        let prefixedKey = ensurePubkyPrefix(publicKey)
        for attempt in 0 ..< 2 {
            do {
                if let profile = try await fetchRemoteProfile(prefixedKey) {
                    return profile
                }
                throw PubkyServiceError.profileNotFound
            } catch {
                if retryTransient, attempt == 0, isRetryableContactProfileError(error) {
                    Logger.warn(
                        "Retrying contact profile resolution for '\(PubkyPublicKeyFormat.redacted(prefixedKey))' after transient error: \(error)",
                        context: "ContactsManager"
                    )
                    try await Task.sleep(nanoseconds: 250_000_000)
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

    private nonisolated static func isRetryableContactProfileError(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if case .profileNotFound? = error as? PubkyServiceError {
            return false
        }
        return true
    }

    private nonisolated static func relevantReceiverPaths(for publicKey: String) async throws -> [String] {
        do {
            return try await PubkyService.discoverRelevantReceiverPaths(publicKey: publicKey)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.warn(
                "Failed to discover Paykit receivers for '\(PubkyPublicKeyFormat.redacted(publicKey))': \(error)",
                context: "ContactsManager"
            )
            return [PaykitReceiverPath.wallet]
        }
    }

    private nonisolated static let contactProfileOverridesKey = "pubkyContactProfileOverrides"

    private nonisolated static func isOrderedByName(_ lhs: PubkyContact, _ rhs: PubkyContact) -> Bool {
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private nonisolated static func contactKey(for record: Paykit.ContactRecord) -> String {
        PubkyPublicKeyFormat.normalized(record.publicKey) ?? ensurePubkyPrefix(record.publicKey)
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
