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
    case duplicateRelay
    case duplicateSecret
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
        if accessLevel.contains("r") {
            levels.append("READ")
        }
        if accessLevel.contains("w") {
            levels.append("WRITE")
        }
        return levels.joined(separator: ", ")
    }
}

// MARK: - PubkyAuth Request

struct PubkyAuthRequest {
    private static let bitkitSetupHost = "pubky-auth"
    private static let bitkitSetupPath = "/setup"

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
    let authorizationUrl: String?

    var isSignup: Bool {
        Self.isSignupURL(rawUrl)
    }
    /// The network origin that receives the authorization. This is a delivery destination, not a service identity.
    var relayOrigin: String? {
        guard let components = URLComponents(string: relay),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }

        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    static func isProtocolURL(_ value: String) -> Bool {
        let normalizedURL = normalizedProtocolURL(value)
        guard let components = URLComponents(string: normalizedURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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

    /// Normalizes Bitkit's unique iOS handoff because the OS cannot deterministically route a custom scheme shared with Pubky Ring.
    static func normalizedProtocolURL(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBitkitSetupHandoff(trimmedValue),
              let queryDelimiter = trimmedValue.firstIndex(of: "?")
        else {
            return value
        }

        let queryStart = trimmedValue.index(after: queryDelimiter)
        return "pubkyauth://signin_grant?\(trimmedValue[queryStart...])"
    }

    static func parse(url: String) throws -> PubkyAuthRequest {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresBitkitClaim = isBitkitSetupHandoff(trimmedURL)
        let normalizedURL = normalizedProtocolURL(trimmedURL)
        try rejectDuplicateRelayAndSecret(in: normalizedURL)

        if requiresBitkitClaim {
            let capabilities = URLComponents(string: normalizedURL)?.queryItems?
                .first { $0.name == "caps" }?.value ?? ""
            _ = try parseBitkitClaim(url: normalizedURL, capabilities: capabilities, requiresBitkitClaim: true)
        }

        if let components = URLComponents(string: normalizedURL), isSignupURL(components) {
            return try parseSignup(url: normalizedURL, components: components)
        }

        let details = try Paykit.parsePubkyAuthUrl(authUrl: normalizedURL)
        let capabilities = details.capabilities
        return try makeRequest(
            url: normalizedURL,
            kind: details.kind,
            clientID: details.clientId,
            relay: details.relayUrl,
            capabilities: capabilities,
            homeserverPublicKey: nil,
            signupToken: nil,
            authorizationUrl: normalizedURL,
            requiresBitkitClaim: requiresBitkitClaim
        )
    }

    static func isSignupURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return isSignupURL(components)
    }

    private static func isSignupURL(_ components: URLComponents) -> Bool {
        switch components.scheme?.lowercased() {
        case "pubkyring":
            return components.host?.lowercased() == "signup"
        case "pubkyauth":
            return ["direct_signup", "signup"].contains(components.host?.lowercased())
        default:
            return false
        }
    }

    private static func parseSignup(url: String, components: URLComponents) throws -> PubkyAuthRequest {
        let values = Dictionary(grouping: components.queryItems ?? [], by: \.name)
        let homeserver = try requiredQueryValue("hs", from: values)
        let authorizesApp = components.scheme?.lowercased() == "pubkyring" ||
            (
                components.scheme?.lowercased() == "pubkyauth" &&
                    components.host?.lowercased() == "signup" &&
                    ["relay", "secret", "caps"].contains { values[$0] != nil }
            )
        let relay = authorizesApp ? try requiredQueryValue("relay", from: values) : ""
        let secret = authorizesApp ? try requiredQueryValue("secret", from: values) : ""
        let capabilities = authorizesApp ? try requiredQueryValue("caps", from: values) : ""
        let authorizationUrl = authorizesApp
            ? ringAuthorizationUrl(relay: relay, secret: secret, capabilities: capabilities)
            : nil
        do {
            if let authorizationUrl {
                _ = try BitkitCore.parsePubkyAuthUrl(authUrl: authorizationUrl)
            }
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
        authorizationUrl: String?,
        requiresBitkitClaim: Bool = false
    ) throws -> PubkyAuthRequest {
        let permissions = parseCapabilities(capabilities)
        var seenServiceNames = Set<String>()
        let serviceNames = permissions
            .compactMap { extractServiceName($0.path) }
            .filter { seenServiceNames.insert($0).inserted }
        let bitkitClaim = try parseBitkitClaim(url: url, capabilities: capabilities, requiresBitkitClaim: requiresBitkitClaim)
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
            authorizationUrl: authorizationUrl
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

    private static func rejectDuplicateRelayAndSecret(in url: String) throws {
        guard let items = URLComponents(string: url)?.queryItems else { return }
        if items.filter({ $0.name == "relay" }).count > 1 {
            throw PubkyAuthRequestError.duplicateRelay
        }
        if items.filter({ $0.name == "secret" }).count > 1 {
            throw PubkyAuthRequestError.duplicateSecret
        }
    }

    static func parseBitkitClaim(url: String, capabilities: String, requiresBitkitClaim: Bool = false) throws -> PubkyAuthClaim? {
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
            if requiresBitkitClaim || PubkyAuthClaim.matchesWatchOnlyAccountCapabilities(capabilities) {
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

    private static func isBitkitSetupHandoff(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "bitkit",
              components.host?.lowercased() == bitkitSetupHost,
              components.path == bitkitSetupPath,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let query = components.percentEncodedQuery,
              !query.isEmpty,
              !query.hasPrefix("?")
        else {
            return false
        }

        return true
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
