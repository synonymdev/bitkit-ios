import Foundation
import Paykit

enum PubkyAppProfileError: LocalizedError {
    /// The pubky.app profile changed since Bitkit loaded it, so the save was not applied.
    case changedElsewhere
    /// The other fields were saved at `revision`, but the tag change was not.
    case tagsNotSaved(revision: String)

    var errorDescription: String? {
        switch self {
        case .changedElsewhere: t("profile__edit_changed_error")
        case .tagsNotSaved: t("profile__edit_tags_error")
        }
    }
}

/// Orders profile writes with profile deletion per identity. A deletion refuses every write until it ends and every
/// later write of a load or save that started before it, and waits for the writes already under way.
struct ProfileWriteGate {
    private var generations: [String: Int] = [:]
    private var deleting: Set<String> = []
    private var writesInFlight: [String: Int] = [:]
    private var writesSettled: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// The generation a load or save starts at, which its writes pass to `admit`.
    func generation(_ key: String) -> Int {
        generations[key, default: 0]
    }

    /// Admits a write; pair each admitted write with `end`.
    mutating func admit(_ key: String, generation: Int) throws {
        guard !deleting.contains(key), generations[key, default: 0] == generation else {
            throw PubkyServiceError.identityChanged
        }
        writesInFlight[key, default: 0] += 1
    }

    mutating func end(_ key: String) {
        let remaining = writesInFlight[key, default: 1] - 1
        guard remaining == 0 else {
            writesInFlight[key] = remaining
            return
        }
        writesInFlight[key] = nil
        writesSettled.removeValue(forKey: key)?.forEach { $0.resume() }
    }

    /// Starts a deletion, which then waits until `hasWritesInFlight` is false (`onWritesSettled`) and ends with
    /// `endDeletion`.
    mutating func beginDeletion(_ key: String) {
        generations[key, default: 0] += 1
        deleting.insert(key)
    }

    mutating func endDeletion(_ key: String) {
        deleting.remove(key)
    }

    func hasWritesInFlight(_ key: String) -> Bool {
        writesInFlight[key, default: 0] > 0
    }

    mutating func onWritesSettled(_ key: String, _ continuation: CheckedContinuation<Void, Never>) {
        writesSettled[key, default: []].append(continuation)
    }
}

