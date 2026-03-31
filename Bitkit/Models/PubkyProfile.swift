import BitkitCore
import Foundation

// MARK: - PubkyProfileData (shared Codable format for profile & contact JSON on homeserver)

struct PubkyProfileData: Codable {
    var name: String
    var bio: String
    var image: String?
    var links: [Link]
    var tags: [String]

    struct Link: Codable {
        let label: String
        let url: String
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
        name = try container.decode(String.self, forKey: .name)
        bio = try container.decode(String.self, forKey: .bio)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        links = try container.decode([Link].self, forKey: .links)
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

struct PubkyProfileLink: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let url: String
}

// MARK: - PubkyProfile

struct PubkyProfile: Sendable {
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

    init(publicKey: String, ffiProfile: BitkitCore.PubkyProfile) {
        self.publicKey = publicKey
        name = ffiProfile.name
        bio = ffiProfile.bio ?? ""
        status = ffiProfile.status
        tags = []

        imageUrl = ffiProfile.image

        if let ffiLinks = ffiProfile.links {
            links = ffiLinks.map { link in
                PubkyProfileLink(label: link.title, url: link.url)
            }
        } else {
            links = []
        }
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

    private static func truncate(_ key: String) -> String {
        guard key.count > 10 else { return key }
        return "\(key.prefix(4))...\(key.suffix(4))"
    }
}
