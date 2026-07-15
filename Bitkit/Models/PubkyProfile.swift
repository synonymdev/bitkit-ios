import Foundation
import Paykit

// MARK: - PubkyProfileData

struct PubkyProfileData: Codable, Equatable {
    var name: String
    var bio: String
    var image: String?
    var links: [Link]
    var tags: [String]

    struct Link: Codable, Equatable {
        let label: String
        let url: String

        init(label: String, url: String) {
            self.label = label
            self.url = url
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        }
    }

    init(name: String, bio: String, image: String?, links: [Link], tags: [String]) {
        self.name = name
        self.bio = bio
        self.image = image
        self.links = links
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        bio = try container.decodeIfPresent(String.self, forKey: .bio) ?? ""
        image = try container.decodeIfPresent(String.self, forKey: .image)
        links = try container.decodeIfPresent([Link].self, forKey: .links) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    func toProfile(publicKey: String, status: String? = nil) -> PubkyProfile {
        PubkyProfile(
            publicKey: publicKey,
            name: name,
            bio: bio,
            imageUrl: image,
            links: links.map { PubkyProfileLink(label: $0.label, url: $0.url) },
            tags: tags,
            status: status
        )
    }

    static func from(profile: PubkyProfile) -> PubkyProfileData {
        PubkyProfileData(
            name: profile.name,
            bio: profile.bio,
            image: profile.imageUrl,
            links: profile.links.map { Link(label: $0.label, url: $0.url) },
            tags: profile.tags
        )
    }

    static func from(paykitProfile: Paykit.PaykitProfile) -> PubkyProfileData {
        let extra = paykitProfile.extraJson.flatMap { try? PubkyProfileData.decode(from: $0) }
        return PubkyProfileData(
            name: paykitProfile.displayName ?? extra?.name ?? "",
            bio: extra?.bio ?? "",
            image: paykitProfile.imageUri ?? extra?.image,
            links: extra?.links ?? [],
            tags: extra?.tags ?? []
        )
    }

    func toPaykitProfile() throws -> Paykit.PaykitProfile {
        let extraJson = try String(data: encoded(), encoding: .utf8)
        return Paykit.PaykitProfile(
            displayName: name,
            imageUri: image,
            extraJson: extraJson
        )
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(from jsonString: String) throws -> PubkyProfileData {
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "PubkyProfileData", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8"])
        }
        return try JSONDecoder().decode(PubkyProfileData.self, from: data)
    }
}

// MARK: - PubkyProfileLink

struct PubkyProfileLink: Identifiable {
    let id = UUID()
    let label: String
    let url: String
}

// MARK: - PubkyProfile

struct PubkyProfile {
    let publicKey: String
    let name: String
    let bio: String
    let imageUrl: String?
    let links: [PubkyProfileLink]
    let tags: [String]
    let status: String?

    var truncatedPublicKey: String {
        Self.truncate(publicKey)
    }

    init(publicKey: String, pubkyProfile: Paykit.PubkyProfile) {
        self.publicKey = publicKey
        name = pubkyProfile.name
        bio = pubkyProfile.bio ?? ""
        imageUrl = pubkyProfile.image
        links = pubkyProfile.links.map { PubkyProfileLink(label: $0.title, url: $0.url) }
        tags = []
        status = pubkyProfile.status
    }

    init(publicKey: String, paykitProfile: Paykit.PaykitProfile) {
        self = PubkyProfileData.from(paykitProfile: paykitProfile).toProfile(publicKey: publicKey)
    }

    init(resolution: Paykit.ContactProfileResolution) {
        let publicKey = Self.normalizedPublicKey(resolution.publicKey)
        if let paykitProfile = resolution.paykitProfile {
            self.init(publicKey: publicKey, paykitProfile: paykitProfile)
            return
        }
        if let pubkyProfile = resolution.pubkyProfile {
            self.init(publicKey: publicKey, pubkyProfile: pubkyProfile)
            return
        }
        self = Self.forDisplay(publicKey: publicKey, name: resolution.displayName, imageUrl: resolution.imageUri)
    }

    init(publicKey: String, name: String, bio: String, imageUrl: String?, links: [PubkyProfileLink], tags: [String] = [], status: String?) {
        self.publicKey = publicKey
        self.name = name
        self.bio = bio
        self.imageUrl = imageUrl
        self.links = links
        self.tags = tags
        self.status = status
    }

    static func placeholder(publicKey: String) -> PubkyProfile {
        PubkyProfile(
            publicKey: publicKey,
            name: PubkyProfile.truncate(publicKey),
            bio: "",
            imageUrl: nil,
            links: [],
            status: nil
        )
    }

    static func forDisplay(publicKey: String, name: String?, imageUrl: String?) -> PubkyProfile {
        PubkyProfile(
            publicKey: publicKey,
            name: name ?? PubkyProfile.truncate(publicKey),
            bio: "",
            imageUrl: imageUrl,
            links: [],
            status: nil
        )
    }

    func withNameFallback(_ fallbackName: String?) -> PubkyProfile {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let fallbackName,
              !fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return self }
        return PubkyProfile(
            publicKey: publicKey,
            name: fallbackName,
            bio: bio,
            imageUrl: imageUrl,
            links: links,
            tags: tags,
            status: status
        )
    }

    private static func truncate(_ key: String) -> String {
        guard key.count > 10 else { return key }
        return "\(key.prefix(4))...\(key.suffix(4))"
    }

    private static func normalizedPublicKey(_ key: String) -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return PubkyPublicKeyFormat.normalized(trimmedKey) ?? (trimmedKey.hasPrefix("pubky") ? trimmedKey : "pubky\(trimmedKey)")
    }
}