/// The identity's own pubky.app profile, which Bitkit reads and edits directly. A save writes only the fields that differ
/// from the loaded profile, at the revision it was loaded at, so an edit made in pubky.app is never overwritten. Profile
/// tags have no pubky.app field: they live in Bitkit's public Paykit profile copy, which follows each save for other
/// Paykit apps.
actor PubkyAppProfileStore {
    static let shared = PubkyAppProfileStore()

    // pubky.app profile limits (pubky-app-specs), applied when moving a Bitkit profile there.
    private static let nameMaxLength = 50
    private static let bioMaxLength = 160
    private static let linksMaxCount = 5
    private static let linkTitleMaxLength = 100
    private static let linkUrlMaxLength = 300
    private static let avatarMaxBytes: UInt64 = 5 * 1024 * 1024

    private static let pubkyAppProfileOwnersKey = "pubky_app_profile_owners"

    private static var pubkyAppProfileOwners: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: pubkyAppProfileOwnersKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: pubkyAppProfileOwnersKey) }
    }

    private static let pubkyAppAvatarPendingKey = "pubky_app_avatar_pending"

    /// Identities whose Bitkit avatar is still to be moved to pubky.app, retried on each load.
    private static var pubkyAppAvatarPending: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: pubkyAppAvatarPendingKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: pubkyAppAvatarPendingKey) }
    }

    /// The profile each recently seen revision held, so a save diffs against what its form was built from.
    private var profilesByRevision: [String: [String: PubkyProfile]] = [:]
    private var revisionOrder: [String: [String]] = [:]
    private var savedProfiles: [UUID: PubkyProfile] = [:]
    private var pendingAvatarUris: [String: String] = [:]
    private var tagsUnavailable: Set<String> = []
    private var writeGate = ProfileWriteGate()
    private static let rememberedRevisions = 8

    /// Loads the profile. An identity that is signed in and has only a Bitkit profile moves it to pubky.app first; until
    /// that move happens (signed out, or it cannot finish) the Bitkit profile is shown and the next save creates the
    /// pubky.app profile.
    func load(publicKey: String) async throws -> PubkyProfile {
        let key = Self.normalized(publicKey)
        let generation = writeGate.generation(key)
        let paykitData: PubkyProfileData?
        var paykitReadError: Error?
        do {
            paykitData = try await PubkyService.fetchPaykitProfile(publicKey: key).map {
                PubkyProfileData.from(paykitProfile: $0.profile)
            }
            tagsUnavailable.remove(key)
        } catch {
            Logger.warn("Failed to read Bitkit profile copy: \(error)", context: "PubkyAppProfileStore")
            paykitData = nil
            paykitReadError = error
            tagsUnavailable.insert(key)
        }
        let fetched = try await PubkyService.fetchPubkyProfileWithRevision(publicKey: key)
        var snapshot = fetched
        let isSignedIn = await Self.isSignedIn(key)
        // Once a pubky.app profile was seen, one missing there was deleted there, so it is not moved back from Bitkit.
        let hadPubkyAppProfile = Self.pubkyAppProfileOwners.contains(key)
        if fetched == nil, isSignedIn, !hadPubkyAppProfile, let paykitData {
            snapshot = await migrate(paykitData, publicKey: key, generation: generation)
        } else if let current = fetched, isSignedIn, Self.pubkyAppAvatarPending.contains(key), let uri = paykitData?.image {
            if current.profile.image == nil, Self.isPaykitStorage(uri) {
                snapshot = await moveAvatar(uri, onto: current, publicKey: key, generation: generation) ?? current
            } else {
                // An avatar set on pubky.app meanwhile wins over the one still to move, and only a Bitkit avatar on Paykit
                // storage is moved.
                Self.pubkyAppAvatarPending.remove(key)
            }
        }
        guard let snapshot else {
            if !hadPubkyAppProfile, let paykitData {
                return paykitData.toProfile(publicKey: key)
            }
            if let paykitReadError {
                throw paykitReadError
            }
            throw PubkyServiceError.profileNotFound
        }
        if !hadPubkyAppProfile {
            Self.pubkyAppProfileOwners.insert(key)
        }
        let avatarPending = Self.pubkyAppAvatarPending.contains(key)
        pendingAvatarUris[key] = avatarPending ? paykitData?.image : nil
        var profile = Self.profile(publicKey: key, snapshot: snapshot, tags: paykitData?.tags ?? [])
        if avatarPending, let uri = paykitData?.image {
            profile = profile.withImageUrl(uri)
        }
        remember(profile, for: key)
        if isSignedIn, !avatarPending, let paykitData, paykitData != PubkyProfileData.from(profile: profile) {
            try? await publishCopy(profile, expectedIdentity: key, generation: generation)
        }
        return profile
    }

    /// Saves `data` for `expectedIdentity`, or the signed-in identity. A save carrying the revision its form was built
    /// from writes only the fields that differ from that revision; one without a revision creates the profile, and is
    /// refused when a pubky.app profile exists by then. Throws `changedElsewhere` after reloading when pubky.app changed
    /// the profile since that revision.
    func save(_ data: PubkyProfileData, expectedIdentity: String?) async throws {
        let data = Self.normalized(data)
        let key = try await Self.identity(expectedIdentity)
        let generation = writeGate.generation(key)
        let copyUnread = tagsUnavailable.contains(key)
        var base: PubkyProfile?
        if let baseRevision = data.baseRevision {
            guard let known = profilesByRevision[key]?[baseRevision] else {
                _ = try? await load(publicKey: key)
                throw PubkyAppProfileError.changedElsewhere
            }
            base = known
        } else if try await PubkyService.fetchPubkyProfileWithRevision(publicKey: key) != nil {
            _ = try? await load(publicKey: key)
            throw PubkyAppProfileError.changedElsewhere
        }
        var update = Self.update(from: base == nil ? Self.fitted(data) : data, base: base)
        // A Bitkit avatar still on Paykit storage is moved by a later load rather than written to pubky.app as is.
        let paykitAvatar = data.image.flatMap { Self.isPaykitStorage($0) ? $0 : nil }
        if let image = update.image, Self.isPaykitStorage(image) {
            update.image = nil
        }
        let snapshot: Paykit.PubkyProfileSnapshot
        do {
            snapshot = try await admitted(key, generation: generation) {
                try await withPubkyAppScope {
                    try await PubkyService.publishPubkyProfile(update, expectedRevision: data.baseRevision, expectedIdentity: key)
                }
            }
        } catch PaykitError.ConcurrentUpdate {
            _ = try? await load(publicKey: key)
            throw PubkyAppProfileError.changedElsewhere
        }
        Self.pubkyAppProfileOwners.insert(key)
        let previousTags = base?.tags ?? []
        let stored = await storedCopy(for: key)
        if let paykitAvatar, snapshot.profile.image == nil {
            Self.pubkyAppAvatarPending.insert(key)
            pendingAvatarUris[key] = paykitAvatar
        } else if snapshot.profile.image != nil || !(copyUnread && Self.pubkyAppAvatarPending.contains(key)) {
            Self.pubkyAppAvatarPending.remove(key)
            pendingAvatarUris[key] = nil
        } else if let uri = stored?.image, Self.isPaykitStorage(uri) {
            // The form could not show the avatar still to move, as the copy was unread; it stays pending.
            pendingAvatarUris[key] = uri
        }
        let tags = stored.map { Self.tags(data.tags, keeping: $0.tags) }
        var profile = Self.profile(publicKey: key, snapshot: snapshot, tags: tags ?? previousTags)
        if Self.pubkyAppAvatarPending.contains(key), let uri = pendingAvatarUris[key] {
            profile = profile.withImageUrl(uri)
        }
        // Tags live only in the Paykit copy, so a tag change it does not take is reported, and the remembered base keeps
        // the tags it last stored so a retry is reported again.
        var copyError: Error?
        if tags != nil {
            do {
                try await publishCopy(profile, expectedIdentity: key, generation: generation)
                tagsUnavailable.remove(key)
            } catch {
                copyError = error
            }
        }
        let storedProfile = tags != nil && copyError == nil ? profile : profile.withTags(previousTags)
        remember(storedProfile, for: key)
        if let saveId = data.saveId {
            savedProfiles[saveId] = storedProfile
        }
        if tags == nil || copyError != nil, data.tags != previousTags {
            if let copyError {
                Logger.warn("Saved the profile without its tag change: \(copyError)", context: "PubkyAppProfileStore")
            }
            throw PubkyAppProfileError.tagsNotSaved(revision: snapshot.revision)
        }
    }

    /// The profile a save stored, by the id its data carried; read once.
    func savedProfile(saveId: UUID) -> PubkyProfile? {
        savedProfiles.removeValue(forKey: saveId)
    }

    private func remember(_ profile: PubkyProfile, for key: String) {
        guard let revision = profile.revision else { return }
        profilesByRevision[key, default: [:]][revision] = profile
        var order = revisionOrder[key, default: []].filter { $0 != revision } + [revision]
        while order.count > Self.rememberedRevisions {
            profilesByRevision[key]?[order.removeFirst()] = nil
        }
        revisionOrder[key] = order
    }

    /// What a save keeps from the Paykit copy after the last load could not read it, as the form then lacked its tags
    /// and the avatar still to move: empty when that load read it, nil while it still cannot be read.
    private func storedCopy(for key: String) async -> (tags: [String]?, image: String?)? {
        guard tagsUnavailable.contains(key) else { return (nil, nil) }
        do {
            let data = try await PubkyService.fetchPaykitProfile(publicKey: key).map { PubkyProfileData.from(paykitProfile: $0.profile) }
            return (data?.tags ?? [], data?.image)
        } catch {
            return nil
        }
    }

    /// The form's tags, plus the stored ones it could not show after a failed copy read.
    private static func tags(_ tags: [String], keeping storedTags: [String]?) -> [String] {
        guard let storedTags else { return tags }
        return storedTags + tags.filter { !storedTags.contains($0) }
    }

    /// Uploads a JPEG avatar as a pubky.app blob and file and returns the file URI for the profile image.
    func uploadAvatar(_ jpegData: Data, expectedIdentity: String?) async throws -> String {
        let key = try await Self.identity(expectedIdentity)
        return try await withPubkyAppScope {
            try await PubkyService.uploadPubkyAppAvatar(bytes: jpegData, contentType: "image/jpeg", expectedIdentity: key)
        }
    }

    /// A Bitkit profile fitted to pubky.app's limits, for a profile written there without a base: text on one line and
    /// cut to length, and only links pubky.app can hold, at most five.
    static func fitted(_ data: PubkyProfileData) -> PubkyProfileData {
        var data = data
        data.name = prefix(singleLine(data.name), nameMaxLength)
        data.bio = prefix(singleLine(data.bio), bioMaxLength)
        data.links = Array(
            data.links
                .compactMap { link -> PubkyProfileData.Link? in
                    let title = singleLine(link.label)
                    guard !title.isEmpty, let url = linkUrl(link.url) else { return nil }
                    return PubkyProfileData.Link(label: prefix(title, linkTitleMaxLength), url: url)
                }
                .prefix(linksMaxCount)
        )
        return data
    }

    private func migrate(_ data: PubkyProfileData, publicKey: String, generation: Int) async -> Paykit.PubkyProfileSnapshot? {
        let fitted = Self.fitted(data)
        // An avatar already on pubky.app is kept as is; one on Paykit storage is moved below.
        let keptImage = data.image.flatMap { Self.isPubkyAppFile($0) ? $0 : nil }
        let update = Paykit.PubkyProfileUpdate(
            name: fitted.name,
            bio: fitted.bio,
            image: keptImage,
            links: fitted.links.map { Paykit.PubkyProfileLink(title: $0.label, url: $0.url) }
        )
        let snapshot: Paykit.PubkyProfileSnapshot
        do {
            snapshot = try await admitted(publicKey, generation: generation) {
                try await withPubkyAppScope {
                    try await PubkyService.publishPubkyProfile(update, expectedRevision: nil, expectedIdentity: publicKey)
                }
            }
            Logger.info("Moved Bitkit profile to pubky.app", context: "PubkyAppProfileStore")
        } catch {
            Logger.warn("Failed to move Bitkit profile to pubky.app: \(error)", context: "PubkyAppProfileStore")
            return nil
        }
        guard let uri = data.image, Self.isPaykitStorage(uri) else { return snapshot }
        return await moveAvatar(uri, onto: snapshot, publicKey: publicKey, generation: generation) ?? snapshot
    }

    private func moveAvatar(
        _ uri: String,
        onto snapshot: Paykit.PubkyProfileSnapshot,
        publicKey: String,
        generation: Int
    ) async -> Paykit.PubkyProfileSnapshot? {
        do {
            let moved = try await admitted(publicKey, generation: generation) { try await withPubkyAppScope {
                let bytes = try await PubkyService.fetchFile(uri: uri, maxBytes: Self.avatarMaxBytes)
                let image = try await PubkyService.uploadPubkyAppAvatar(
                    bytes: bytes,
                    contentType: Self.contentType(for: uri),
                    expectedIdentity: publicKey
                )
                return try await PubkyService.publishPubkyProfile(
                    Paykit.PubkyProfileUpdate(name: nil, bio: nil, image: image, links: nil),
                    expectedRevision: snapshot.revision,
                    expectedIdentity: publicKey
                )
            } }
            Self.pubkyAppAvatarPending.remove(publicKey)
            return moved
        } catch {
            Logger.warn("Failed to move avatar to pubky.app: \(error)", context: "PubkyAppProfileStore")
            Self.pubkyAppAvatarPending.insert(publicKey)
            return nil
        }
    }

    /// Deletes the identity's Bitkit profile copy and, unless `keepPubkyAppProfile`, its pubky.app profile. Writes already
    /// under way finish first, and no load or save writes while it runs or, when it started before, after it, so
    /// neither profile is written back once deleted.
    func deleteProfile(expectedIdentity: String, keepPubkyAppProfile: Bool) async throws {
        let key = Self.normalized(expectedIdentity)
        writeGate.beginDeletion(key)
        defer { writeGate.endDeletion(key) }
        if writeGate.hasWritesInFlight(key) {
            await withCheckedContinuation { writeGate.onWritesSettled(key, $0) }
        }
        if !keepPubkyAppProfile, let revision = try await PubkyService.fetchPubkyProfileWithRevision(publicKey: key)?.revision {
            try await withPubkyAppScope {
                try await PubkyService.deletePubkyProfile(expectedRevision: revision, expectedIdentity: key)
            }
            profilesByRevision[key] = nil
            revisionOrder[key] = nil
        }
        try await PubkyService.deletePaykitProfile(expectedIdentity: key)
    }

    /// Runs a write of a load or save that started at `generation`, refused during a deletion or after one that began
    /// since.
    private func admitted<T>(_ key: String, generation: Int, _ write: () async throws -> T) async throws -> T {
        try writeGate.admit(key, generation: generation)
        defer { writeGate.end(key) }
        return try await write()
    }

    private func publishCopy(_ profile: PubkyProfile, expectedIdentity: String, generation: Int) async throws {
        do {
            try await admitted(expectedIdentity, generation: generation) {
                try await PubkyService.publishPaykitProfile(
                    PubkyProfileData.from(profile: profile).toPaykitProfile(),
                    expectedIdentity: expectedIdentity
                )
            }
        } catch {
            Logger.warn("Failed to update Bitkit profile copy: \(error)", context: "PubkyAppProfileStore")
            throw error
        }
    }

    /// Sessions from builds before pubky.app profile writes lack its scope; sign in again once to gain it.
    private func withPubkyAppScope<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as PaykitError {
            guard case .Identity = error, let secretKeyHex = PubkyProfileManager.activeSecretKeyHex() else { throw error }
            _ = try await PubkyService.signIn(secretKeyHex: secretKeyHex)
            return try await operation()
        }
    }

    static func update(from data: PubkyProfileData, base: PubkyProfile?) -> Paykit.PubkyProfileUpdate {
        let links = data.links.map { Paykit.PubkyProfileLink(title: $0.label, url: $0.url) }
        guard let base else {
            return Paykit.PubkyProfileUpdate(name: data.name, bio: data.bio, image: data.image, links: links)
        }
        let baseLinks = base.links.map { PubkyProfileData.Link(label: $0.label, url: $0.url) }
        return Paykit.PubkyProfileUpdate(
            name: data.name == base.name ? nil : data.name,
            bio: data.bio == base.bio ? nil : data.bio,
            // An empty image removes it.
            image: data.image == base.imageUrl ? nil : data.image ?? "",
            links: data.links == baseLinks ? nil : links
        )
    }

    private static func profile(publicKey: String, snapshot: Paykit.PubkyProfileSnapshot, tags: [String]) -> PubkyProfile {
        let profile = PubkyProfile(publicKey: publicKey, pubkyProfile: snapshot.profile)
        var result = PubkyProfile(
            publicKey: publicKey,
            name: profile.name,
            bio: profile.bio,
            imageUrl: profile.imageUrl,
            links: profile.links,
            tags: tags,
            status: profile.status
        )
        result.revision = snapshot.revision
        return result
    }

    /// pubky.app keeps profile text on one line and links as full URLs.
    private static func normalized(_ data: PubkyProfileData) -> PubkyProfileData {
        var data = data
        data.name = singleLine(data.name)
        data.bio = singleLine(data.bio)
        data.links = data.links.map { PubkyProfileData.Link(label: singleLine($0.label), url: linkUrl($0.url) ?? $0.url) }
        return data
    }

    static func singleLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncates by Unicode scalars, as pubky.app counts them.
    private static func prefix(_ text: String, _ maxScalars: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxScalars)))
    }

    /// Bitkit accepted links without a scheme (a site, an email address, a phone number); pubky.app needs full URLs.
    /// Free text that is none of these is not a link pubky.app can hold.
    static func linkUrl(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) || isPhoneNumber(value) else { return nil }
        let url: String
        if URL(string: value)?.scheme != nil, !isPhoneNumber(value) {
            url = value
        } else if isEmailAddress(value) {
            url = "mailto:\(value)"
        } else if isPhoneNumber(value) {
            url = "tel:\(value.filter { !" -().".contains($0) })"
        } else if value.contains("."), !value.hasPrefix(".") {
            url = "https://\(value)"
        } else {
            return nil
        }
        guard url.unicodeScalars.count <= linkUrlMaxLength, let parsed = URL(string: url), hasValidHost(parsed) else { return nil }
        return url
    }

    /// Paykit's URL parser reads a web URL's host that ends in an all-digit label as an IPv4 address (one to four
    /// numbers, as in `127.1`) and rejects it when it is not one; other schemes keep such hosts as they are.
    private static func hasValidHost(_ url: URL) -> Bool {
        guard ["http", "https", "ws", "wss", "ftp"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, let last = host.split(separator: ".").last, last.allSatisfy(\.isNumber)
        else { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map { UInt64($0) }
        guard (1 ... 4).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return false }
        let numbers = parts.compactMap { $0 }
        let lastLimit = (UInt64(1) << (8 * UInt64(5 - numbers.count))) - 1
        return numbers.dropLast().allSatisfy { $0 <= 255 } && numbers[numbers.count - 1] <= lastLimit
    }

    private static func isEmailAddress(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !value.contains("/")
    }

    private static func isPhoneNumber(_ value: String) -> Bool {
        let digits = value.filter(\.isNumber).count
        return value.hasPrefix("+") || digits >= 7
            ? value.allSatisfy { "+0123456789 -().".contains($0) } && digits >= 5 && !value.dropFirst().contains("+")
            && value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil
            && value.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) == nil
            : false
    }

    private static func isPaykitStorage(_ uri: String) -> Bool {
        uri.contains("/pub/paykit/")
    }

    private static func isPubkyAppFile(_ uri: String) -> Bool {
        uri.contains("/pub/pubky.app/files/") && uri.unicodeScalars.count <= linkUrlMaxLength
    }

    private static func identity(_ expectedIdentity: String?) async throws -> String {
        if let expectedIdentity {
            return normalized(expectedIdentity)
        }
        guard let current = await PubkyService.currentPublicKey() else { throw PubkyServiceError.sessionNotActive }
        return normalized(current)
    }

    private static func isSignedIn(_ publicKey: String) async -> Bool {
        guard let current = await PubkyService.currentPublicKey() else { return false }
        return PubkyPublicKeyFormat.matches(current, publicKey)
    }

    private static func normalized(_ publicKey: String) -> String {
        PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
    }

    private static func contentType(for uri: String) -> String {
        switch uri.split(separator: ".").last?.lowercased() {
        case "png": "image/png"
        case "webp": "image/webp"
        case "gif": "image/gif"
        default: "image/jpeg"
        }
    }
}
