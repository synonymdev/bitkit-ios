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
    private static let rememberedRevisions = 8

    /// Loads the profile. An identity that is signed in and has only a Bitkit profile moves it to pubky.app first; until
    /// that move happens (signed out, or it cannot finish) the Bitkit profile is shown and the next save creates the
    /// pubky.app profile.
    func load(publicKey: String) async throws -> PubkyProfile {
        let key = Self.normalized(publicKey)
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
            snapshot = await migrate(paykitData, publicKey: key)
        } else if let current = fetched, isSignedIn, Self.pubkyAppAvatarPending.contains(key), let uri = paykitData?.image {
            if current.profile.image == nil, Self.isPaykitStorage(uri) {
                snapshot = await moveAvatar(uri, onto: current, publicKey: key) ?? current
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
            try? await publishCopy(profile, expectedIdentity: key)
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
        var update = Self.update(from: data, base: base)
        // A Bitkit avatar still on Paykit storage is moved by a later load rather than written to pubky.app as is.
        let paykitAvatar = data.image.flatMap { Self.isPaykitStorage($0) ? $0 : nil }
        if let image = update.image, Self.isPaykitStorage(image) {
            update.image = nil
        }
        let snapshot: Paykit.PubkyProfileSnapshot
        do {
            snapshot = try await withPubkyAppScope {
                try await PubkyService.publishPubkyProfile(update, expectedRevision: data.baseRevision, expectedIdentity: key)
            }
        } catch PaykitError.ConcurrentUpdate {
            _ = try? await load(publicKey: key)
            throw PubkyAppProfileError.changedElsewhere
        }
        Self.pubkyAppProfileOwners.insert(key)
        if let paykitAvatar, snapshot.profile.image == nil {
            Self.pubkyAppAvatarPending.insert(key)
            pendingAvatarUris[key] = paykitAvatar
        } else {
            Self.pubkyAppAvatarPending.remove(key)
            pendingAvatarUris[key] = nil
        }
        let previousTags = base?.tags ?? []
        let tags = await tagsToKeep(data.tags, for: key)
        var profile = Self.profile(publicKey: key, snapshot: snapshot, tags: tags ?? previousTags)
        if Self.pubkyAppAvatarPending.contains(key), let uri = pendingAvatarUris[key] {
            profile = profile.withImageUrl(uri)
        }
        // Tags live only in the Paykit copy, so a tag change it does not take is reported, and the remembered base keeps
        // the tags it last stored so a retry is reported again.
        var copyError: Error?
        if tags != nil {
            do {
                try await publishCopy(profile, expectedIdentity: key)
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

    /// When the last load could not read the Paykit copy, the form showed no tags, so the stored ones are kept; nil while
    /// they still cannot be read.
    private func tagsToKeep(_ tags: [String], for key: String) async -> [String]? {
        guard tagsUnavailable.contains(key) else { return tags }
        let stored: Paykit.PaykitProfileRecord?
        do {
            stored = try await PubkyService.fetchPaykitProfile(publicKey: key)
        } catch {
            return nil
        }
        tagsUnavailable.remove(key)
        let storedTags = stored.map { PubkyProfileData.from(paykitProfile: $0.profile).tags } ?? []
        return storedTags + tags.filter { !storedTags.contains($0) }
    }

    /// Uploads a JPEG avatar as a pubky.app blob and file and returns the file URI for the profile image.
    func uploadAvatar(_ jpegData: Data, expectedIdentity: String?) async throws -> String {
        let key = try await Self.identity(expectedIdentity)
        return try await withPubkyAppScope {
            try await PubkyService.uploadPubkyAppAvatar(bytes: jpegData, contentType: "image/jpeg", expectedIdentity: key)
        }
    }

    private func migrate(_ data: PubkyProfileData, publicKey: String) async -> Paykit.PubkyProfileSnapshot? {
        let links = data.links
            .compactMap { link -> Paykit.PubkyProfileLink? in
                let title = Self.singleLine(link.label)
                guard !title.isEmpty, let url = Self.linkUrl(link.url) else { return nil }
                return Paykit.PubkyProfileLink(title: Self.prefix(title, Self.linkTitleMaxLength), url: url)
            }
            .prefix(Self.linksMaxCount)
        let update = Paykit.PubkyProfileUpdate(
            name: Self.prefix(Self.singleLine(data.name), Self.nameMaxLength),
            bio: Self.prefix(Self.singleLine(data.bio), Self.bioMaxLength),
            image: nil,
            links: Array(links)
        )
        let snapshot: Paykit.PubkyProfileSnapshot
        do {
            snapshot = try await withPubkyAppScope {
                try await PubkyService.publishPubkyProfile(update, expectedRevision: nil, expectedIdentity: publicKey)
            }
            Logger.info("Moved Bitkit profile to pubky.app", context: "PubkyAppProfileStore")
        } catch {
            Logger.warn("Failed to move Bitkit profile to pubky.app: \(error)", context: "PubkyAppProfileStore")
            return nil
        }
        guard let uri = data.image, Self.isPaykitStorage(uri) else { return snapshot }
        return await moveAvatar(uri, onto: snapshot, publicKey: publicKey) ?? snapshot
    }

    private func moveAvatar(
        _ uri: String,
        onto snapshot: Paykit.PubkyProfileSnapshot,
        publicKey: String
    ) async -> Paykit.PubkyProfileSnapshot? {
        do {
            let moved = try await withPubkyAppScope {
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
            }
            Self.pubkyAppAvatarPending.remove(publicKey)
            return moved
        } catch {
            Logger.warn("Failed to move avatar to pubky.app: \(error)", context: "PubkyAppProfileStore")
            Self.pubkyAppAvatarPending.insert(publicKey)
            return nil
        }
    }

    /// Deletes the identity's pubky.app profile, for a wallet-owned identity deleting its profile.
    func deleteProfile(expectedIdentity: String) async throws {
        let key = Self.normalized(expectedIdentity)
        guard let revision = try await PubkyService.fetchPubkyProfileWithRevision(publicKey: key)?.revision else { return }
        try await withPubkyAppScope {
            try await PubkyService.deletePubkyProfile(expectedRevision: revision, expectedIdentity: key)
        }
        profilesByRevision[key] = nil
        revisionOrder[key] = nil
    }

    private func publishCopy(_ profile: PubkyProfile, expectedIdentity: String) async throws {
        do {
            try await PubkyService.publishPaykitProfile(
                PubkyProfileData.from(profile: profile).toPaykitProfile(),
                expectedIdentity: expectedIdentity
            )
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
            url = "tel:\(value.filter { !" -()".contains($0) })"
        } else if value.contains("."), !value.hasPrefix(".") {
            url = "https://\(value)"
        } else {
            return nil
        }
        guard url.unicodeScalars.count <= linkUrlMaxLength, URL(string: url) != nil else { return nil }
        return url
    }

    private static func isEmailAddress(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !value.contains("/")
    }

    private static func isPhoneNumber(_ value: String) -> Bool {
        let digits = value.filter(\.isNumber).count
        return value.hasPrefix("+") || digits >= 7
            ? value.allSatisfy { "+0123456789 -()".contains($0) } && digits >= 5 && !value.dropFirst().contains("+")
            && value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil
            : false
    }

    private static func isPaykitStorage(_ uri: String) -> Bool {
        uri.contains("/pub/paykit/")
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
