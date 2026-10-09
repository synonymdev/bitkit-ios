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

/// The fields an edit on a contact's edit screen saves.
struct ContactEdit {
    let name: String
    let bio: String
    let imageUrl: String?
    let links: [PubkyProfileLink]
    let tags: [String]
}

// MARK: - ContactsManager

@MainActor
class ContactsManager: ObservableObject {
    /// How long a contact profile resolved in this session is shown without being looked up again.
    nonisolated static let contactProfileFreshness: TimeInterval = 10 * 60
    /// Shortest time between two contact list updates of a background profile refresh.
    nonisolated static let contactRefreshBatchWindow: Duration = .milliseconds(300)

    private var contactsRevision = 0
    private var loadGeneration = 0
    private var isApplyingProfileRefresh = false
    private var profileRefresh: ContactProfileRefresh?
    private var profileRefreshCount = 0
    /// Each contact's lookup started by a screen, under an id its result is checked against, so the result of a lookup that
    /// was ended never lands.
    private var pendingProfileLookups: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// The last tag change queued for each contact, which the next one for that contact waits for. Forgotten on a reset
    /// or owner change, so a change for the next session never waits behind one from the session before.
    private var tagChanges: [String: Task<Void, Error>] = [:]
    /// Profiles resolved this session for the owner's contacts, shown in place of stored labels while a load refreshes,
    /// each with the time it was resolved.
    private var resolvedProfiles: [String: ResolvedContactProfile] = [:]
    private var resolvedProfilesOwner: String?
    private var resolvedProfilesGeneration = 0
    private let contactRecords: @Sendable () async throws -> [ContactRecord]
    private let fetchFollows: @Sendable (String) async throws -> [String]
    private let fetchRemoteProfile: @Sendable (_ publicKey: String, _ priority: PaykitPublicReadPriority) async throws -> PubkyProfile?
    private let saveContactLabel: @Sendable (_ publicKey: String, _ label: String, _ expectedIdentity: String) async throws -> Void
    private let removeContactRecord: @Sendable (_ publicKey: String) async throws -> Void
    private let removeContactRecords: @Sendable (_ publicKeys: [String]) async throws -> [ContactRecord]
    private let forgetRemovedContacts: @Sendable (_ publicKeys: [String]) async -> Void
    private let currentDate: @Sendable () -> Date

    init(
        contactRecords: @escaping @Sendable () async throws -> [ContactRecord] = PubkyService.contactRecords,
        fetchFollows: @escaping @Sendable (String) async throws -> [String] = { try await PubkyService.getContacts(publicKey: $0) },
        fetchRemoteProfile: @escaping @Sendable (_ publicKey: String, _ priority: PaykitPublicReadPriority) async throws -> PubkyProfile? = {
            try await ContactsManager.remoteContactProfile(publicKey: $0, priority: $1)
        },
        saveContactLabel: @escaping @Sendable (_ publicKey: String, _ label: String, _ expectedIdentity: String) async throws -> Void = {
            _ = try await PubkyService.saveContact(publicKey: $0, label: $1, expectedIdentity: $2)
        },
        removeContactRecord: @escaping @Sendable (_ publicKey: String) async throws -> Void = {
            _ = try await PubkyService.removeContact(publicKey: $0)
        },
        removeContactRecords: @escaping @Sendable (_ publicKeys: [String]) async throws -> [ContactRecord] = {
            try await PubkyService.removeContacts(publicKeys: $0)
        },
        forgetRemovedContacts: @escaping @Sendable (_ publicKeys: [String]) async -> Void = {
            await PrivatePaykitService.shared.removeSavedContacts(publicKeys: $0)
        },
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.contactRecords = contactRecords
        self.fetchFollows = fetchFollows
        self.fetchRemoteProfile = fetchRemoteProfile
        self.saveContactLabel = saveContactLabel
        self.removeContactRecord = removeContactRecord
        self.removeContactRecords = removeContactRecords
        self.forgetRemovedContacts = forgetRemovedContacts
        self.currentDate = currentDate
    }

    /// Profile refreshes replace rows without counting as a change to the saved contacts.
    @Published var contacts: [PubkyContact] = [] {
        didSet {
            guard !isApplyingProfileRefresh else { return }
            contactsRevision += 1
            announceSavedContactsIfKeysChanged()
        }
    }

