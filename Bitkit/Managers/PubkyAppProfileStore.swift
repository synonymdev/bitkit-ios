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

    private struct Base {
        let profile: PubkyProfile
        let revision: String?
    }

    private var bases: [String: Base] = [:]
    private var saveCount = 0

    /// Loads the profile. An identity that is signed in and has only a Bitkit profile moves it to pubky.app first.
    func load(publicKey: String) async throws -> PubkyProfile {
        let key = Self.normalized(publicKey)
        let savesBeforeLoad = saveCount
        let paykitData: PubkyProfileData?
        do {
            paykitData = try await PubkyService.fetchPaykitProfile(publicKey: key).map {
                PubkyProfileData.from(paykitProfile: $0.profile)
            }
        } catch {
            Logger.warn("Failed to read Bitkit profile copy: \(error)", context: "PubkyAppProfileStore")
            paykitData = nil
        }
        let fetched = try await PubkyService.fetchPubkyProfileWithRevision(publicKey: key)
        var snapshot = fetched
        let isSignedIn = await Self.isSignedIn(key)
        // Once a pubky.app profile was seen, one missing there was deleted there, so it is not moved back from Bitkit.
        let hadPubkyAppProfile = Self.pubkyAppProfileOwners.contains(key)
        if snapshot == nil, let paykitData, isSignedIn, !hadPubkyAppProfile {
            snapshot = await migrate(paykitData, publicKey: key)
        } else if let current = snapshot, isSignedIn, Self.pubkyAppAvatarPending.contains(key), let uri = paykitData?.image {
            snapshot = await moveAvatar(uri, onto: current, publicKey: key) ?? current
        }
        let wrote = snapshot?.revision != fetched?.revision
        if snapshot != nil, !hadPubkyAppProfile {
            Self.pubkyAppProfileOwners.insert(key)
        }
        // A save that finished while this load ran holds a newer revision than this read.
        let isLatest = saveCount == savesBeforeLoad
        guard let snapshot else {
            if isLatest {
                bases[key] = nil
            }
            throw PubkyServiceError.profileNotFound
        }
        let avatarPending = Self.pubkyAppAvatarPending.contains(key)
        var profile = Self.profile(publicKey: key, snapshot: snapshot, tags: paykitData?.tags ?? [])
        if avatarPending, let uri = paykitData?.image {
            profile = profile.withImageUrl(uri)
        }
        // A refresh keeps the revision an open edit started from, so the edit's save is checked against it.
        if isLatest, bases[key] == nil || wrote {
            bases[key] = Base(profile: profile, revision: snapshot.revision)
        }
        if isSignedIn, !avatarPending, let paykitData, paykitData != PubkyProfileData.from(profile: profile) {
            await publishCopy(profile, expectedIdentity: key)
        }
        return profile
    }

    /// Saves `data` for `expectedIdentity`, or the signed-in identity. Throws `changedElsewhere` after reloading when
    /// pubky.app changed the profile since it was loaded.
    func save(_ data: PubkyProfileData, expectedIdentity: String?) async throws {
        var data = data
        data.bio = data.bio.replacingOccurrences(of: "\n", with: " ")
        let key = try await Self.identity(expectedIdentity)
        let base = bases[key]
        let expectedRevision: String? = if let base {
            base.revision
        } else {
            // Creating: an existing pubky.app profile keeps every field the form does not set.
            try await PubkyService.fetchPubkyProfileWithRevision(publicKey: key)?.revision
        }
        let update = Self.update(from: data, base: base?.profile)
        let snapshot: Paykit.PubkyProfileSnapshot
        do {
            snapshot = try await withPubkyAppScope {
                try await PubkyService.publishPubkyProfile(update, expectedRevision: expectedRevision, expectedIdentity: key)
            }
        } catch PaykitError.ConcurrentUpdate {
            bases[key] = nil
            _ = try? await load(publicKey: key)
            throw PubkyAppProfileError.changedElsewhere
        }
        let profile = Self.profile(publicKey: key, snapshot: snapshot, tags: data.tags)
        saveCount += 1
        bases[key] = Base(profile: profile, revision: snapshot.revision)
        await publishCopy(profile, expectedIdentity: key)
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
            .map { (label: $0.label.trimmed, url: $0.url.trimmed) }
            .filter { !$0.label.isEmpty && $0.url.count <= Self.linkUrlMaxLength && URL(string: $0.url)?.scheme != nil }
            .prefix(Self.linksMaxCount)
            .map { Paykit.PubkyProfileLink(title: String($0.label.prefix(Self.linkTitleMaxLength)), url: $0.url) }
        let update = Paykit.PubkyProfileUpdate(
            name: String(data.name.trimmed.prefix(Self.nameMaxLength)),
            bio: String(data.bio.trimmed.prefix(Self.bioMaxLength)),
            image: nil,
            links: links
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
        bases[key] = nil
    }

    private func publishCopy(_ profile: PubkyProfile, expectedIdentity: String) async {
        do {
            try await PubkyService.publishPaykitProfile(
                PubkyProfileData.from(profile: profile).toPaykitProfile(),
                expectedIdentity: expectedIdentity
            )
        } catch {
            Logger.warn("Failed to update Bitkit profile copy: \(error)", context: "PubkyAppProfileStore")
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
        return PubkyProfile(
            publicKey: publicKey,
            name: profile.name,
            bio: profile.bio,
            imageUrl: profile.imageUrl,
            links: profile.links,
            tags: tags,
            status: profile.status
        )
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

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
