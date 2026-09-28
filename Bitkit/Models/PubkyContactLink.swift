import Foundation

enum PubkyContactLink {
    static func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "bitkit" && url.host?.lowercased() == "contact"
    }

    static func publicKey(from url: URL) -> String? {
        guard matches(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "pubky", let key = items[0].value,
              key.count <= PubkyPublicKeyFormat.maximumInputLength
        else { return nil }

        return PubkyPublicKeyFormat.normalized(key)
    }
}
