import SwiftUI

struct PubkyContactAvatar: View {
    let name: String
    let imageUrl: String?
    let size: CGFloat
    /// Rounded square when set, circular otherwise.
    let cornerRadius: CGFloat?

    init(name: String, imageUrl: String?, size: CGFloat, cornerRadius: CGFloat? = nil) {
        self.name = name
        self.imageUrl = imageUrl
        self.size = size
        self.cornerRadius = cornerRadius
    }

    init(contact: PubkyContact, size: CGFloat, cornerRadius: CGFloat? = nil) {
        name = contact.displayName
        imageUrl = contact.profile.imageUrl
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let imageUrl {
                PubkyImage(uri: imageUrl, size: size, cornerRadius: cornerRadius)
            } else {
                ContactAvatarLetter(source: name, size: size, cornerRadius: cornerRadius)
            }
        }
        .accessibilityHidden(true)
    }
}
