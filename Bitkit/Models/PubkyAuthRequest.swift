import BitkitCore
import Foundation
import Paykit

enum PubkyAuthClaim: String, Equatable {
    case watchOnlyAccountV1 = "watch-only-account-v1"

    static let queryParameter = "x-bitkit-claim"
    static let watchOnlyAccountCapabilities = "/pub/paykit/v0/bitkit/server/:rw,/pub/paykit/v0/private/bitkit/server/:rw"
    private static let watchOnlyAccountCapabilitySet = Set(watchOnlyAccountCapabilities.split(separator: ",").map(String.init))

    static func matchesWatchOnlyAccountCapabilities(_ capabilities: String) -> Bool {
        guard let requestedCapabilitySet = capabilitySet(capabilities) else { return false }
        return requestedCapabilitySet == watchOnlyAccountCapabilitySet
    }

    private static func capabilitySet(_ capabilities: String) -> Set<String>? {
        let entries = capabilities
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !entries.contains(where: \.isEmpty) else { return nil }
        return Set(entries)
    }
}

enum PubkyAuthRequestError: Error, Equatable {
    case invalidUrl
    case missingBitkitClaim
    case duplicateBitkitClaim
    case unsupportedBitkitClaim(String)
    case invalidBitkitClaimCapabilities
}

// MARK: - PubkyAuth Permission

struct PubkyAuthPermission {
    let path: String
    let accessLevel: String

    var displayPath: String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    var displayAccess: String {
        var levels: [String] = []
        if accessLevel.contains("r") { levels.append("READ") }
        if accessLevel.contains("w") { levels.append("WRITE") }
        return levels.joined(separator: ", ")
    }
}

// MARK: - PubkyAuth Request

struct PubkyAuthRequest {
    let rawUrl: String
    let kind: Paykit.PubkyAuthRequestKind
    let clientID: String
    let relay: String
    let capabilities: String
    let permissions: [PubkyAuthPermission]
    let serviceNames: [String]
    let bitkitClaim: PubkyAuthClaim?
    let homeserverPublicKey: String?
    let signupToken: String?
    let authorizationUrl: String

    var isRingSignup: Bool {
        guard let components = URLComponents(string: rawUrl) else { return false }
        return components.scheme?.lowercased() == "pubkyring" && components.host?.lowercased() == "signup"
    }

