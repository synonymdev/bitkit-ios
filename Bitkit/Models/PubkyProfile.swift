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
        guard publicKey.count > 10 else { return publicKey }
        let prefix = publicKey.prefix(4)
        let suffix = publicKey.suffix(4)
        return "\(prefix)...\(suffix)"
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
}
