import Foundation
import Paykit

enum PubkyAppProfileError: LocalizedError {
    /// The pubky.app profile changed since Bitkit loaded it, so the save was not applied.
    case changedElsewhere

    var errorDescription: String? {
        t("profile__edit_changed_error")
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
    private var lastSavedRevisions: [String: String] = [:]
    private var tagsUnavailable: Set<String> = []
    private static let rememberedRevisions = 8

    /// Loads the profile. An identity that is signed in and has only a Bitkit profile moves it to pubky.app first; while
    /// that move cannot finish, the Bitkit profile is shown and the next save creates the pubky.app profile.
    func load(publicKey: String) async throws -> PubkyProfile {
        let key = Self.normalized(publicKey)
        let paykitData: PubkyProfileData?
        do {
            paykitData = try await PubkyService.fetchPaykitProfile(publicKey: key).map {
                PubkyProfileData.from(paykitProfile: $0.profile)
            }
            tagsUnavailable.remove(key)
        } catch {
            Logger.warn("Failed to read Bitkit profile copy: \(error)", context: "PubkyAppProfileStore")
            paykitData = nil
            tagsUnavailable.insert(key)
        }
        let fetched = try await PubkyService.fetchPubkyProfileWithRevision(publicKey: key)
        var snapshot = fetched
        let isSignedIn = await Self.isSignedIn(key)
        // Once a pubky.app profile was seen, one missing there was deleted there, so it is not moved back from Bitkit.
        let hadPubkyAppProfile = Self.pubkyAppProfileOwners.contains(key)
        let migrating = snapshot == nil && isSignedIn && !hadPubkyAppProfile
        if migrating, let paykitData {
            snapshot = await migrate(paykitData, publicKey: key)
        } else if let current = snapshot, isSignedIn, Self.pubkyAppAvatarPending.contains(key), let uri = paykitData?.image {
            snapshot = await moveAvatar(uri, onto: current, publicKey: key) ?? current
        }
        guard let snapshot else {
            if migrating, let paykitData {
                return paykitData.toProfile(publicKey: key)
            }
            throw PubkyServiceError.profileNotFound
        }
        if !hadPubkyAppProfile {
            Self.pubkyAppProfileOwners.insert(key)
        }
        let avatarPending = Self.pubkyAppAvatarPending.contains(key)
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
    /// from writes only the fields that differ from that revision; without one it creates or replaces the profile.
    /// Throws `changedElsewhere` after reloading when pubky.app changed the profile since that revision.
    func save(_ data: PubkyProfileData, expectedIdentity: String?) async throws {
        let data = Self.normalized(data)
        let key = try await Self.identity(expectedIdentity)
        var base: PubkyProfile?
        let expectedRevision: String?
        if let baseRevision = data.baseRevision {
            guard let known = profilesByRevision[key]?[baseRevision] else {
                _ = try? await load(publicKey: key)
                throw PubkyAppProfileError.changedElsewhere
            }
            base = known
            expectedRevision = baseRevision
        } else {
            // Creating: an existing pubky.app profile keeps every field the form does not set.
            expectedRevision = try await PubkyService.fetchPubkyProfileWithRevision(publicKey: key)?.revision
        }
        let update = Self.update(from: data, base: base)
        let snapshot: Paykit.PubkyProfileSnapshot
        do {
            snapshot = try await withPubkyAppScope {
                try await PubkyService.publishPubkyProfile(update, expectedRevision: expectedRevision, expectedIdentity: key)
            }
        } catch PaykitError.ConcurrentUpdate {
            _ = try? await load(publicKey: key)
            throw PubkyAppProfileError.changedElsewhere
        }
        Self.pubkyAppProfileOwners.insert(key)
        let tags = await tagsToKeep(data.tags, for: key)
        let profile = Self.profile(publicKey: key, snapshot: snapshot, tags: tags)
        remember(profile, for: key)
        lastSavedRevisions[key] = snapshot.revision
        // Tags live only in the Paykit copy, so a changed tag that it does not take is reported.
        let tagsChanged = tags != (base?.tags ?? [])
        do {
            try await publishCopy(profile, expectedIdentity: key)
        } catch where tagsChanged {
            throw error
        } catch {}
    }

    /// The revision the last successful save for `publicKey` produced.
    func lastSavedRevision(publicKey: String) -> String? {
        lastSavedRevisions[Self.normalized(publicKey)]
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

    /// When the last load could not read the Paykit copy, the form showed no tags, so the stored ones are kept.
    private func tagsToKeep(_ tags: [String], for key: String) async -> [String] {
        guard tagsUnavailable.contains(key), let stored = try? await PubkyService.fetchPaykitProfile(publicKey: key) else { return tags }
        tagsUnavailable.remove(key)
        let storedTags = PubkyProfileData.from(paykitProfile: stored.profile).tags
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
        guard let uri = data.image else { return snapshot }
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

    private static func singleLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncates by Unicode scalars, as pubky.app counts them.
    private static func prefix(_ text: String, _ maxScalars: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxScalars)))
    }

    /// Bitkit accepted links without a scheme (a site, an email address, a phone number); pubky.app needs full URLs.
    static func linkUrl(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let url: String = if URL(string: value)?.scheme != nil {
            value
        } else if value.contains("@") {
            "mailto:\(value)"
        } else if value.allSatisfy({ "+0123456789 -()".contains($0) }) {
            "tel:\(value.filter { !" -()".contains($0) })"
        } else {
            "https://\(value)"
        }
        guard url.unicodeScalars.count <= linkUrlMaxLength, URL(string: url) != nil else { return nil }
        return url
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
