import BitkitCore
import CryptoKit
import Foundation

struct ClipboardPromptHistory {
    private struct Observation: Codable {
        let changeCount: Int
        let digest: String?
        let launchID: UUID?
    }

    private static let storageKey = "lastInspectedClipboard"
    private static let currentLaunchID = UUID()
    private let defaults: UserDefaults
    private let launchID: UUID

    init(defaults: UserDefaults = .standard, launchID: UUID? = nil) {
        self.defaults = defaults
        self.launchID = launchID ?? Self.currentLaunchID
    }

    func shouldInspect(changeCount: Int) -> Bool {
        guard let observation else { return true }
        return observation.launchID != launchID || observation.changeCount != changeCount
    }

    func recordInspection(changeCount: Int, supportedValue: String?) -> Bool {
        let previous = observation
        let digest = supportedValue.map { Data(SHA256.hash(data: Data($0.utf8))).base64EncodedString() }
        let shouldOffer = previous.map { changeCount > $0.changeCount || digest != $0.digest } ?? true

        if let encoded = try? JSONEncoder().encode(Observation(changeCount: changeCount, digest: digest, launchID: launchID)) {
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
    // Mirrors bitkit-core's LNURL_ADDRESS_REGEX and Scanner::find_lnurl, whose matches can trigger network resolution.
    private static let lightningAddressPattern = #"^[a-z0-9._-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"#
    private static let lnurlPattern = #"^(?:(http.*|bitcoin:.*)[&?]lightning=|lightning:)?(lnurl1[02-9ac-hj-np-z]+)"#

    static func isSupportedURI(
        _ uri: String,
        ownPublicKey: String?,
        contacts: [PubkyContact],
        decodeURI: (String) async -> Bool = { await (try? decode(invoice: $0)) != nil }
    ) async -> Bool {
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
        // Only recognize these shapes here: fetching remote metadata must wait for the user's OK tap.
        if requiresNetworkResolution(normalized) {
            return true
        }
        return await decodeURI(normalized)
    }

    private static func requiresNetworkResolution(_ uri: String) -> Bool {
        var payload = uri
        if payload.hasPrefix("bitkit://") {
            // The core scanner removes all Bitkit wrappers, then recursively decodes the remaining payload.
            payload = payload.replacingOccurrences(of: "bitkit://", with: "")
            if payload.hasPrefix("lightning:") {
                payload.removeFirst("lightning:".count)
            }
        }
        return payload.lowercased().range(of: lnurlPattern, options: .regularExpression) != nil
            || payload.range(of: lightningAddressPattern, options: .regularExpression) != nil
    }
}