    private let savedContactsChangedSubject = PassthroughSubject<[PubkyContact], Never>()
    /// The saved contact keys last announced, or nil while nothing was announced for the current owner.
    private var announcedSavedContactKeys: Set<String>?

    /// The contacts each time the set of saved contact keys changes, and on the first load for each owner even when it
    /// finds none. A reload, a profile refresh or an edit that keeps the same keys does not emit, so work that runs per
    /// saved contact, such as private Paykit sync, which walks every saved contact under the publication lock, does not
    /// rerun each time Contacts opens.
    var savedContactsChangedPublisher: AnyPublisher<[PubkyContact], Never> {
        savedContactsChangedSubject.eraseToAnyPublisher()
    }

    func savedContactsSnapshot() -> (publicKeys: [String], isCurrent: @MainActor () -> Bool) {
        let keys = announcedSavedContactKeys
        let generation = resolvedProfilesGeneration
        return (contacts.map(\.publicKey), { self.announcedSavedContactKeys == keys && self.resolvedProfilesGeneration == generation })
    }

    private func announceSavedContactsIfKeysChanged() {
        let keys = Set(contacts.map { PubkyPublicKeyFormat.normalized($0.publicKey) ?? $0.publicKey })
        guard keys != announcedSavedContactKeys else { return }
        announcedSavedContactKeys = keys
        savedContactsChangedSubject.send(contacts)
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
    /// profiles up in the background on the bulk read lane and updates rows as they resolve. A profile resolved in this
    /// session less than `contactProfileFreshness` ago is not looked up again, so coming back to Contacts does not look
    /// every contact up again. A failed lookup leaves its row as it is and remembers nothing, so the next load looks that
    /// contact up again. A cancelled or failed load publishes nothing and leaves a running refresh to finish. A cancelled
    /// load returns without an error even when the record read throws once cancelled, as the SDK lock does.
    func loadContacts(
        for publicKey: String,
        fetchContactRecords: @escaping @Sendable () async throws -> [Paykit.ContactRecord],
        fetchRemoteProfile: @escaping @Sendable (String) async throws -> PubkyProfile?
    ) async throws {
        guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
            let revision = contactsRevision
            do {
                let records = try await fetchContactRecords()
                guard !Task.isCancelled, generation == loadGeneration else { return }
                guard contactsRevision == revision else { continue }

                Logger.debug("Loaded \(records.count) SDK contact records", context: "ContactsManager")

                let overrides = Self.loadContactProfileOverrides()
                contacts = records.map { savedContact(from: $0, overrides: overrides) }.sorted(by: Self.isOrderedByName)
                hasLoaded = true
                let now = currentDate()
                refreshContactProfiles(
                    for: records.filter { record in
                        let key = Self.contactKey(for: record)
                        return record.profile == nil && overrides[key] == nil && resolvedProfiles[key]?.isFresh(at: now) != true
                    },
                    fetchRemoteProfile: fetchRemoteProfile
                )
                let snapshot = savedContactsSnapshot()
                await PrivatePaykitService.shared.pruneUnsavedContactState(
                    savedPublicKeys: snapshot.publicKeys, isSessionCurrent: snapshot.isCurrent
                )

                Logger.info("Loaded \(contacts.count) contacts", context: "ContactsManager")
                return
            } catch {
                guard !Task.isCancelled, generation == loadGeneration else { return }
                guard contactsRevision == revision else { continue }
                if Self.isMissingContactsDataError(error) {
                    contacts = []
                    hasLoaded = true
                    loadErrorMessage = nil
                    await PrivatePaykitService.shared.pruneUnsavedContactState(
                        savedPublicKeys: [], isSessionCurrent: savedContactsSnapshot().isCurrent
                    )
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
        if let profile = resolvedProfiles[publicKey]?.profile {
            return PubkyContact(publicKey: publicKey, profile: profile.withNameFallback(record.label))
        }
        let label = record.label.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return PubkyContact(publicKey: publicKey, profile: PubkyProfile.forDisplay(publicKey: publicKey, name: label, imageUrl: nil))
    }

    /// Keeps a running refresh that already looks up every one of `records`, so reopening Contacts does not start the same
    /// lookups again; otherwise replaces it. The refresh applies the profiles it finds in batches, at most once every
    /// `contactRefreshBatchWindow`, sorting and publishing the list once per batch rather than once per contact, and
    /// applies the last batch as soon as its lookups finish.
    private func refreshContactProfiles(
        for records: [Paykit.ContactRecord],
        fetchRemoteProfile: @escaping @Sendable (String) async throws -> PubkyProfile?
    ) {
        let labels = Dictionary(records.map { (Self.contactKey(for: $0), $0.label) }, uniquingKeysWith: { first, _ in first })
        if let running = profileRefresh, Set(running.labels.keys).isSuperset(of: labels.keys) {
            return
        }
        stopProfileRefresh()
        guard !labels.isEmpty else { return }

        profileRefreshCount += 1
        let refreshID = profileRefreshCount
        let lookups = Dictionary(uniqueKeysWithValues: labels.map { publicKey, label in
            let lookup = Task { [weak self] in
                let profile = try? await Self.resolveContactProfile(publicKey: publicKey, fetchRemoteProfile: fetchRemoteProfile)
                self?.finishRefreshLookup(of: publicKey, profile: profile?.withNameFallback(label), refreshID: refreshID)
            }
            return (publicKey, lookup)
        })
        let task = Task { [weak self] in
            for lookup in lookups.values {
                await lookup.value
            }
            self?.applyBatchedProfiles(of: refreshID)
            self?.finishProfileRefresh(refreshID)
        }
        profileRefresh = ContactProfileRefresh(id: refreshID, labels: labels, pendingKeys: Set(labels.keys), lookups: lookups, task: task)
    }

    /// Drops the result for a contact whose lookup a screen took over; the refresh leaves its own read of that contact
    /// running. Any other profile found joins the next batch.
    private func finishRefreshLookup(of publicKey: String, profile: PubkyProfile?, refreshID: Int) {
        guard profileRefresh?.id == refreshID, profileRefresh?.pendingKeys.remove(publicKey) != nil, let profile else { return }
        rememberResolvedProfile(profile, for: publicKey)
        profileRefresh?.batchedProfiles[publicKey] = profile
        guard profileRefresh?.batchFlush == nil else { return }
        profileRefresh?.batchFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.contactRefreshBatchWindow)
            guard !Task.isCancelled else { return }
            self?.applyBatchedProfiles(of: refreshID)
        }
    }

    /// Applies the profiles the refresh found since its last update. A batch of a refresh that was replaced or stopped,
    /// as by a reset, a sign-out or another owner's load, is dropped with it and never reaches the rows.
    private func applyBatchedProfiles(of refreshID: Int) {
        guard let refresh = profileRefresh, refresh.id == refreshID else { return }
        refresh.batchFlush?.cancel()
        profileRefresh?.batchFlush = nil
        profileRefresh?.batchedProfiles = [:]
        applyResolvedProfiles(refresh.batchedProfiles)
    }

    private func stopProfileRefresh() {
        profileRefresh?.cancel()
        profileRefresh = nil
    }

    /// Cancels the lookups of removed contacts, the running refresh's and any a screen started, so a lookup still waiting
    /// for a read slot never reads, and drops whatever they found. A removed contact can be added back with a newer profile
    /// before such a lookup returns.
    private func stopProfileLookups(for publicKeys: [String]) {
        for publicKey in publicKeys {
            let key = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
            profileRefresh?.lookups[key]?.cancel()
            profileRefresh?.pendingKeys.remove(key)
            profileRefresh?.batchedProfiles[key] = nil
            pendingProfileLookups.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func stopPendingProfileLookups() {
        pendingProfileLookups.values.forEach { $0.task.cancel() }
        pendingProfileLookups = [:]
    }

    private func finishProfileRefresh(_ refreshID: Int) {
        if profileRefresh?.id == refreshID {
            profileRefresh = nil
        }
    }

    /// Looks a saved contact's profile up on the interactive read lane while its row still shows only its saved label
    /// because the background refresh has not reached it, so a screen showing that contact does not wait behind bulk
    /// reads and an edit made there keeps the contact's avatar, bio and links. The lookup takes the contact over from the
    /// running background refresh, which then drops its own result for it, so that refresh cannot change the row under an
    /// edit. Returns at once for any other row, and joins a lookup already running for the contact. When the lookup fails,
    /// the row keeps its label. A profile the refresh already found for the contact but holds for its next batch is
    /// applied at once instead.
    func resolvePendingContactProfile(publicKey: String) async {
        await resolvePendingContactProfile(publicKey: publicKey, fetchRemoteProfile: remoteProfileLookup(on: .interactive))
    }

    func resolvePendingContactProfile(
        publicKey: String,
        fetchRemoteProfile: @escaping @Sendable (String) async throws -> PubkyProfile?
    ) async {
        guard let key = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        if let refresh = profileRefresh, refresh.batchedProfiles[key] != nil {
            applyBatchedProfiles(of: refresh.id)
        }
        if let lookup = pendingProfileLookups[key] {
            return await lookup.task.value
        }
        guard let refresh = profileRefresh,
              refresh.pendingKeys.contains(key),
              let label = refresh.labels[key],
              resolvedProfiles[key] == nil,
              Self.loadContactProfileOverrides()[key] == nil
        else { return }

        profileRefresh?.pendingKeys.remove(key)
        let lookupID = UUID()
        let lookup = Task { [weak self] in
            let profile = try? await Self.resolveContactProfile(publicKey: key, fetchRemoteProfile: fetchRemoteProfile)
            self?.finishPendingProfileLookup(lookupID, of: key, profile: profile?.withNameFallback(label))
        }
        pendingProfileLookups[key] = (lookupID, lookup)
        await lookup.value
    }

    /// Drops the result of a lookup that was ended, by removing the contact, a reset or another owner's load, before it
    /// reaches the cache or the rows.
    private func finishPendingProfileLookup(_ lookupID: UUID, of publicKey: String, profile: PubkyProfile?) {
        guard pendingProfileLookups[publicKey]?.id == lookupID else { return }
        pendingProfileLookups[publicKey] = nil
        if let profile {
            rememberResolvedProfile(profile, for: publicKey)
            applyResolvedProfiles([publicKey: profile])
        }
    }

    /// Replaces the rows of `profiles` in one sorted publish. A row the user edited keeps the edit, and when every row
    /// already shows its profile nothing is published.
    private func applyResolvedProfiles(_ profiles: [String: PubkyProfile]) {
        guard !profiles.isEmpty else { return }
        let overrides = Self.loadContactProfileOverrides()
        var refreshed = contacts
        var hasChanges = false
        for index in refreshed.indices {
            let publicKey = refreshed[index].publicKey
            guard let profile = profiles[publicKey],
                  overrides[publicKey] == nil,
                  !refreshed[index].profile.hasSameContent(as: profile)
            else { continue }
            refreshed[index] = PubkyContact(publicKey: publicKey, profile: profile)
            hasChanges = true
        }
        guard hasChanges else { return }

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
    /// or cache, and drops that owner's queued tag changes, which then stop without saving. The next change to the
    /// contacts is announced as a saved contacts change whatever keys it holds, as it belongs to another session.
    private func forgetResolvedProfiles(owner: String?) {
        announcedSavedContactKeys = nil
        resolvedProfilesGeneration += 1
        stopProfileRefresh()
        stopPendingProfileLookups()
        tagChanges = [:]
        resolvedProfiles = [:]
        resolvedProfilesOwner = owner
    }

    /// A placeholder is not remembered, so a contact whose lookup found nothing is still looked up on the next load.
    private func rememberResolvedProfile(_ profile: PubkyProfile, for publicKey: String) {
        guard !profile.isPlaceholder, let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) else { return }
        resolvedProfiles[normalizedKey] = ResolvedContactProfile(profile: profile, resolvedAt: currentDate())
    }

    #if DEBUG
        func waitForProfileRefreshForTesting() async {
            await profileRefresh?.task.value
        }

        var batchedProfileCountForTesting: Int {
            profileRefresh?.batchedProfiles.count ?? 0
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

        _ = try await PubkyService.saveContact(
            publicKey: prefixedKey,
            label: profile.name,
            restorePrivateConnection: true
        )

        Logger.info("Added contact \(PubkyPublicKeyFormat.redacted(prefixedKey))", context: "ContactsManager")

        rememberResolvedProfile(profile, for: prefixedKey)
        let contact = PubkyContact(publicKey: prefixedKey, profile: profile)
        contacts.append(contact)
        contacts.sort(by: Self.isOrderedByName)
    }

    func refreshContactLink(publicKey: String, wallet: WalletViewModel) async {
        guard let prefixedKey = PubkyPublicKeyFormat.normalized(publicKey),
              let contact = contacts.first(where: { PubkyPublicKeyFormat.matches($0.publicKey, prefixedKey) })
        else { return }

        do {
            let identity = await PubkyService.currentPublicKey()
            _ = try await PubkyService.saveContact(publicKey: prefixedKey, label: contact.profile.name, expectedIdentity: identity)
            await PrivatePaykitService.shared.startExplicitContactLink(publicKey: prefixedKey, expectedIdentity: identity, wallet: wallet)
        } catch is CancellationError {
            return
        } catch {
            Logger.warn(
                "Failed to refresh contact link for \(PubkyPublicKeyFormat.redacted(prefixedKey)): \(error)",
                context: "ContactsManager"
            )
        }
    }

    // MARK: - Import Contacts

    /// Remembers the profiles it saves for this session, so the Contacts list shows them at once rather than only their
    /// saved labels. A placeholder for a follow whose lookup failed is not remembered, so that profile is still looked up.
    /// An import outlives its screens, so a reset or another identity's load while it runs, such as after a sign-out,
    /// drops its result quietly: it adds nothing to the next session's list and reports no error.
    func importContacts(
        contacts selected: [PubkyContact],
        saveContacts: ([ContactUpdate], String?) async throws -> Void = { updates, expectedIdentity in
            _ = try await PubkyService.saveContacts(updates: updates, expectedIdentity: expectedIdentity)
        }
    ) async throws {
        let profilesGeneration = resolvedProfilesGeneration
        let expectedIdentity = resolvedProfilesOwner
        var existingKeys = Set(contacts.map(\.publicKey))
        let imported = selected.filter { existingKeys.insert($0.publicKey).inserted }
        try Task.checkCancellation()
        guard !imported.isEmpty else { return }

        do {
            try await saveContacts(imported.map { ContactUpdate(publicKey: $0.publicKey, label: $0.displayName) }, expectedIdentity)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard profilesGeneration == resolvedProfilesGeneration else { return }
            throw error
        }

        try Task.checkCancellation()
        guard profilesGeneration == resolvedProfilesGeneration else {
            Logger.info("Discarded a contact import that a reset overtook", context: "ContactsManager")
            return
        }
        for contact in imported {
            rememberResolvedProfile(contact.profile, for: contact.publicKey)
        }
        let currentKeys = Set(contacts.map(\.publicKey))
        contacts = (contacts + imported.filter { !currentKeys.contains($0.publicKey) }).sorted(by: Self.isOrderedByName)
        Logger.info("Imported \(imported.count) new contacts", context: "ContactsManager")
    }

    // MARK: - Update Contact

    /// True while work started now still belongs to its session: `isSessionCurrent` still holds and no reset or other
    /// owner's load has run since.
    private func sessionCheck(_ isSessionCurrent: @escaping @MainActor () -> Bool) -> @MainActor () -> Bool {
        let generation = resolvedProfilesGeneration
        return { [weak self] in
            self?.resolvedProfilesGeneration == generation && isSessionCurrent()
        }
    }

    /// Saves an edit made on a contact's edit screen once the lookup of a profile the row is still waiting for is done, so
    /// the save keeps the bio, links and avatar that lookup finds. `makeEdit` runs only then and returns the fields to
    /// save, such as by filling the form again from the row and uploading a new avatar. Returns the saved profile.
    ///
    /// An edit belongs to the session Save was tapped in, bound before it waits for anything. Once `isSessionCurrent` is
    /// false, or a reset or another owner's load has run, it stops quietly and returns nil: `makeEdit` does not run, or its
    /// result or error is dropped, and it saves nothing, writes no local override and reports no error. The lookup or
    /// upload it waits for can finish after a sign-out, and the next identity may have saved a contact with the same key.
    /// `expectedIdentity` is the pubky signed in when Save was tapped. The save is refused unless it is still signed in
    /// when the save runs, and that refusal, or `makeEdit` throwing `identityChanged` for an avatar upload refused the same
    /// way, is dropped just as quietly.
    func saveContactEdit(
        publicKey: String,
        expectedIdentity: String,
        isSessionCurrent: @escaping @MainActor () -> Bool,
        makeEdit: @MainActor () async throws -> ContactEdit
    ) async throws -> PubkyProfile? {
        let isCurrent = sessionCheck(isSessionCurrent)
        await resolvePendingContactProfile(publicKey: publicKey)
        guard isCurrent() else { return nil }
        let edit: ContactEdit
        do {
            edit = try await makeEdit()
        } catch PubkyServiceError.identityChanged {
            Logger.info("Dropped a contact edit whose avatar upload was for an identity that is no longer signed in", context: "ContactsManager")
            return nil
        } catch {
            guard isCurrent() else { return nil }
            throw error
        }
        return try await updateContact(
            publicKey: publicKey,
            name: edit.name,
            bio: edit.bio,
            imageUrl: edit.imageUrl,
            links: edit.links,
            tags: edit.tags,
            expectedIdentity: expectedIdentity,
            isCurrent: isCurrent
        )
    }

    /// `isCurrent` is checked right before the save and again once it returns, with nothing suspending between that check
    /// and the writes after it. Sign-out clears the local overrides, so a save that lands after the session changed must
    /// not write one back, and its error, if any, belongs to a session the user has left. Returns the saved profile, or
    /// nil when the save was dropped.
    ///
    /// The session can still change after that first check, while the save waits for the SDK. So the SDK checks that
    /// `expectedIdentity` is still signed in, in the same locked operation as its write, and otherwise writes nothing and
    /// throws `identityChanged`, which is dropped like any other save `isCurrent` no longer holds for.
    @discardableResult
    private func updateContact(
        publicKey: String,
        name: String,
        bio: String,
        imageUrl: String?,
        links: [PubkyProfileLink],
        tags: [String],
        expectedIdentity: String,
        isCurrent: @MainActor () -> Bool
    ) async throws -> PubkyProfile? {
        let prefixedKey = ensurePubkyPrefix(publicKey)

        let contactData = PubkyProfileData(
            name: name,
            bio: bio,
            image: imageUrl,
            links: links.map { PubkyProfileData.Link(label: $0.label, url: $0.url) },
            tags: tags
        )

        guard isCurrent() else { return nil }
        let saveContactLabel = saveContactLabel
        do {
            try await Task.detached {
                try await saveContactLabel(prefixedKey, name, expectedIdentity)
            }.value
        } catch PubkyServiceError.identityChanged {
            Logger.info("Dropped a contact update for an identity that is no longer signed in", context: "ContactsManager")
            return nil
        } catch {
            guard isCurrent() else { return nil }
            throw error
        }
        guard isCurrent() else {
            Logger.info("Dropped a contact update that a session change overtook", context: "ContactsManager")
            return nil
        }
        Self.upsertContactProfileOverride(publicKey: prefixedKey, data: contactData)

        let updatedProfile = contactData.toProfile(publicKey: prefixedKey)
        if let index = contacts.firstIndex(where: { $0.publicKey == prefixedKey }) {
            contacts[index] = PubkyContact(publicKey: prefixedKey, profile: updatedProfile)
            contacts.sort(by: Self.isOrderedByName)
        }

        Logger.info("Updated contact \(PubkyPublicKeyFormat.redacted(prefixedKey))", context: "ContactsManager")
        return updatedProfile
    }

    /// Saves a tag change made on a contact's screen over the contact's latest profile once the changes queued before it
    /// for that contact are done, so each one applies over the tags the last one saved. It first waits for the lookup of a
    /// profile the row is still waiting for, so the save keeps the bio, links and avatar that lookup finds. `shownProfile`
    /// stands in when the contact is no longer listed. A failed change does not stop the ones queued after it.
    ///
    /// A change belongs to the session it was queued in. Once `isSessionCurrent` is false, or a reset or another owner's
    /// load has run, it stops quietly: it saves nothing, writes no local override and reports no error. A lookup it waits
    /// for can still finish after a sign-out, and the next identity may have saved a contact with the same key.
    /// `expectedIdentity` is the pubky signed in when the change was queued. The save is refused unless it is still signed
    /// in when the save runs, and that refusal is dropped just as quietly.
    func updateContactTags(
        publicKey: String,
        shownProfile: PubkyProfile,
        expectedIdentity: String,
        isSessionCurrent: @escaping @MainActor () -> Bool,
        transform: @escaping ([String]) -> [String]
    ) -> Task<Void, Error> {
        let key = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
        let isCurrent = sessionCheck(isSessionCurrent)
        let previousChange = tagChanges[key]
        let change = Task {
            _ = await previousChange?.result
            guard isCurrent() else { return }
            await resolvePendingContactProfile(publicKey: publicKey)
            guard isCurrent() else { return }
            let latest = contacts.first(where: { $0.publicKey == publicKey })?.profile ?? shownProfile
            try await updateContact(
                publicKey: publicKey,
                name: latest.name,
                bio: latest.bio,
                imageUrl: latest.imageUrl,
                links: latest.links,
                tags: transform(latest.tags),
                expectedIdentity: expectedIdentity,
                isCurrent: isCurrent
            )
        }
        tagChanges[key] = change
        return change
    }

    // MARK: - Delete Contact

    /// Also stops the profile lookups of the contact, the running refresh's and any a screen started.
    func removeContact(publicKey: String) async throws {
        let prefixedKey = ensurePubkyPrefix(publicKey)
        let removeContactRecord = removeContactRecord

        try await Task.detached {
            try await removeContactRecord(prefixedKey)
        }.value
        contacts.removeAll { $0.publicKey == prefixedKey }
        stopProfileLookups(for: [prefixedKey])
        Self.removeContactProfileOverride(publicKey: prefixedKey)
        await forgetRemovedContacts([prefixedKey])

        Logger.info("Removed contact \(PubkyPublicKeyFormat.redacted(prefixedKey))", context: "ContactsManager")
    }

    /// Stops the running profile refresh and every lookup a screen started first: every contact is going, their reads would
    /// only compete with the ones removing them, and a contact can be added back with a newer profile before one returns.
    func deleteAllContacts() async throws {
        stopProfileRefresh()
        stopPendingProfileLookups()
        let contactRecords = contactRecords
        let removeContactRecords = removeContactRecords
        let records: [ContactRecord]
        do {
            records = try await Task.detached {
                try await contactRecords()
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

        let keys = records.compactMap { PubkyPublicKeyFormat.normalized($0.publicKey) }
        let removed = try await Task.detached { try await removeContactRecords(keys) }.value
        let deletedKeys = Set(removed.compactMap { PubkyPublicKeyFormat.normalized($0.publicKey) })
        await forgetRemovedContacts(Array(deletedKeys))
        Self.removeContactProfileOverrides(publicKeys: deletedKeys)
        contacts.removeAll { deletedKeys.contains($0.publicKey) }
        guard deletedKeys.isSuperset(of: keys) else {
            throw PrivatePaykitError.privateUnavailable
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

    private struct ResolvedContactProfile {
        let profile: PubkyProfile
        let resolvedAt: Date

        func isFresh(at now: Date) -> Bool {
            let age = now.timeIntervalSince(resolvedAt)
            return age >= 0 && age < ContactsManager.contactProfileFreshness
        }
    }

    /// A background refresh of saved contacts' profiles. `labels` maps each contact it looks up to its saved label, and
    /// `pendingKeys` holds those whose lookup has not finished, that no screen's lookup has taken over and that were not
    /// removed, whose rows may still show only that label.
    private struct ContactProfileRefresh {
        let id: Int
        let labels: [String: String?]
        var pendingKeys: Set<String>
        /// One lookup per contact, so removing a contact can cancel its lookup alone.
        let lookups: [String: Task<Void, Never>]
        /// Finishes once every lookup has.
        let task: Task<Void, Never>
        /// Profiles found and not applied to the rows yet, applied together once `batchFlush` fires or the refresh ends.
        var batchedProfiles: [String: PubkyProfile] = [:]
        var batchFlush: Task<Void, Never>?

        func cancel() {
            lookups.values.forEach { $0.cancel() }
            task.cancel()
            batchFlush?.cancel()
        }
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
        removeContactProfileOverrides(publicKeys: [prefixedKey])
    }

    private nonisolated static func removeContactProfileOverrides(publicKeys: Set<String>) {
        guard !publicKeys.isEmpty else { return }
        saveContactProfileOverrides(loadContactProfileOverrides().filter { !publicKeys.contains($0.key) })
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

private extension PubkyProfile {
    /// Compares everything a contact's row and screen show. A `PubkyProfileLink` gets a new id each time one is made, so
    /// links compare by label and URL.
    func hasSameContent(as other: PubkyProfile) -> Bool {
        publicKey == other.publicKey && name == other.name && bio == other.bio && imageUrl == other.imageUrl
            && tags == other.tags && status == other.status
            && links.map(\.label) == other.links.map(\.label) && links.map(\.url) == other.links.map(\.url)
    }
}
