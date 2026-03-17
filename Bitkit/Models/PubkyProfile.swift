import BitkitCore
import Foundation

struct PubkyProfileLink: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let url: String
}

struct PubkyProfile: Sendable {
    let publicKey: String
    let name: String
    let bio: String
    let imageUrl: String?
    let links: [PubkyProfileLink]
    let status: String?

    var truncatedPublicKey: String {
        Self.truncate(publicKey)
    }

    init(publicKey: String, ffiProfile: BitkitCore.PubkyProfile) {
        self.publicKey = publicKey
        name = ffiProfile.name
        bio = ffiProfile.bio ?? ""
        status = ffiProfile.status

        imageUrl = ffiProfile.image

        if let ffiLinks = ffiProfile.links {
            links = ffiLinks.map { link in
                PubkyProfileLink(label: link.title, url: link.url)
            }
        } else {
            links = []
        }
    }

    init(publicKey: String, name: String, bio: String, imageUrl: String?, links: [PubkyProfileLink], status: String?) {
        self.publicKey = publicKey
        self.name = name
        self.bio = bio
        self.imageUrl = imageUrl
        self.links = links
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
