import Foundation

/// The pubky.app moderation accounts. pubky.app makes every new profile follow one of them, so it shows up among the
/// follows of a fresh profile without being anyone the user knows.
enum PubkyModerationBot {
    private static let publicKeys = [
        // pubky.app production
        "euarj183st16psbzusb44usk8i1k5foubnw7zt3n3j8h9zxg6hro",
        // pubky.app staging
        "nto4u7kkagk5hfjk4wgueemzy61nssic811hid1ty9u81uatmqzy",
    ]

    static func matches(_ publicKey: String) -> Bool {
        publicKeys.contains { PubkyPublicKeyFormat.matches(publicKey, $0) }
    }
}
