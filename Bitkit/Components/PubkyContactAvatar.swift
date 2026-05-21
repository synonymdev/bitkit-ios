import SwiftUI

struct PubkyContactAvatar: View {
    let name: String
    let imageUrl: String?
    let size: CGFloat

    init(name: String, imageUrl: String?, size: CGFloat) {
        self.name = name
        self.imageUrl = imageUrl
        self.size = size
    }

    init(contact: PubkyContact, size: CGFloat) {
        name = contact.displayName
        imageUrl = contact.profile.imageUrl
        self.size = size
    }

    var body: some View {
        Group {
            if let imageUrl {
                PubkyImage(uri: imageUrl, size: size)
            } else {
                ContactAvatarLetter(source: name, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}