    static func isProtocolURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }

        switch components.scheme?.lowercased() {
        case "pubkyauth":
            return true
        case "pubkyring":
            return components.host?.lowercased() == "signup"
        default:
            return false
        }
    }

    static func parse(url: String) throws -> PubkyAuthRequest {
        if let components = URLComponents(string: url),
           components.scheme?.lowercased() == "pubkyring",
           components.host?.lowercased() == "signup"
        {
            return try parseRingSignup(url: url, components: components)
        }

        let details = try Paykit.parsePubkyAuthUrl(authUrl: url)
        let capabilities = details.capabilities
        return try makeRequest(
            url: url,
            kind: details.kind,
            clientID: details.clientId,
            relay: details.relayUrl,
            capabilities: capabilities,
            homeserverPublicKey: nil,
            signupToken: nil
        )
    }

    private static func parseRingSignup(url: String, components: URLComponents) throws -> PubkyAuthRequest {
        let values = Dictionary(grouping: components.queryItems ?? [], by: \.name)
        let relay = try requiredQueryValue("relay", from: values)
        let secret = try requiredQueryValue("secret", from: values)
        let capabilities = try requiredQueryValue("caps", from: values)
        let homeserver = try requiredQueryValue("hs", from: values)
        let authorizationUrl = ringAuthorizationUrl(relay: relay, secret: secret, capabilities: capabilities)
        do {
            _ = try BitkitCore.parsePubkyAuthUrl(authUrl: authorizationUrl)
            _ = try Paykit.normalizePubkyPublicKey(value: homeserver)
        } catch {
            throw PubkyAuthRequestError.invalidUrl
        }
        let request = try makeRequest(
            url: url,
            kind: .signUp,
            clientID: "",
            relay: relay,
            capabilities: capabilities,
            homeserverPublicKey: homeserver,
            signupToken: optionalQueryValue("st", from: values),
            authorizationUrl: authorizationUrl
        )
        guard request.bitkitClaim == nil else {
            throw PubkyAuthRequestError.invalidUrl
        }
        return request
    }

    private static func makeRequest(
        url: String,
        kind: Paykit.PubkyAuthRequestKind,
        clientID: String,
        relay: String,
        capabilities: String,
        homeserverPublicKey: String?,
        signupToken: String?,
        authorizationUrl: String? = nil
    ) throws -> PubkyAuthRequest {
        let permissions = parseCapabilities(capabilities)
        var seenServiceNames = Set<String>()
        let serviceNames = permissions
            .compactMap { extractServiceName($0.path) }
            .filter { seenServiceNames.insert($0).inserted }
        let bitkitClaim = try parseBitkitClaim(url: url, capabilities: capabilities)
        return PubkyAuthRequest(
            rawUrl: url,
            kind: kind,
            clientID: clientID,
            relay: relay,
            capabilities: capabilities,
            permissions: permissions,
            serviceNames: serviceNames,
            bitkitClaim: bitkitClaim,
            homeserverPublicKey: homeserverPublicKey,
            signupToken: signupToken,
            authorizationUrl: authorizationUrl ?? url
        )
    }

    private static func ringAuthorizationUrl(relay: String, secret: String, capabilities: String) -> String {
        "pubkyauth:///?relay=\(encodeQueryComponent(relay))" +
            "&secret=\(encodeQueryComponent(secret))&caps=\(encodeQueryComponent(capabilities))"
    }

    private static func encodeQueryComponent(_ value: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func requiredQueryValue(
        _ name: String,
        from values: [String: [URLQueryItem]]
    ) throws -> String {
        guard let value = try optionalQueryValue(name, from: values), !value.isEmpty else {
            throw PubkyAuthRequestError.invalidUrl
        }
        return value
    }

    private static func optionalQueryValue(
        _ name: String,
        from values: [String: [URLQueryItem]]
    ) throws -> String? {
        let items = values[name] ?? []
        guard items.count <= 1 else {
            throw PubkyAuthRequestError.invalidUrl
        }
        return items.first?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func parseBitkitClaim(url: String, capabilities: String) throws -> PubkyAuthClaim? {
        guard let components = URLComponents(string: url) else {
            throw PubkyAuthRequestError.invalidUrl
        }

        let claimValues = components.queryItems?
            .filter { $0.name == PubkyAuthClaim.queryParameter }
            .map { $0.value ?? "" } ?? []

        guard claimValues.count <= 1 else {
            throw PubkyAuthRequestError.duplicateBitkitClaim
        }
        guard let claimValue = claimValues.first else {
            if PubkyAuthClaim.matchesWatchOnlyAccountCapabilities(capabilities) {
                throw PubkyAuthRequestError.missingBitkitClaim
            }
            return nil
        }
        guard let claim = PubkyAuthClaim(rawValue: claimValue) else {
            throw PubkyAuthRequestError.unsupportedBitkitClaim(claimValue)
        }
        guard PubkyAuthClaim.matchesWatchOnlyAccountCapabilities(capabilities) else {
            throw PubkyAuthRequestError.invalidBitkitClaimCapabilities
        }

        return claim
    }

    static func parseCapabilities(_ caps: String) -> [PubkyAuthPermission] {
        caps
            .split(separator: ",")
            .compactMap { segment -> PubkyAuthPermission? in
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                guard let lastColon = trimmed.lastIndex(of: ":") else { return nil }

                let path = String(trimmed[trimmed.startIndex ..< lastColon])
                let access = String(trimmed[trimmed.index(after: lastColon)...])

                guard !path.isEmpty, !access.isEmpty else { return nil }

                return PubkyAuthPermission(path: path, accessLevel: access)
            }
    }

    static func extractServiceName(_ path: String) -> String? {
        let components = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")

        // Skip "pub" prefix, take the next meaningful component
        guard components.count >= 2 else { return nil }
        let name = String(components[1])
        return name.isEmpty ? nil : name
    }
}
