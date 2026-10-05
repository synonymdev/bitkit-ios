import BitkitCore
import CryptoKit
import Foundation

struct ClipboardPromptHistory {
    private struct Observation: Codable {
        let changeCount: Int
        let digest: String?
    }

    private static let storageKey = "lastInspectedClipboard"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shouldInspect(changeCount: Int) -> Bool {
        observation?.changeCount != changeCount
    }

    func recordInspection(changeCount: Int, supportedValue: String?) -> Bool {
        let previous = observation
        let digest = supportedValue.map { Data(SHA256.hash(data: Data($0.utf8))).base64EncodedString() }
        let shouldOffer = previous.map { changeCount > $0.changeCount || digest != $0.digest } ?? true

        if let encoded = try? JSONEncoder().encode(Observation(changeCount: changeCount, digest: digest)) {
            defaults.set(encoded, forKey: Self.storageKey)
        }

        return shouldOffer
    }

    private var observation: Observation? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(Observation.self, from: data)
    }
}

enum ClipboardPromptValidator {
    static func isSupportedURI(_ uri: String, ownPublicKey: String?, contacts: [PubkyContact]) async -> Bool {
        if resolvePastedPubkyRoute(input: uri, ownPublicKey: ownPublicKey, contacts: contacts) != nil {
            return true
        }
        if SamRockSetupRequest.parse(uri) != nil {
            return true
        }
        if PaykitFeatureFlags.isUIEnabled,
           PubkyAuthRequest.isProtocolURL(uri),
           (try? PubkyAuthRequest.parse(url: uri)) != nil
        {
            return true
        }

        let normalized = uri.removingLightningSchemes()
        guard !Bip21Utils.isDuplicatedBip21(normalized) else { return false }
        return await (try? decode(invoice: normalized)) != nil
    }
}
